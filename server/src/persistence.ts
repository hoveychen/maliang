import { createHash, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ActiveTask, Character, MemoryItem, Player, Visit, WorldProp } from './types.ts';
import type { ImageBlob } from './adapters/types.ts';

export interface World {
  id: string;
  characters: Map<string, Character>;
  /** 玩家的贴纸收集册：贴纸 id → 数量（委托奖励累积，可转赠扣减）。 */
  inventory: Record<string, number>;
  /** 进行中的 NPC 委托（至多一个，见 types.ActiveTask）。 */
  activeTask: ActiveTask | null;
  /** 语音生成的 SDF 物件（id → WorldProp，tile 为落位回报）。 */
  props: Map<string, WorldProp>;
}

/**
 * 世界状态 + 生成的 sprite 资源存储。
 * 传 dataDir → 持久化到 SQLite（<dataDir>/world.db，assets/ + assets.json 清单沿用文件寻址）；
 * 不传 → 内存 SQLite（`:memory:`，测试用）。
 *
 * 存储布局（P1：只换介质，对外 API 与返回结构不变）：
 *   worlds(id, inventory JSON, active_task JSON|null)
 *   characters(id PK, world_id, data JSON)   ← Character 整对象存一行（memory/chatHistory 暂 JSON 内嵌，表拆分留 P3/P5）
 *   props(id PK, world_id, data JSON)
 * saveCharacter 从「全量重写 worlds.json」变为「UPDATE 一行」，根治 chatHistory 膨胀拖慢落盘。
 * 首启若存在旧 worlds.json 且库为空 → 一次性迁移后把 worlds.json 改名 .migrated 备份。
 */
export class WorldStore {
  readonly #dir: string | null;
  readonly #db: DatabaseSync;
  readonly #assets = new Map<string, ImageBlob>();
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
      this.#loadAssets();
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
    `);
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
      this.#db
        .prepare('INSERT INTO worlds (id, inventory, active_task) VALUES (?, ?, ?)')
        .run(w.id, JSON.stringify(w.inventory ?? {}), w.activeTask ? JSON.stringify(w.activeTask) : null);
      const insChar = this.#db.prepare('INSERT INTO characters (id, world_id, data) VALUES (?, ?, ?)');
      for (const c of w.characters ?? []) insChar.run(c.id, w.id, JSON.stringify(c));
      const insProp = this.#db.prepare('INSERT INTO props (id, world_id, data) VALUES (?, ?, ?)');
      // 旧存档物件缺 state 视为已摆放（沿用旧 #load 兼容）
      for (const p of w.props ?? []) insProp.run(p.id, w.id, JSON.stringify({ ...p, state: p.state ?? 'placed' }));
    }
    renameSync(wf, `${wf}.migrated`);
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
    this.#db
      .prepare('INSERT OR IGNORE INTO worlds (id, inventory, active_task) VALUES (?, ?, ?)')
      .run(id, '{}', null);
    return { id, characters: new Map(), inventory: {}, activeTask: null, props: new Map() };
  }

  getWorld(id: string): World | undefined {
    const row = this.#db.prepare('SELECT id, inventory, active_task FROM worlds WHERE id = ?').get(id) as
      | { id: string; inventory: string; active_task: string | null }
      | undefined;
    if (!row) return undefined;
    const characters = new Map<string, Character>();
    for (const c of this.listCharacters(id)) characters.set(c.id, c);
    const props = new Map<string, WorldProp>();
    for (const p of this.listProps(id)) props.set(p.id, p);
    return {
      id: row.id,
      characters,
      inventory: JSON.parse(row.inventory) as Record<string, number>,
      activeTask: row.active_task ? (JSON.parse(row.active_task) as ActiveTask) : null,
      props,
    };
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

  listProps(worldId: string): WorldProp[] {
    const rows = this.#db.prepare('SELECT data FROM props WHERE world_id = ?').all(worldId) as { data: string }[];
    return rows.map((r) => JSON.parse(r.data) as WorldProp);
  }

  /** 客户端上报的世界地点名（喂给意图 LLM 让「去某地」说的是真实地名）。 */
  setLocations(worldId: string, names: string[]): void {
    this.#locations.set(worldId, names);
  }

  getLocations(worldId: string): string[] {
    return this.#locations.get(worldId) ?? [];
  }

  // ── 奖赏系统：玩家贴纸背包 + 进行中委托 ──────────────────────────────────

  #getInventoryRow(worldId: string): Record<string, number> | undefined {
    const row = this.#db.prepare('SELECT inventory FROM worlds WHERE id = ?').get(worldId) as
      | { inventory: string }
      | undefined;
    return row ? (JSON.parse(row.inventory) as Record<string, number>) : undefined;
  }

  #setInventory(worldId: string, inv: Record<string, number>): void {
    this.#db.prepare('UPDATE worlds SET inventory = ? WHERE id = ?').run(JSON.stringify(inv), worldId);
  }

  getInventory(worldId: string): Record<string, number> {
    return this.#getInventoryRow(worldId) ?? {};
  }

  /** 发贴纸（委托奖励）。 */
  addSticker(worldId: string, stickerId: string, n = 1): void {
    const inv = this.#getInventoryRow(worldId);
    if (!inv) return;
    inv[stickerId] = (inv[stickerId] ?? 0) + n;
    this.#setInventory(worldId, inv);
  }

  /** 扣贴纸（转赠/gift 委托）。不够扣返回 false 且不动账。 */
  removeSticker(worldId: string, stickerId: string, n = 1): boolean {
    const inv = this.#getInventoryRow(worldId);
    if (!inv || (inv[stickerId] ?? 0) < n) return false;
    inv[stickerId] = (inv[stickerId] ?? 0) - n;
    if (inv[stickerId] === 0) delete inv[stickerId];
    this.#setInventory(worldId, inv);
    return true;
  }

  getActiveTask(worldId: string): ActiveTask | null {
    const row = this.#db.prepare('SELECT active_task FROM worlds WHERE id = ?').get(worldId) as
      | { active_task: string | null }
      | undefined;
    return row && row.active_task ? (JSON.parse(row.active_task) as ActiveTask) : null;
  }

  setActiveTask(worldId: string, task: ActiveTask | null): void {
    if (!this.#worldExists(worldId)) return;
    this.#db.prepare('UPDATE worlds SET active_task = ? WHERE id = ?').run(task ? JSON.stringify(task) : null, worldId);
  }

  listCharacters(worldId: string): Character[] {
    const rows = this.#db.prepare('SELECT data FROM characters WHERE world_id = ?').all(worldId) as { data: string }[];
    return rows.map((r) => JSON.parse(r.data) as Character);
  }

  getCharacter(worldId: string, characterId: string): Character | undefined {
    const row = this.#db
      .prepare('SELECT data FROM characters WHERE id = ? AND world_id = ?')
      .get(characterId, worldId) as { data: string } | undefined;
    return row ? (JSON.parse(row.data) as Character) : undefined;
  }

  // ── 玩家实体（面向 MMO；身份=设备端 UUID，无鉴权，见 types.Player）──────────

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
}
