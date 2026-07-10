import { createHash, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ActiveTask, ChatTurn, Character, MemoryItem, Player, Scene, ScenePoi, ScenePortal, TilePos, Visit, Wallet, WorldProp } from './types.ts';
import { ANON_PLAYER, DEFAULT_SCENE, INITIAL_FLOWERS, MAX_FLOWERS, STAMPS_PER_FLOWER } from './types.ts';
import type { ImageBlob } from './adapters/types.ts';
import type { SpriteSheetMeta } from './sprite_sheet.ts';

/** 初始钱包（冷启动/旧档迁移）：预置初始小红花，零盖章进度。 */
function freshWallet(): Wallet {
  return { flowers: INITIAL_FLOWERS, stampProgress: 0, stampsTotal: 0 };
}

/**
 * 把持久化里读到的原始值归一成 Wallet。
 * 真 Wallet（对象且有数值 flowers 键）→ 夹紧字段直接用（migrated=false）；
 * 其它（旧贴纸背包 {stickerId:count}、空 {}、非法）→ 方案 A 换初始小红花（migrated=true，供上层写回固化）。
 */
function coerceWallet(raw: unknown): { wallet: Wallet; migrated: boolean } {
  if (raw && typeof raw === 'object' && typeof (raw as { flowers?: unknown }).flowers === 'number') {
    const r = raw as { flowers: number; stampProgress?: unknown; stampsTotal?: unknown };
    const flowers = Math.max(0, Math.min(MAX_FLOWERS, Math.floor(r.flowers)));
    const stampProgress = Math.max(0, Math.min(STAMPS_PER_FLOWER, Math.floor(Number(r.stampProgress) || 0)));
    const stampsTotal = Math.max(0, Math.floor(Number(r.stampsTotal) || 0));
    return { wallet: { flowers, stampProgress, stampsTotal }, migrated: false };
  }
  return { wallet: freshWallet(), migrated: true };
}

/**
 * 结算钱包：每满 STAMPS_PER_FLOWER 章换 1 花，直到不满或花达 MAX_FLOWERS。返回是否升了花。
 * 满 9 溢出：一组已满（stampProgress===STAMPS_PER_FLOWER）却无格子时停住不清零、不再多攒——
 * 等 spendFlower 腾出格子后本函数再跑一次立即补升，不浪费小朋友攒的章（decision：暂停升花）。
 */
function settleWallet(w: Wallet): boolean {
  let gained = false;
  while (w.stampProgress >= STAMPS_PER_FLOWER && w.flowers < MAX_FLOWERS) {
    w.flowers += 1;
    w.stampProgress -= STAMPS_PER_FLOWER;
    gained = true;
  }
  // 满 9 溢出：最多把一组已满的章留作待兑换（停在 STAMPS_PER_FLOWER），多出来的丢弃，避免无限累积。
  if (w.stampProgress > STAMPS_PER_FLOWER) w.stampProgress = STAMPS_PER_FLOWER;
  return gained;
}

/**
 * 立绘 idle 动画记录，按源立绘 hash 键控（fairy/player/NPC 统一）。
 * status=pending 生成中；ready 带图集资产 hash + meta；failed 生成失败（客户端保留静态）。
 */
export interface SpriteAnimRecord {
  status: 'pending' | 'ready' | 'failed';
  animAsset?: string;
  meta?: SpriteSheetMeta;
}

/** scenes 表的一行原样（列名 snake_case）。 */
interface SceneRow {
  world_id: string;
  scene_id: string;
  name: string;
  terrain_asset: string;
  grid_tiles: number;
  pois: string;
  portals: string;
}

export interface World {
  id: string;
  characters: Map<string, Character>;
  /** 语音生成的 SDF 物件（id → WorldProp，tile 为落位回报）。 */
  props: Map<string, WorldProp>;
}
// 注：钱包与进行中委托已不属于「世界」——它们按 (worldId, playerId) 分，
// 见 getWallet/getActiveTask。世界只剩角色与物件这类真正全局的东西。

/**
 * 世界状态 + 生成的 sprite 资源存储。
 * 传 dataDir → 持久化到 SQLite（<dataDir>/world.db，assets/ + assets.json 清单沿用文件寻址）；
 * 不传 → 内存 SQLite（`:memory:`，测试用）。
 *
 * 存储布局：
 *   worlds(id, inventory, active_task)       ← inventory/active_task 两列已废弃，见 wallets/player_tasks
 *   characters(id PK, world_id, data JSON)   ← Character 整对象存一行
 *   props(id PK, world_id, data JSON)
 *   wallets(world_id, player_id, data JSON)      ← 每玩家一份小红花钱包
 *   player_tasks(world_id, player_id, data JSON) ← 每玩家一个进行中委托（无委托则无行）
 * saveCharacter 从「全量重写 worlds.json」变为「UPDATE 一行」，根治 chatHistory 膨胀拖慢落盘。
 * 首启若存在旧 worlds.json 且库为空 → 一次性迁移后把 worlds.json 改名 .migrated 备份。
 */
export class WorldStore {
  readonly #dir: string | null;
  readonly #db: DatabaseSync;
  readonly #assets = new Map<string, ImageBlob>();
  // 立绘 hash → idle 动画记录（sprite_anims.json 持久化，跨重启保留）
  readonly #spriteAnims = new Map<string, SpriteAnimRecord>();
  // 世界地点名清单（POI，客户端 world_info 上报）：纯内存，客户端每次连上重发，不持久化
  readonly #locations = new Map<string, string[]>();

  constructor(dataDir?: string) {
    this.#dir = dataDir ?? null;
    if (this.#dir !== null) mkdirSync(this.#dir, { recursive: true });
    this.#db = new DatabaseSync(this.#dir !== null ? join(this.#dir, 'world.db') : ':memory:');
    this.#initSchema();
    if (this.#dir !== null) {
      this.#migrateFromJson();
      this.#migrateLegacyMemories();
      this.#migrateLegacyChatHistory();
      this.#migrateLegacyPlayerPositions();
      this.#migrateLegacyEntityScenes();
      this.#loadAssets();
      this.#loadSpriteAnims();
    }
  }

  #initSchema(): void {
    this.#db.exec(`
      CREATE TABLE IF NOT EXISTS players (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS worlds (
        id TEXT PRIMARY KEY,
        inventory TEXT NOT NULL DEFAULT '{}',
        active_task TEXT
      );
      CREATE TABLE IF NOT EXISTS characters (
        id TEXT PRIMARY KEY,
        world_id TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_characters_world ON characters(world_id);
      CREATE TABLE IF NOT EXISTS props (
        id TEXT PRIMARY KEY,
        world_id TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_props_world ON props(world_id);
      CREATE TABLE IF NOT EXISTS memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_character_id TEXT NOT NULL,
        about_player_id TEXT NOT NULL,
        about_character_id TEXT,
        text TEXT NOT NULL,
        kind TEXT NOT NULL,
        ts INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_mem_owner_player ON memories(owner_character_id, about_player_id);
      CREATE TABLE IF NOT EXISTS visits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        world_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_visits_world_player ON visits(world_id, player_id);
      CREATE TABLE IF NOT EXISTS chat_turns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        ts INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_chat_char_player ON chat_turns(character_id, player_id, id);
      CREATE TABLE IF NOT EXISTS creation_icons (
        option_id TEXT PRIMARY KEY,
        asset_hash TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS wallets (
        world_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (world_id, player_id)
      );
      CREATE TABLE IF NOT EXISTS player_tasks (
        world_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (world_id, player_id)
      );
      -- 玩家位置：必须带场景。只按 playerId 存位置在多场景下毫无意义——
      -- 「小明在 (12,30)」是村庄的池塘边还是森林的空地？
      CREATE TABLE IF NOT EXISTS player_positions (
        world_id  TEXT NOT NULL,
        scene_id  TEXT NOT NULL,
        player_id TEXT NOT NULL,
        tile_x    INTEGER NOT NULL,
        tile_y    INTEGER NOT NULL,
        PRIMARY KEY (world_id, scene_id, player_id)
      );
      -- 场景 = 世界里的一片区域（一张地图）。地形二进制存 assets 库，这里只记 hash。
      CREATE TABLE IF NOT EXISTS scenes (
        world_id      TEXT NOT NULL,
        scene_id      TEXT NOT NULL,
        name          TEXT NOT NULL,
        terrain_asset TEXT NOT NULL,
        grid_tiles    INTEGER NOT NULL,
        pois          TEXT NOT NULL DEFAULT '[]',
        portals       TEXT NOT NULL DEFAULT '[]',
        PRIMARY KEY (world_id, scene_id)
      );
    `);
  }

  /** 引导式造角色：某选项 id 已生成图标的资产 hash（未生成返回空串）。 */
  getCreationIcon(optionId: string): string {
    const row = this.#db.prepare('SELECT asset_hash FROM creation_icons WHERE option_id = ?').get(optionId) as
      | { asset_hash: string }
      | undefined;
    return row?.asset_hash ?? '';
  }

  /** 记录/更新某选项的图标资产 hash。 */
  setCreationIcon(optionId: string, assetHash: string): void {
    this.#db
      .prepare('INSERT INTO creation_icons (option_id, asset_hash) VALUES (?, ?) ON CONFLICT(option_id) DO UPDATE SET asset_hash = excluded.asset_hash')
      .run(optionId, assetHash);
  }

  /** 全部已生成图标映射（option id → asset hash）。 */
  listCreationIcons(): Record<string, string> {
    const rows = this.#db.prepare('SELECT option_id, asset_hash FROM creation_icons').all() as
      { option_id: string; asset_hash: string }[];
    const out: Record<string, string> = {};
    for (const r of rows) out[r.option_id] = r.asset_hash;
    return out;
  }

  #assetsDir(): string {
    return join(this.#dir as string, 'assets');
  }

  /** 一次性迁移旧 worlds.json → SQLite（库为空且旧文件存在时）。迁移后旧文件改名 .migrated 备份。 */
  #migrateFromJson(): void {
    const wf = join(this.#dir as string, 'worlds.json');
    if (!existsSync(wf)) return;
    const already = (this.#db.prepare('SELECT COUNT(*) AS c FROM worlds').get() as { c: number }).c;
    if (already > 0) return; // 已迁移过（库非空），不重复导入
    const data = JSON.parse(readFileSync(wf, 'utf8')) as {
      worlds: Array<{
        id: string;
        characters: Character[];
        inventory?: Record<string, number>;
        activeTask?: ActiveTask | null;
        props?: Array<Omit<WorldProp, 'state'> & { state?: WorldProp['state'] }>;
      }>;
    };
    for (const w of data.worlds ?? []) {
      // 方案 A：旧贴纸背包整体废弃，一次性置初始小红花（inventory 列改存 Wallet JSON）。
      this.#db
        .prepare('INSERT INTO worlds (id, inventory, active_task) VALUES (?, ?, ?)')
        .run(w.id, JSON.stringify(freshWallet()), w.activeTask ? JSON.stringify(w.activeTask) : null);
      const insChar = this.#db.prepare('INSERT INTO characters (id, world_id, data) VALUES (?, ?, ?)');
      for (const c of w.characters ?? []) insChar.run(c.id, w.id, JSON.stringify(c));
      const insProp = this.#db.prepare('INSERT INTO props (id, world_id, data) VALUES (?, ?, ?)');
      // 旧存档物件缺 state 视为已摆放（沿用旧 #load 兼容）
      for (const p of w.props ?? []) insProp.run(p.id, w.id, JSON.stringify({ ...p, state: p.state ?? 'placed' }));
    }
    renameSync(wf, `${wf}.migrated`);
  }

  /** 立绘 idle 动画记录从 sprite_anims.json 读回（每次启动，与 assets 一样走文件寻址，不进 DB）。 */
  #loadSpriteAnims(): void {
    const af = join(this.#dir as string, 'sprite_anims.json');
    if (!existsSync(af)) return;
    const anims = JSON.parse(readFileSync(af, 'utf8')) as Record<string, SpriteAnimRecord>;
    for (const hash of Object.keys(anims)) {
      const rec = anims[hash]!;
      // 重启时把"生成中"视为失败：进程已死、那次异步任务不会回来，避免永久 pending
      this.#spriteAnims.set(hash, rec.status === 'pending' ? { status: 'failed' } : rec);
    }
  }

  #persistSpriteAnims(): void {
    if (this.#dir === null) return;
    mkdirSync(this.#dir, { recursive: true });
    const obj: Record<string, SpriteAnimRecord> = {};
    for (const [hash, rec] of this.#spriteAnims) obj[hash] = rec;
    writeFileSync(join(this.#dir, 'sprite_anims.json'), JSON.stringify(obj));
  }

  #loadAssets(): void {
    const mf = join(this.#dir as string, 'assets.json');
    if (!existsSync(mf)) return;
    const mimes = JSON.parse(readFileSync(mf, 'utf8')) as Record<string, string>;
    for (const hash of Object.keys(mimes)) {
      const p = join(this.#assetsDir(), hash);
      if (existsSync(p)) this.#assets.set(hash, { bytes: new Uint8Array(readFileSync(p)), mime: mimes[hash]! });
    }
  }

  #persistAssetIndex(): void {
    if (this.#dir === null) return;
    const idx: Record<string, string> = {};
    for (const [hash, blob] of this.#assets) idx[hash] = blob.mime;
    writeFileSync(join(this.#dir, 'assets.json'), JSON.stringify(idx));
  }

  createWorld(id: string = randomUUID()): World {
    // 钱包不再随世界创建：每个玩家首次读到自己的钱包时才发初始小红花（见 getWallet）。
    // inventory / active_task 两列已废弃，保留仅为兼容旧库文件。
    this.#db
      .prepare('INSERT OR IGNORE INTO worlds (id, inventory, active_task) VALUES (?, ?, ?)')
      .run(id, '{}', null);
    return { id, characters: new Map(), props: new Map() };
  }

  getWorld(id: string): World | undefined {
    const row = this.#db.prepare('SELECT id, active_task FROM worlds WHERE id = ?').get(id) as
      | { id: string; active_task: string | null }
      | undefined;
    if (!row) return undefined;
    const characters = new Map<string, Character>();
    for (const c of this.listCharacters(id)) characters.set(c.id, c);
    const props = new Map<string, WorldProp>();
    for (const p of this.listProps(id)) props.set(p.id, p);
    return { id: row.id, characters, props };
  }

  #worldExists(id: string): boolean {
    return this.#db.prepare('SELECT 1 FROM worlds WHERE id = ?').get(id) !== undefined;
  }

  addCharacter(character: Character): void {
    if (!this.#worldExists(character.worldId)) throw new Error(`world not found: ${character.worldId}`);
    this.saveCharacter(character);
  }

  /** 角色状态变更后持久化（如 chatHistory/behaviorScript 更新）。整对象 UPSERT 一行。 */
  saveCharacter(character: Character): void {
    this.#db
      .prepare(
        'INSERT INTO characters (id, world_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(id) DO UPDATE SET world_id = excluded.world_id, data = excluded.data',
      )
      .run(character.id, character.worldId, JSON.stringify(character));
  }

  /** 语音生成的 SDF 物件：新增（tile 待客户端落位回报）。 */
  addProp(worldId: string, prop: WorldProp): void {
    if (!this.#worldExists(worldId)) throw new Error(`world not found: ${worldId}`);
    this.#saveProp(worldId, prop);
  }

  #getProp(worldId: string, propId: string): WorldProp | undefined {
    const row = this.#db.prepare('SELECT data FROM props WHERE id = ? AND world_id = ?').get(propId, worldId) as
      | { data: string }
      | undefined;
    return row ? (JSON.parse(row.data) as WorldProp) : undefined;
  }

  #saveProp(worldId: string, prop: WorldProp): void {
    this.#db
      .prepare(
        'INSERT INTO props (id, world_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(id) DO UPDATE SET world_id = excluded.world_id, data = excluded.data',
      )
      .run(prop.id, worldId, JSON.stringify(prop));
  }

  /** 客户端落位回报：记下物件的 tile，重载世界时按此恢复。 */
  setPropTile(worldId: string, propId: string, tile: [number, number]): boolean {
    const prop = this.#getProp(worldId, propId);
    if (!prop) return false;
    prop.tile = tile;
    this.#saveProp(worldId, prop);
    return true;
  }

  /** 收纳：已摆物件收进收集册物品页（tile 清空）。不存在或已在背包 → false 不动账。 */
  storeProp(worldId: string, propId: string): boolean {
    const prop = this.#getProp(worldId, propId);
    if (!prop || prop.state !== 'placed') return false;
    prop.state = 'bagged';
    prop.tile = null;
    this.#saveProp(worldId, prop);
    return true;
  }

  /** 摆出：背包物件放回世界指定 tile（客户端已过占地校验）。不存在或不在背包 → false。 */
  takeProp(worldId: string, propId: string, tile: [number, number]): boolean {
    const prop = this.#getProp(worldId, propId);
    if (!prop || prop.state !== 'bagged') return false;
    prop.state = 'placed';
    prop.tile = tile;
    this.#saveProp(worldId, prop);
    return true;
  }

  /** 挪位：已摆物件换 tile（长按拖拽后回报）。不存在或在背包 → false。 */
  movePropTile(worldId: string, propId: string, tile: [number, number]): boolean {
    const prop = this.#getProp(worldId, propId);
    if (!prop || prop.state !== 'placed') return false;
    prop.tile = tile;
    this.#saveProp(worldId, prop);
    return true;
  }

  /**
   * 世界里的物件。传 sceneId 则只返回该场景的物件（缺 sceneId 的存量物件按 DEFAULT_SCENE 归入）；
   * 不传 = 全世界所有场景（保持既有调用点行为不变）。
   */
  listProps(worldId: string, sceneId?: string): WorldProp[] {
    const rows = this.#db.prepare('SELECT data FROM props WHERE world_id = ?').all(worldId) as { data: string }[];
    const all = rows.map((r) => JSON.parse(r.data) as WorldProp);
    if (sceneId === undefined) return all;
    return all.filter((p) => (p.sceneId ?? DEFAULT_SCENE) === sceneId);
  }

  /**
   * 客户端 world_info 上报的地点名。**兼容路径**：场景已入库时不再需要它。
   * 保留是因为老客户端仍会上报，且 POI 尚未入库的环境要能照常派委托。
   */
  setLocations(worldId: string, names: string[]): void {
    this.#locations.set(worldId, names);
  }

  /**
   * 世界的地点名（喂给意图 LLM 让「去某地」说的是真实地名）。
   * 权威来源是 scenes.pois——服务端说了算，不再依赖客户端上报（那个方向是反的）。
   * POI 还没入库时回退到客户端上报的内存清单，保证旧环境不退化。
   *
   * 多场景时这里会把所有场景的地点摊平，委托可能指向别的场景。
   * 步骤⑤真做 portal 时要按玩家当前场景过滤（见 docs/multi-scene-design.md 待确认项）。
   */
  getLocations(worldId: string): string[] {
    const fromScenes = this.listScenes(worldId)
      .flatMap((s) => s.pois.map((p) => p.name))
      .filter((n) => n.length > 0);
    if (fromScenes.length > 0) return [...new Set(fromScenes)];
    return this.#locations.get(worldId) ?? [];
  }

  // ── 场景（模型 B：world 含多 scene，见 docs/multi-scene-design.md）──────────────

  /** 登记/更新一个场景。地形二进制先经 putAsset 入库，这里只记它的 hash。 */
  upsertScene(scene: Scene): void {
    if (!this.#worldExists(scene.worldId)) throw new Error(`world not found: ${scene.worldId}`);
    this.#db
      .prepare(
        'INSERT INTO scenes (world_id, scene_id, name, terrain_asset, grid_tiles, pois, portals) VALUES (?, ?, ?, ?, ?, ?, ?) ' +
          'ON CONFLICT(world_id, scene_id) DO UPDATE SET name = excluded.name, terrain_asset = excluded.terrain_asset, ' +
          'grid_tiles = excluded.grid_tiles, pois = excluded.pois, portals = excluded.portals',
      )
      .run(
        scene.worldId, scene.sceneId, scene.name, scene.terrainAsset, scene.gridTiles,
        JSON.stringify(scene.pois), JSON.stringify(scene.portals),
      );
  }

  #rowToScene(r: SceneRow): Scene {
    return {
      worldId: r.world_id,
      sceneId: r.scene_id,
      name: r.name,
      terrainAsset: r.terrain_asset,
      gridTiles: r.grid_tiles,
      pois: JSON.parse(r.pois) as ScenePoi[],
      portals: JSON.parse(r.portals) as ScenePortal[],
    };
  }

  getScene(worldId: string, sceneId: string): Scene | undefined {
    const row = this.#db.prepare('SELECT * FROM scenes WHERE world_id = ? AND scene_id = ?').get(worldId, sceneId) as
      | SceneRow
      | undefined;
    return row ? this.#rowToScene(row) : undefined;
  }

  listScenes(worldId: string): Scene[] {
    const rows = this.#db.prepare('SELECT * FROM scenes WHERE world_id = ? ORDER BY scene_id').all(worldId) as unknown as SceneRow[];
    return rows.map((r) => this.#rowToScene(r));
  }

  // ── 奖赏系统：小红花钱包 + 进行中委托（均按 (worldId, playerId) 维度）────────────────
  //
  // 历史：两者原本挂在 worlds 表（inventory / active_task 列），全世界共用一份——
  // 所有小朋友共享同一个钱包，且 A 接了委托后 B 再也拿不到委托（tasks.ts 的空位判定）。
  // 现已迁到 wallets / player_tasks 两张表。worlds 的那两列就此废弃，不再读写。
  //
  // 匿名兜底：playerId 为空（老客户端 / 直连调试，不带 playerId）统一落到 ANON_PLAYER 键，
  // 行为退化成「所有匿名连接共用一个钱包」——与改动前一致，不会因为缺身份就崩。

  #walletKey(playerId: string): string {
    return playerId || ANON_PLAYER;
  }

  #setWallet(worldId: string, playerId: string, w: Wallet): void {
    this.#db
      .prepare(
        'INSERT INTO wallets (world_id, player_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(world_id, player_id) DO UPDATE SET data = excluded.data',
      )
      .run(worldId, this.#walletKey(playerId), JSON.stringify(w));
  }

  /**
   * 读某玩家在某世界的钱包。没有行 → 发初始小红花并落库（懒初始化，每个小朋友各自一份）。
   * 世界不存在返回一个空钱包（不写库）。
   */
  getWallet(worldId: string, playerId: string): Wallet {
    if (!this.#worldExists(worldId)) return { flowers: 0, stampProgress: 0, stampsTotal: 0 };
    const row = this.#db
      .prepare('SELECT data FROM wallets WHERE world_id = ? AND player_id = ?')
      .get(worldId, this.#walletKey(playerId)) as { data: string } | undefined;
    let raw: unknown = null;
    if (row) {
      try {
        raw = JSON.parse(row.data);
      } catch {
        raw = null;
      }
    }
    const { wallet, migrated } = coerceWallet(raw);
    // 首次见到这个玩家（或行损坏）→ 固化初始钱包，之后每次读到的都是同一份
    if (migrated) this.#setWallet(worldId, playerId, wallet);
    return wallet;
  }

  /**
   * 盖 1 章：stampsTotal++，攒满 STAMPS_PER_FLOWER 结算 1 花（受 MAX_FLOWERS 上限；满 9 溢出见 settleWallet）。
   * 返回是否因此升了花 + 结算后的钱包。世界不存在则 flowerGained=false。
   */
  addStamp(worldId: string, playerId: string): { flowerGained: boolean; wallet: Wallet } {
    if (!this.#worldExists(worldId)) return { flowerGained: false, wallet: { flowers: 0, stampProgress: 0, stampsTotal: 0 } };
    const w = this.getWallet(worldId, playerId);
    w.stampsTotal += 1;
    w.stampProgress += 1;
    const flowerGained = settleWallet(w);
    this.#setWallet(worldId, playerId, w);
    return { flowerGained, wallet: w };
  }

  /** 花 n 朵小红花（造物/造角色）。够扣则扣、腾出格子后立即补升满 9 溢出的待兑换组，返回 true；不够返回 false 且不动账。 */
  spendFlower(worldId: string, playerId: string, n = 1): boolean {
    if (!this.#worldExists(worldId)) return false;
    const w = this.getWallet(worldId, playerId);
    if (w.flowers < n) return false;
    w.flowers -= n;
    settleWallet(w); // 满 9 溢出停在待兑换的那一组，腾出格子后立即补升
    this.#setWallet(worldId, playerId, w);
    return true;
  }

  /** 退还/补发 n 朵小红花（造失败退款，受 MAX_FLOWERS 上限，多余丢弃）。返回结算后的钱包。 */
  refundFlower(worldId: string, playerId: string, n = 1): Wallet {
    const w = this.getWallet(worldId, playerId);
    if (!this.#worldExists(worldId)) return w;
    w.flowers = Math.min(MAX_FLOWERS, w.flowers + n);
    this.#setWallet(worldId, playerId, w);
    return w;
  }

  /** 管理用：把小红花数直接设为 n（夹紧到 0..MAX_FLOWERS），盖章进度不动。返回结算后的钱包。世界不存在则原样返回空钱包。 */
  setFlowers(worldId: string, playerId: string, n: number): Wallet {
    const w = this.getWallet(worldId, playerId);
    if (!this.#worldExists(worldId)) return w;
    w.flowers = Math.max(0, Math.min(MAX_FLOWERS, Math.floor(n)));
    this.#setWallet(worldId, playerId, w);
    return w;
  }

  /** 列出某世界里所有有钱包的玩家（debug 后台用）。匿名键原样出现在结果里。 */
  listWallets(worldId: string): { playerId: string; wallet: Wallet }[] {
    const rows = this.#db
      .prepare('SELECT player_id, data FROM wallets WHERE world_id = ? ORDER BY player_id')
      .all(worldId) as { player_id: string; data: string }[];
    return rows.map((r) => ({ playerId: r.player_id, wallet: coerceWallet(JSON.parse(r.data)).wallet }));
  }

  getActiveTask(worldId: string, playerId: string): ActiveTask | null {
    const row = this.#db
      .prepare('SELECT data FROM player_tasks WHERE world_id = ? AND player_id = ?')
      .get(worldId, this.#walletKey(playerId)) as { data: string } | undefined;
    return row ? (JSON.parse(row.data) as ActiveTask) : null;
  }

  /** 设进行中委托；task=null 直接删行（「无委托」不留空行）。 */
  setActiveTask(worldId: string, playerId: string, task: ActiveTask | null): void {
    if (!this.#worldExists(worldId)) return;
    const key = this.#walletKey(playerId);
    if (task === null) {
      this.#db.prepare('DELETE FROM player_tasks WHERE world_id = ? AND player_id = ?').run(worldId, key);
      return;
    }
    this.#db
      .prepare(
        'INSERT INTO player_tasks (world_id, player_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(world_id, player_id) DO UPDATE SET data = excluded.data',
      )
      .run(worldId, key, JSON.stringify(task));
  }

  /** 列出某世界里所有玩家的进行中委托（debug 后台用）。 */
  listActiveTasks(worldId: string): { playerId: string; task: ActiveTask }[] {
    const rows = this.#db
      .prepare('SELECT player_id, data FROM player_tasks WHERE world_id = ? ORDER BY player_id')
      .all(worldId) as { player_id: string; data: string }[];
    return rows.map((r) => ({ playerId: r.player_id, task: JSON.parse(r.data) as ActiveTask }));
  }

  /**
   * 世界里的角色。传 sceneId 则只返回该场景的角色（缺 sceneId 的存量角色按 DEFAULT_SCENE 归入）；
   * 不传 = 全世界所有场景（保持既有调用点行为不变）。
   */
  listCharacters(worldId: string, sceneId?: string): Character[] {
    const rows = this.#db.prepare('SELECT data FROM characters WHERE world_id = ?').all(worldId) as { data: string }[];
    const all = rows.map((r) => JSON.parse(r.data) as Character);
    if (sceneId === undefined) return all;
    return all.filter((c) => (c.sceneId ?? DEFAULT_SCENE) === sceneId);
  }

  getCharacter(worldId: string, characterId: string): Character | undefined {
    const row = this.#db
      .prepare('SELECT data FROM characters WHERE id = ? AND world_id = ?')
      .get(characterId, worldId) as { data: string } | undefined;
    return row ? (JSON.parse(row.data) as Character) : undefined;
  }

  /**
   * 角色所在 tile 的落位回报（positions_report）。空间权威在客户端，服务端只记最后位置供重载读回。
   * 角色不存在 → false 不动账。tile 合法性由调用方（server.ts）先行校验。
   * sceneId 给了就一并更新角色所在场景——上报只带当前场景里的角色，故场景跟着位置走（模型 B）。
   */
  setCharacterTile(worldId: string, characterId: string, tile: TilePos, sceneId?: string): boolean {
    const character = this.getCharacter(worldId, characterId);
    if (!character) return false;
    character.position = tile;
    if (sceneId !== undefined) character.sceneId = sceneId;
    this.saveCharacter(character);
    return true;
  }

  // ── 玩家实体（面向 MMO；身份=设备端 UUID，无鉴权，见 types.Player）──────────

  /**
   * 玩家在某世界某场景的落位回报。玩家档案未建（首次进世界还没上报 profile）→ false 不动账。
   * 键必须是 (world, scene, player)：同一个 tile 坐标在不同场景是完全不同的地方。
   */
  setPlayerTile(worldId: string, sceneId: string, playerId: string, tile: TilePos): boolean {
    if (!this.getPlayer(playerId)) return false;
    this.#db
      .prepare(
        'INSERT INTO player_positions (world_id, scene_id, player_id, tile_x, tile_y) VALUES (?, ?, ?, ?, ?) ' +
          'ON CONFLICT(world_id, scene_id, player_id) DO UPDATE SET tile_x = excluded.tile_x, tile_y = excluded.tile_y',
      )
      .run(worldId, sceneId, playerId, tile.tileX, tile.tileY);
    return true;
  }

  /** 玩家在某世界某场景的最后位置。没去过 → undefined（客户端按小神仙旁降生）。 */
  getPlayerTile(worldId: string, sceneId: string, playerId: string): TilePos | undefined {
    const row = this.#db
      .prepare('SELECT tile_x, tile_y FROM player_positions WHERE world_id = ? AND scene_id = ? AND player_id = ?')
      .get(worldId, sceneId, playerId) as { tile_x: number; tile_y: number } | undefined;
    return row ? { tileX: row.tile_x, tileY: row.tile_y } : undefined;
  }

  /**
   * 存量迁移：老档案把位置塞在 players.data.position（无世界、无场景）。
   * 单场景时代那批坐标只可能属于 default 世界的 village 场景，一次性搬过去并清掉旧字段。幂等。
   */
  #migrateLegacyPlayerPositions(): void {
    const rows = this.#db.prepare('SELECT id, data FROM players').all() as { id: string; data: string }[];
    for (const r of rows) {
      const p = JSON.parse(r.data) as Player & { position?: TilePos };
      if (!p.position) continue;
      const t = p.position;
      if (Number.isInteger(t.tileX) && Number.isInteger(t.tileY)) {
        this.#db
          .prepare('INSERT OR IGNORE INTO player_positions (world_id, scene_id, player_id, tile_x, tile_y) VALUES (?, ?, ?, ?, ?)')
          .run('default', 'village', p.id, t.tileX, t.tileY);
      }
      delete p.position;
      this.#db.prepare('UPDATE players SET data = ? WHERE id = ?').run(JSON.stringify(p), r.id);
    }
  }

  /**
   * 存量迁移：单场景时代的角色/物件 blob 里没有 sceneId 字段。
   * 那批全部隐含属于 village，一次性补写 sceneId='village' 让数据说清自己在哪个场景。
   * 已有 sceneId 的行跳过 → 幂等（第二次开库不改任何值）。
   */
  #migrateLegacyEntityScenes(): void {
    const backfill = (table: 'characters' | 'props') => {
      const rows = this.#db.prepare(`SELECT id, data FROM ${table}`).all() as { id: string; data: string }[];
      const upd = this.#db.prepare(`UPDATE ${table} SET data = ? WHERE id = ?`);
      for (const r of rows) {
        const obj = JSON.parse(r.data) as { sceneId?: string };
        if (obj.sceneId !== undefined) continue;
        obj.sceneId = DEFAULT_SCENE;
        upd.run(JSON.stringify(obj), r.id);
      }
    };
    backfill('characters');
    backfill('props');
  }

  /** 登记/更新玩家档案（首见即建，再见即更）。整对象 UPSERT 一行。 */
  upsertPlayer(player: Player): void {
    this.#db
      .prepare('INSERT INTO players (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data')
      .run(player.id, JSON.stringify(player));
  }

  getPlayer(id: string): Player | undefined {
    const row = this.#db.prepare('SELECT data FROM players WHERE id = ?').get(id) as { data: string } | undefined;
    return row ? (JSON.parse(row.data) as Player) : undefined;
  }

  listPlayers(): Player[] {
    const rows = this.#db.prepare('SELECT data FROM players').all() as { data: string }[];
    return rows.map((r) => JSON.parse(r.data) as Player);
  }

  // ── 长期记忆（P3：结构化，按 owner NPC × aboutPlayer 维度；见 types.MemoryItem）──────

  /** 旧存量 Character.memory[] → memories 表（aboutPlayer='' 未绑定历史）。幂等：搬完清空 memory[]。 */
  #migrateLegacyMemories(): void {
    const rows = this.#db.prepare('SELECT data FROM characters').all() as { data: string }[];
    for (const row of rows) {
      const c = JSON.parse(row.data) as Character;
      if (!Array.isArray(c.memory) || c.memory.length === 0) continue;
      for (const text of c.memory) {
        if (typeof text === 'string' && text.trim()) {
          this.addMemory(c.id, { text: text.trim(), kind: 'event', aboutPlayer: '', ts: 0 });
        }
      }
      c.memory = []; // 清空，避免重复迁移（幂等）
      this.#db.prepare('UPDATE characters SET data = ? WHERE id = ?').run(JSON.stringify(c), c.id);
    }
  }

  /** 追加一条长期记忆。 */
  addMemory(ownerCharacterId: string, item: MemoryItem): void {
    this.#db
      .prepare(
        'INSERT INTO memories (owner_character_id, about_player_id, about_character_id, text, kind, ts) VALUES (?, ?, ?, ?, ?, ?)',
      )
      .run(ownerCharacterId, item.aboutPlayer, item.aboutCharacter ?? null, item.text, item.kind, item.ts);
  }

  /** 取某 NPC 关于某玩家的记忆（含 aboutPlayer='' 的未绑定历史记忆），按插入顺序。 */
  getMemories(ownerCharacterId: string, aboutPlayerId: string): MemoryItem[] {
    const rows = this.#db
      .prepare(
        "SELECT about_player_id, about_character_id, text, kind, ts FROM memories WHERE owner_character_id = ? AND about_player_id IN (?, '') ORDER BY id",
      )
      .all(ownerCharacterId, aboutPlayerId) as {
      about_player_id: string;
      about_character_id: string | null;
      text: string;
      kind: string;
      ts: number;
    }[];
    return rows.map((r) => ({
      text: r.text,
      kind: r.kind as MemoryItem['kind'],
      aboutPlayer: r.about_player_id,
      aboutCharacter: r.about_character_id ?? undefined,
      ts: r.ts,
    }));
  }

  // ── 对话历史 chat_turns（P5：从 Character.chatHistory[] 拆独立表，按 (NPC,玩家) 分页/裁剪）──────

  /** 单角色×单玩家保留的对话轮上限（child/npc 各算一条）；超出裁剪最旧。 */
  static readonly CHAT_TURN_CAP = 40;

  /** 旧存量 Character.chatHistory[] → chat_turns（player_id='' 未绑定历史）。幂等：搬完清空。 */
  #migrateLegacyChatHistory(): void {
    const rows = this.#db.prepare('SELECT data FROM characters').all() as { data: string }[];
    for (const row of rows) {
      const c = JSON.parse(row.data) as Character;
      if (!Array.isArray(c.chatHistory) || c.chatHistory.length === 0) continue;
      for (const t of c.chatHistory) {
        if (t && (t.role === 'child' || t.role === 'npc') && typeof t.text === 'string') {
          this.addChatTurn(c.id, '', t.role, t.text, typeof t.ts === 'number' ? t.ts : 0);
        }
      }
      c.chatHistory = []; // 清空，避免重复迁移（幂等）
      this.#db.prepare('UPDATE characters SET data = ? WHERE id = ?').run(JSON.stringify(c), c.id);
    }
  }

  /** 追加一轮对话；写后按 (NPC,玩家) 裁剪到 CHAT_TURN_CAP（挤出最旧）。 */
  addChatTurn(characterId: string, playerId: string, role: ChatTurn['role'], text: string, ts = 0): void {
    this.#db
      .prepare('INSERT INTO chat_turns (character_id, player_id, role, text, ts) VALUES (?, ?, ?, ?, ?)')
      .run(characterId, playerId, role, text, ts);
    // 裁剪：删掉超出 CAP 的最旧行（按 id 递增即时间序）。抽完记忆的旧 turn 无需保留连贯上下文。
    this.#db
      .prepare(
        'DELETE FROM chat_turns WHERE character_id = ? AND player_id = ? AND id NOT IN ' +
          '(SELECT id FROM chat_turns WHERE character_id = ? AND player_id = ? ORDER BY id DESC LIMIT ?)',
      )
      .run(characterId, playerId, characterId, playerId, WorldStore.CHAT_TURN_CAP);
  }

  /** 取某 NPC×某玩家最近 limit 轮对话（含 player_id='' 未绑定历史），按时间正序（最旧在前）。 */
  getRecentTurns(characterId: string, playerId: string, limit: number): ChatTurn[] {
    const rows = this.#db
      .prepare(
        "SELECT role, text, ts FROM chat_turns WHERE character_id = ? AND player_id IN (?, '') " +
          'ORDER BY id DESC LIMIT ?',
      )
      .all(characterId, playerId, limit) as { role: string; text: string; ts: number }[];
    return rows
      .map((r) => ({ role: r.role as ChatTurn['role'], text: r.text, ts: r.ts }))
      .reverse(); // DESC 取近 N 条后翻回正序
  }

  // ── 会话 Visit（进世界→离开为一段，作会话结束批量抽记忆的边界；见 types.Visit）──────

  /** 开一段会话，返回 visitId（ended_at 置空=进行中）。startedAt 由调用方传（server 用 Date.now）。 */
  startVisit(worldId: string, playerId: string, startedAt: number): number {
    const info = this.#db
      .prepare('INSERT INTO visits (world_id, player_id, started_at, ended_at) VALUES (?, ?, ?, NULL)')
      .run(worldId, playerId, startedAt);
    return Number(info.lastInsertRowid);
  }

  /** 收尾一段会话（leave_world 显式退出 / socket.close 兜底）。已收尾的不覆盖。 */
  endVisit(id: number, endedAt: number): void {
    this.#db.prepare('UPDATE visits SET ended_at = ? WHERE id = ? AND ended_at IS NULL').run(endedAt, id);
  }

  /** 查会话记录（P6 只读后台用；worldId 省略=全部），按开始时间倒序。 */
  listVisits(worldId?: string): Visit[] {
    const rows = (
      worldId === undefined
        ? this.#db.prepare('SELECT id, world_id, player_id, started_at, ended_at FROM visits ORDER BY started_at DESC').all()
        : this.#db
            .prepare('SELECT id, world_id, player_id, started_at, ended_at FROM visits WHERE world_id = ? ORDER BY started_at DESC')
            .all(worldId)
    ) as { id: number; world_id: string; player_id: string; started_at: number; ended_at: number | null }[];
    return rows.map((r) => ({
      id: r.id,
      worldId: r.world_id,
      playerId: r.player_id,
      startedAt: r.started_at,
      endedAt: r.ended_at,
    }));
  }

  // ── 只读观测（P6 调试后台；不改状态，直连查询）────────────────────────────

  /** 列出所有世界，每个世界带上各玩家的钱包与进行中委托（debug 后台用）。 */
  listWorlds(): {
    id: string;
    wallets: { playerId: string; wallet: Wallet }[];
    activeTasks: { playerId: string; task: ActiveTask }[];
  }[] {
    const rows = this.#db.prepare('SELECT id FROM worlds ORDER BY id').all() as { id: string }[];
    return rows.map((r) => ({
      id: r.id,
      wallets: this.listWallets(r.id),
      activeTasks: this.listActiveTasks(r.id),
    }));
  }

  /** 列出某 NPC 的全部记忆（跨所有玩家，含未绑定历史），按插入顺序。 */
  listMemories(ownerCharacterId: string): MemoryItem[] {
    const rows = this.#db
      .prepare(
        'SELECT about_player_id, about_character_id, text, kind, ts FROM memories WHERE owner_character_id = ? ORDER BY id',
      )
      .all(ownerCharacterId) as {
      about_player_id: string;
      about_character_id: string | null;
      text: string;
      kind: string;
      ts: number;
    }[];
    return rows.map((r) => ({
      text: r.text,
      kind: r.kind as MemoryItem['kind'],
      aboutPlayer: r.about_player_id,
      aboutCharacter: r.about_character_id ?? undefined,
      ts: r.ts,
    }));
  }

  /** 列出某 NPC 的全部对话轮（跨所有玩家，带 playerId），按时间正序。 */
  listChatTurns(characterId: string): { playerId: string; role: ChatTurn['role']; text: string; ts: number }[] {
    const rows = this.#db
      .prepare('SELECT player_id, role, text, ts FROM chat_turns WHERE character_id = ? ORDER BY id')
      .all(characterId) as { player_id: string; role: string; text: string; ts: number }[];
    return rows.map((r) => ({ playerId: r.player_id, role: r.role as ChatTurn['role'], text: r.text, ts: r.ts }));
  }

  /** 存入资源，返回内容寻址 hash。 */
  putAsset(blob: ImageBlob): string {
    const hash = createHash('sha256').update(blob.bytes).digest('hex').slice(0, 16);
    this.#assets.set(hash, blob);
    if (this.#dir !== null) {
      mkdirSync(this.#assetsDir(), { recursive: true });
      writeFileSync(join(this.#assetsDir(), hash), Buffer.from(blob.bytes));
      this.#persistAssetIndex();
    }
    return hash;
  }

  getAsset(hash: string): ImageBlob | undefined {
    return this.#assets.get(hash);
  }

  /** 取某立绘的 idle 动画记录（无则 undefined，客户端据此保留静态或轮询）。 */
  getSpriteAnim(spriteHash: string): SpriteAnimRecord | undefined {
    return this.#spriteAnims.get(spriteHash);
  }

  setSpriteAnimPending(spriteHash: string): void {
    this.#spriteAnims.set(spriteHash, { status: 'pending' });
    this.#persistSpriteAnims();
  }

  setSpriteAnimReady(spriteHash: string, animAsset: string, meta: SpriteSheetMeta): void {
    this.#spriteAnims.set(spriteHash, { status: 'ready', animAsset, meta });
    this.#persistSpriteAnims();
  }

  setSpriteAnimFailed(spriteHash: string): void {
    this.#spriteAnims.set(spriteHash, { status: 'failed' });
    this.#persistSpriteAnims();
  }
}
