import { createHash, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ActiveTask, ChatTurn, Character, CharacterDef, CharacterInstanceRecord, DeviceSnapshot, Familiarity, ItemDef, MemoryItem, Player, PlayerOnboardingProfile, Scene, ScenePoi, ScenePortal, StoryProgress, TilePos, Visit, Wallet, WorldProp } from './types.ts';
import { ANON_PLAYER, DEFAULT_SCENE, FAIRY_NAME, FAIRY_PERSONALITY, INITIAL_FLOWERS, LOCOMOTION_ABILITIES, MAX_FLOWERS, STAMPS_PER_FLOWER } from './types.ts';
import { coerceRelationship, deriveFamiliarity } from './social.ts';
import { FAIRY_VOICE } from './voice_catalog.ts';
import { creationItemDef, getBuiltinItem } from './items.ts';
import { applyTileEdits } from './terrain_edit.ts';
import { decodeTerrain, encodeTerrain } from './terrain.ts';
import type { ClipName, ImageBlob } from './adapters/types.ts';
import type { SpriteSheetMeta } from './sprite_sheet.ts';
import { sanitizeLevels, type DeviceSample, type Levels } from './device_profile.ts';

/** 现网单例世界 id（存量玩家档、seed 脚本、模板提升的内容来源）。 */
export const DEFAULT_WORLD_ID = 'default';
/** 模板世界 id（作者面：摆放置、不接客；每人一世界从这里复制放置）。世界模板架构 v2 §4。 */
export const TEMPLATE_WORLD_ID = 'template';
/** 每人一世界的 id 前缀（w_<playerId>），绑玩家、非匿名 UUID（防空壳，§7）。 */
export const PLAYER_WORLD_PREFIX = 'w_';
/** 测试沙箱世界的 id 前缀（sandbox_<uuid>），临时、可随手 DELETE（§5 P4）。 */
export const SANDBOX_WORLD_PREFIX = 'sandbox_';

/** 初始钱包（冷启动/旧档迁移）：预置初始小红花，零盖章进度。 */
function freshWallet(): Wallet {
  return { flowers: INITIAL_FLOWERS, stampProgress: 0, stampsTotal: 0, hearts: 0 };
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
    const hearts = Math.max(0, Math.floor(Number((r as { hearts?: unknown }).hearts) || 0));
    return { wallet: { flowers, stampProgress, stampsTotal, hearts }, migrated: false };
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
 * 把持久化里读到的原始值归一成 StoryProgress。非法/损坏的册整个丢弃——最坏结果是
 * 那册从头重看一遍，不该因此崩。performing/rewarded 瞬态读回一律归稳态
 * （崩溃时若真落了库，等价于「断线回幕首」的既定语义）。
 */
function coerceStoryProgress(raw: unknown): StoryProgress {
  const out: StoryProgress = { books: {} };
  const books = raw && typeof raw === 'object' ? (raw as { books?: unknown }).books : null;
  if (!books || typeof books !== 'object') return out;
  for (const [bookId, bp] of Object.entries(books as Record<string, unknown>)) {
    if (!bp || typeof bp !== 'object') continue;
    const b = bp as { chapter?: unknown; state?: unknown; rewarded?: unknown; settled?: unknown; activeChapter?: unknown };
    const chapter = Math.max(0, Math.floor(Number(b.chapter) || 0));
    const state = b.state === 'interacting' ? 'interacting' : 'idle';
    const rewarded = Array.isArray(b.rewarded)
      ? [...new Set(b.rewarded.filter((n): n is number => Number.isInteger(n) && (n as number) >= 0))]
      : [];
    const activeChapter =
      state === 'interacting' && Number.isInteger(b.activeChapter) && (b.activeChapter as number) >= 0
        ? (b.activeChapter as number)
        : undefined;
    out.books[bookId] = { chapter, state, rewarded, settled: b.settled === true, ...(activeChapter !== undefined ? { activeChapter } : {}) };
  }
  return out;
}

/**
 * 从完整 Character 抽出【定义层】字段（世界模板架构 v2 §1）。纯函数，P1b 迁移与 saveCharacter
 * 拆分都用它。resident 不进 def（是每世界实例状态）；storyRole 的 bookId/castId 收进 storyArchetype。
 * defId 缺省 = c.id（作者角色/玩家造物自有定义）；模板克隆场景传入共享 defId 以指向同一份定义。
 */
export function characterDefFromCharacter(c: Character, defId: string = c.id): CharacterDef {
  return {
    defId,
    isFairy: c.isFairy,
    name: c.name,
    personality: c.personality,
    voiceId: c.voiceId,
    ...(c.greetingStyle !== undefined ? { greetingStyle: c.greetingStyle } : {}),
    appearance: c.appearance,
    abilities: c.abilities,
    ...(c.storyRole ? { storyArchetype: { bookId: c.storyRole.bookId, castId: c.storyRole.castId } } : {}),
  };
}

/**
 * 从完整 Character 抽出【实例层】放置记录（世界模板架构 v2 §1）。纯函数，saveCharacter 拆写用。
 * 只带每世界可变状态 + defId 引用；def 字段（name/性格/音色/长相/能力/故事原型）绝不进来。
 * resident 从 storyRole.resident 落进实例（每世界一份）；无 storyRole 的普通村民不带 resident。
 * defId 缺省 = c.id；克隆/共享场景传入目标 defId。
 */
export function characterInstanceFromCharacter(c: Character, defId: string = c.id): CharacterInstanceRecord {
  return {
    id: c.id,
    worldId: c.worldId,
    defId,
    position: c.position,
    ...(c.sceneId !== undefined ? { sceneId: c.sceneId } : {}),
    state: c.state,
    behaviorScript: c.behaviorScript,
    memory: c.memory,
    chatHistory: c.chatHistory,
    relationships: c.relationships,
    ...(c.attachments !== undefined ? { attachments: c.attachments } : {}),
    ...(c.taskChain !== undefined ? { taskChain: c.taskChain } : {}),
    ...(c.storyRole ? { resident: c.storyRole.resident } : {}),
  };
}

/**
 * 合并【共享定义】+【实例放置】→ 完整 Character（getCharacter/listCharacters 读时用）。纯函数。
 * def 提供身份（name/性格/音色/长相/能力）；实例提供每世界可变状态（位置/场景/关系/记忆/入住…）。
 * storyRole 由 def.storyArchetype + inst.resident 重组——resident 是每世界的，只此世界翻动。
 * 这条合并方向（def 供身份、实例供状态）就是「改共享定义→全世界引用者当场生效」的地基。
 */
export function characterFromDefInstance(def: CharacterDef, inst: CharacterInstanceRecord): Character {
  return {
    id: inst.id,
    worldId: inst.worldId,
    isFairy: def.isFairy,
    name: def.name,
    personality: def.personality,
    voiceId: def.voiceId,
    ...(def.greetingStyle !== undefined ? { greetingStyle: def.greetingStyle } : {}),
    appearance: def.appearance,
    abilities: def.abilities,
    memory: inst.memory ?? [],
    chatHistory: inst.chatHistory ?? [],
    state: inst.state,
    behaviorScript: inst.behaviorScript,
    position: inst.position,
    ...(inst.sceneId !== undefined ? { sceneId: inst.sceneId } : {}),
    relationships: inst.relationships ?? {},
    ...(inst.attachments !== undefined ? { attachments: inst.attachments } : {}),
    ...(inst.taskChain !== undefined ? { taskChain: inst.taskChain } : {}),
    ...(def.storyArchetype
      ? { storyRole: { bookId: def.storyArchetype.bookId, castId: def.storyArchetype.castId, resident: inst.resident ?? false } }
      : {}),
  };
}

/** 归一持久化读到的原始值成 CharacterDef；缺关键字段（defId/name）视为损坏，返回 null 丢弃。 */
function coerceCharacterDef(raw: unknown): CharacterDef | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const defId = typeof r.defId === 'string' ? r.defId : '';
  const name = typeof r.name === 'string' ? r.name : '';
  if (!defId || !name) return null;
  const ap = (r.appearance && typeof r.appearance === 'object' ? r.appearance : {}) as Record<string, unknown>;
  const arch = r.storyArchetype && typeof r.storyArchetype === 'object' ? (r.storyArchetype as Record<string, unknown>) : null;
  return {
    defId,
    isFairy: r.isFairy === true,
    name,
    personality: typeof r.personality === 'string' ? r.personality : '',
    voiceId: typeof r.voiceId === 'string' ? r.voiceId : '',
    ...(typeof r.greetingStyle === 'string' ? { greetingStyle: r.greetingStyle } : {}),
    appearance: {
      visualDescription: typeof ap.visualDescription === 'string' ? ap.visualDescription : '',
      spriteAsset: typeof ap.spriteAsset === 'string' ? ap.spriteAsset : '',
      scale: typeof ap.scale === 'number' ? ap.scale : 1,
      ...(ap.size !== undefined ? { size: ap.size as CharacterDef['appearance']['size'] } : {}),
      ...(ap.anchors !== undefined ? { anchors: ap.anchors as CharacterDef['appearance']['anchors'] } : {}),
      ...(ap.recipient !== undefined ? { recipient: ap.recipient as CharacterDef['appearance']['recipient'] } : {}),
    },
    abilities: Array.isArray(r.abilities) ? r.abilities.filter((a): a is string => typeof a === 'string') : [],
    ...(arch && typeof arch.bookId === 'string' && typeof arch.castId === 'string'
      ? { storyArchetype: { bookId: arch.bookId, castId: arch.castId } }
      : {}),
  };
}

/**
 * 备份包格式版本。导入时严格比对：版本不同 = 布局可能变了，宁可拒绝也不要在老板的灾难恢复
 * 现场"尽力而为"地导进半套数据。往后改布局必须 +1，并在 restore 里显式写迁移。
 */
export const BACKUP_VERSION = 1;

/**
 * 资产字节缓存的预算（默认 32MB）。热数据 = 当前在线小朋友看到的立绘与图集，几十 MB 足够；
 * 关键是它**封顶**——资产总量随小朋友造角色只增不减（生产已 70MB），不能再让它全量常驻。
 * 超预算就驱逐最久未用的，下次要用再回源读盘。测试可通过构造参数调小。
 */
const ASSET_CACHE_BYTES = 32 * 1024 * 1024;

/** 备份包里的 manifest.json：既是导入前的完整性校验，也是给管理台看的"包里有什么"。 */
export interface BackupManifest {
  version: number;
  createdAt: number;
  gitSha: string;
  counts: {
    players: number;
    worlds: number;
    characters: number;
    items: number;
    assets: number;
    spriteAnims: number;
  };
}

/**
 * 立绘 idle 动画记录，按源立绘 hash 键控（fairy/player/NPC 统一）。
 * status=pending 生成中；ready 带图集资产 hash + meta；failed 生成失败（客户端保留静态）。
 */
export interface SpriteAnimRecord {
  status: 'pending' | 'ready' | 'failed';
  animAsset?: string;
  meta?: SpriteSheetMeta;
  /**
   * 图集「结构」版本。缺省 = 1 = 单段 idle（本字段上线前的老记录）；2 = 三段 idle/moving/talking。
   * 结构变化（新增段）要重新向 Seedance 买视频才能补，回填走完整重生成。见 backfillCharacterAnimations。
   */
  version?: number;
  /**
   * 图集「打包管线」版本。缺省 = 1。抠图/去绿溢/帧率/裁剪盒等打包参数变了就 bump（见
   * idle_animation.ts 的 SPRITE_PACK_VERSION）。它与 version 正交：结构没变、只是打包管线变了，
   * 回填从存量原片零成本 repack 即可，不必再买视频。缺省视为 1，好让存量记录被自动 repack 一次。
   */
  packVersion?: number;
  /**
   * 段名 → 该段原始绿幕 mp4 的资产 hash。
   *
   * 留着原片是有意的：视频是花钱生成的（每段约 $0.046），而图集的帧率/分辨率/打包方式
   * 都还会变（比如日后把抽帧从 8fps 提到原片的原生帧率）。存了原片，重打图集就是一次纯
   * 本地 ffmpeg，零成本；不存就得重新向 Seedance 买一遍。原片不下发给客户端。
   */
  clipVideos?: Partial<Record<ClipName, string>>;
}

/** scenes 表的一行（列名 snake_case；terrain blob 单独走 getSceneTerrain，不在此）。 */
interface SceneRow {
  world_id: string;
  scene_id: string;
  name: string;
  terrain_asset: string;
  grid_tiles: number;
  pois: string;
  portals: string;
  terrain_version: number;
}

/** getScene/listScenes 的列清单：刻意不含 terrain blob（50KB，别随场景元数据白拉）。 */
const SCENE_COLS = 'world_id, scene_id, name, terrain_asset, grid_tiles, pois, portals, terrain_version';

export interface World {
  id: string;
  characters: Map<string, Character>;
}
// 注：钱包/委托/背包按 (worldId, playerId) 分（getWallet/getActiveTask/getBag）；
// 语音造物是 items 实体行 + 地形矩阵 tile 引用（万物皆物品），不再挂在世界对象上。

/**
 * 世界状态 + 生成的 sprite 资源存储。
 * 传 dataDir → 持久化到 SQLite（<dataDir>/world.db，assets/ + assets.json 清单沿用文件寻址）；
 * 不传 → 内存 SQLite（`:memory:`，测试用）。
 *
 * 存储布局：
 *   worlds(id, inventory, active_task)       ← inventory/active_task 两列已废弃，见 wallets/player_tasks
 *   characters(id PK, world_id, data JSON)   ← Character 整对象存一行
 *   props(id PK, world_id, data JSON)            ← 已退役：启动时迁到 items+矩阵/背包（#migratePropsToItems）
 *   items(id PK, world_id, data JSON)            ← 语音造物实体行（万物皆物品）
 *   bag(world_id, player_id, item_id, count)     ← 每玩家的物品背包计数
 *   wallets(world_id, player_id, data JSON)      ← 每玩家一份小红花钱包
 *   player_tasks(world_id, player_id, data JSON) ← 每玩家一个进行中委托（无委托则无行）
 * saveCharacter 从「全量重写 worlds.json」变为「UPDATE 一行」，根治 chatHistory 膨胀拖慢落盘。
 * 首启若存在旧 worlds.json 且库为空 → 一次性迁移后把 worlds.json 改名 .migrated 备份。
 */
export class WorldStore {
  readonly #dir: string | null;
  #db!: DatabaseSync;
  /**
   * 资产清单：hash → mime。**常驻**内存，但每条只有几十字节（生产 122 个资产 ≈ 几 KB）。
   * 资产的字节不在这里——见 #assetCache。
   */
  readonly #assetMime = new Map<string, string>();
  /**
   * 资产字节的 LRU 缓存（Map 保序，队尾 = 最近使用）。
   *
   * 持久化 store 下这是**纯缓存**：miss 就回源读盘，超预算就驱逐最久未用的。
   * 内存 store（dataDir=null，测试用）下它是字节的**唯一**落点，因此永不驱逐——
   * 那里驱逐一张就等于把数据弄丢了。
   */
  readonly #assetCache = new Map<string, ImageBlob>();
  #cacheBytes = 0;
  readonly #cacheBudget: number;
  // 立绘 hash → idle 动画记录（sprite_anims.json 持久化，跨重启保留）
  readonly #spriteAnims = new Map<string, SpriteAnimRecord>();
  // 世界地点名清单（POI，客户端 world_info 上报）：纯内存，客户端每次连上重发，不持久化
  readonly #locations = new Map<string, string[]>();

  constructor(dataDir?: string, opts?: { assetCacheBytes?: number }) {
    this.#dir = dataDir ?? null;
    this.#cacheBudget = opts?.assetCacheBytes ?? ASSET_CACHE_BYTES;
    this.#open();
  }

  /** 开库 + schema + 迁移 + 加载内存态。构造与 reload（导入备份后）共用同一条路径。 */
  #open(): void {
    if (this.#dir !== null) mkdirSync(this.#dir, { recursive: true });
    this.#db = new DatabaseSync(this.#dir !== null ? join(this.#dir, 'world.db') : ':memory:');
    this.#initSchema();
    if (this.#dir !== null) {
      this.#migrateFromJson();
      // 复合 PK 迁移必须在拆定义/实例【之前】：其后所有对 characters 的写（拆实例行、fairy/记忆/对话
      // 迁移的 UPDATE）都按 (world_id,id) 复合键操作。放在 json 迁移之后（先把老 worlds.json 导进单列
      // PK 表，再整体重建成复合），既吃老库也幂等吃已复合的库（新库 initSchema 直接建复合，这步跳过）。
      this.#migrateCharactersCompositePk();
      // 拆定义/实例必须最先跑：其后每个角色迁移都按【拆分后】的形态操作——身份字段（isFairy/name/
      // abilities）走定义层（fairy 迁移读 character_defs），可变态（memory/chatHistory/sceneId）走实例行。
      // 放在最前，既能吃下老库的全量 blob（首开），也能吃下已拆分的库（重开/新格式），两条路都幂等。
      this.#migrateCharactersToDefsInstances();
      this.#migrateLegacyMemories();
      this.#migrateLegacyChatHistory();
      this.#migrateLegacyPlayerPositions();
      this.#migrateLegacyEntityScenes();
      this.#migrateVisitsDevice();
      this.#migrateWorldsTemplateVersion(); // 存量 worlds 表补 template_version 列（P5 放置级迁移记账）
      this.#migrateFairyAbilities(); // 存量仙子补新增能力（create_sticker / play_game / guide_to / guide_stop）
      this.#migrateFairyPersona(); // 存量仙子改名换人设（小神仙 → 点点，神笔的笔灵）
      this.#loadAssets();
      this.#loadSpriteAnims();
      this.#migrateSceneTerrainBlobs(); // 依赖 assets 已加载（从内容寻址库搬 blob）
      this.#migratePropsToItems(); // 依赖场景矩阵已就位（placed 物件要写进矩阵）
    }
  }

  /**
   * 旧库的 visits 表没有 device 列（生产已有 62 条会话记录），补上。
   * 幂等：列已存在就跳过（新库 initSchema 已带 device，走这条会跳过）。
   */
  #migrateVisitsDevice(): void {
    const cols = this.#db.prepare('PRAGMA table_info(visits)').all() as { name: string }[];
    if (!cols.some((c) => c.name === 'device')) {
      this.#db.exec('ALTER TABLE visits ADD COLUMN device TEXT');
    }
  }

  /**
   * 存量 worlds 表补 template_version 列（世界模板架构 v2 P5，§6）。旧库建表时无此列，
   * 加列后所有世界默认版本 0——模板与存量玩家世界同为 0，故首次跑迁移是 no-op（无放置差异要补），
   * 直到作者第一次 bumpTemplateVersion 才产生落差、触发 additive 补入。幂等：列已在则跳过。
   */
  #migrateWorldsTemplateVersion(): void {
    const cols = this.#db.prepare('PRAGMA table_info(worlds)').all() as { name: string }[];
    if (!cols.some((c) => c.name === 'template_version')) {
      this.#db.exec('ALTER TABLE worlds ADD COLUMN template_version INTEGER NOT NULL DEFAULT 0');
    }
  }

  /**
   * 给存量世界的仙子补齐全部看家本领。seedFairy 只在建世界时跑（新世界自带），老库里的仙子
   * 从 DB 读能力、缺哪条就不认对应意图（「做个贴纸」「我们来踢球」「帮我造一个小房子」）。
   * REQUIRED 曾只列「后续新增」的四条，漏了 create_prop/create_character 这类「一直都该有」的——
   * 在那之前的历史窗口期建的库，点点造物入口永远是死的（本地遗留库实证撞见）。现在列全量：
   * 与 seedFairy 的 abilities 保持同一份清单，缺谁补谁。
   * 幂等：非仙子/已齐全的跳过；只 UPDATE 真改到的行（getCharacter 直读 DB，无内存 Map 需刷新）。
   */
  #migrateFairyAbilities(): void {
    const REQUIRED = ['create_character', 'create_prop', 'create_sticker', 'play_game', 'guide_to', 'guide_stop'];
    // 能力是【定义层】字段（世界模板架构 v2）：拆分后仙子的 abilities 落在 character_defs，改这里。
    for (const def of this.listCharacterDefs()) {
      if (!def.isFairy) continue;
      const abilities = Array.isArray(def.abilities) ? def.abilities : [];
      const missing = REQUIRED.filter((a) => !abilities.includes(a));
      if (missing.length === 0) continue;
      this.upsertCharacterDef({ ...def, abilities: [...abilities, ...missing] });
    }
  }

  /**
   * 存量世界的仙子改名换人设：「小神仙」→「点点」（神笔的笔灵，见 docs/fairy-persona-design.md）。
   *
   * 名字进 LLM 的 system prompt（characterName/personality），老库不迁移的话，生产上她会继续
   * 自称「小神仙」、继续按旧人设说话——新客户端念的是点点，服务端答的是小神仙，当场分裂。
   *
   * 幂等：名字已是 FAIRY_NAME 且 personality 已是新版就跳过。
   * 刻意**不动** spriteAsset——立绘替换走 POST /worlds/:id/fairy-sprite（P2），迁移只管文字人设。
   */
  #migrateFairyPersona(): void {
    // name/personality/voiceId/abilities 都是【定义层】字段（世界模板架构 v2）：拆分后改 character_defs。
    for (const def of this.listCharacterDefs()) {
      if (!def.isFairy) continue;
      // voiceId 也要迁移：它驱动【动态对话 replyText】的实时 TTS，老库存的是旧音色（Xiaoyi）。
      // 不迁移的话，存量世界里预制台词是新音色（客户端 WAV 已重烧）、实时对话却还是旧音色，当场分裂。
      if (def.name === FAIRY_NAME && def.personality === FAIRY_PERSONALITY && def.voiceId === FAIRY_VOICE) continue;
      this.upsertCharacterDef({
        ...def,
        name: FAIRY_NAME,
        personality: FAIRY_PERSONALITY,
        voiceId: FAIRY_VOICE,
        // 顺手清掉历史残留：她拿到 move_to/deliver_message 也兑现不了（effectiveAbilities 恒剔除）。
        abilities: (Array.isArray(def.abilities) ? def.abilities : []).filter((a) => !LOCOMOTION_ABILITIES.includes(a)),
      });
    }
  }

  /**
   * characters 表单列 PK (id) → 复合 PK (world_id, id)（世界模板架构 v2 P2）。
   * 幂等：PRAGMA table_info 看 world_id 那列的 pk 序号 > 0（已是主键成员）就跳过；否则就地重建。
   * 新库/内存库 initSchema 已直接建复合 PK，这步只对老单列 PK 库生效。事务原子包裹。
   */
  #migrateCharactersCompositePk(): void {
    const cols = this.#db.prepare('PRAGMA table_info(characters)').all() as { name: string; pk: number }[];
    const worldCol = cols.find((c) => c.name === 'world_id');
    if (!worldCol || worldCol.pk > 0) return; // 表不存在（不该发生）或 world_id 已是 PK 成员 → 已复合
    this.#db.exec('BEGIN');
    try {
      this.#db.exec(
        'CREATE TABLE characters_new (world_id TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (world_id, id));',
      );
      this.#db.exec('INSERT INTO characters_new (world_id, id, data) SELECT world_id, id, data FROM characters;');
      this.#db.exec('DROP TABLE characters;');
      this.#db.exec('ALTER TABLE characters_new RENAME TO characters;');
      this.#db.exec('CREATE INDEX IF NOT EXISTS idx_characters_world ON characters(world_id);');
      this.#db.exec('COMMIT');
    } catch (e) {
      this.#db.exec('ROLLBACK');
      throw e;
    }
  }

  /**
   * 存量 characters 行（旧全量 blob）→ 拆成【共享定义】+【实例放置】（世界模板架构 v2 §8 P1）。
   * 幂等：已是实例（data 含 defId）的行跳过；只搬旧全量 blob。作者角色/玩家造物 defId = 自身 id。
   * 必须【最先】跑（#open 里排第一个角色迁移）：其后 fairy 迁移改定义层、记忆/对话/场景迁移改实例层，
   * 都依赖此步已把行拆开。事务原子：定义与实例同生，避免拆到一半崩出裸实例。
   */
  #migrateCharactersToDefsInstances(): void {
    const rows = this.#db.prepare('SELECT id, world_id, data FROM characters').all() as { id: string; world_id: string; data: string }[];
    this.#db.exec('BEGIN');
    try {
      for (const r of rows) {
        let parsed: unknown;
        try {
          parsed = JSON.parse(r.data);
        } catch {
          continue;
        }
        if (parsed && typeof parsed === 'object' && typeof (parsed as { defId?: unknown }).defId === 'string') continue; // 已拆
        const c = parsed as Character;
        this.upsertCharacterDef(characterDefFromCharacter(c)); // defId = c.id
        this.#writeInstanceRow(characterInstanceFromCharacter(c));
      }
      this.#db.exec('COMMIT');
    } catch (e) {
      this.#db.exec('ROLLBACK');
      throw e;
    }
  }

  /**
   * 关库重开，把进程内状态与（被外部整体换掉的）落盘数据重新对齐。
   * 唯一调用方是导入备份：dataDir 被原子替换后，旧的 db 句柄指着已被 rename 走的 inode，
   * 内存里的 assets/spriteAnims 也全是旧数据——不 reload 就得重启进程才能生效。
   * locations 是纯内存态（客户端每次连上重发），清掉即可。
   */
  reload(): void {
    this.#db.close();
    this.#assetMime.clear();
    this.#assetCache.clear();
    this.#cacheBytes = 0;
    this.#spriteAnims.clear();
    this.#locations.clear();
    this.#open();
  }

  /** 持久化目录（内存 store 为 null）。备份/恢复据此定位 assets/ 与同卷临时目录。 */
  get dataDir(): string | null {
    return this.#dir;
  }

  #count(table: string): number {
    return (this.#db.prepare(`SELECT COUNT(*) AS c FROM ${table}`).get() as { c: number }).c;
  }

  /**
   * 导出一份自洽快照到 stagingDir，供 backup.ts 打包（见那里的整体流程注释）。
   *
   * world.db 走 SQLite 的 `VACUUM INTO`：在线安全，拿到的是事务一致的快照。直接拷正在被写的
   * db 文件会拿到撕裂内容，而 node:sqlite 没有 .backup()（实测 v26.4 上是 undefined），
   * VACUUM INTO 是这个 runtime 上唯一的一致性快照手段。
   *
   * 两份清单从内存态重新序列化，而不是拷 dataDir 里的现成文件：#persistAssetIndex 是全量
   * writeFileSync 重写、并非原子，拷文件可能正撞上重写、读到半截 JSON。
   *
   * assets/ 不在这里处理——它内容寻址、只增不改，打包时直接从 dataDir 取就是安全的。
   */
  exportSnapshot(stagingDir: string): BackupManifest {
    if (this.#dir === null) throw new Error('in-memory store has nothing to back up');
    mkdirSync(stagingDir, { recursive: true });
    mkdirSync(this.#assetsDir(), { recursive: true }); // 空库也得有 assets/，否则 tar 报源不存在

    const dbOut = join(stagingDir, 'world.db');
    rmSync(dbOut, { force: true }); // VACUUM INTO 拒绝覆盖已存在的文件
    this.#db.exec(`VACUUM INTO '${dbOut.replace(/'/g, "''")}'`);

    const assetIndex: Record<string, string> = {};
    for (const [hash, mime] of this.#assetMime) assetIndex[hash] = mime;
    writeFileSync(join(stagingDir, 'assets.json'), JSON.stringify(assetIndex));

    const anims: Record<string, SpriteAnimRecord> = {};
    for (const [hash, rec] of this.#spriteAnims) anims[hash] = rec;
    writeFileSync(join(stagingDir, 'sprite_anims.json'), JSON.stringify(anims));

    const manifest: BackupManifest = {
      version: BACKUP_VERSION,
      createdAt: Date.now(),
      gitSha: process.env.GIT_SHA ?? 'dev',
      counts: {
        players: this.#count('players'),
        worlds: this.#count('worlds'),
        characters: this.#count('characters'),
        items: this.#count('items'),
        assets: this.#assetMime.size,
        spriteAnims: this.#spriteAnims.size,
      },
    };
    writeFileSync(join(stagingDir, 'manifest.json'), JSON.stringify(manifest, null, 2));
    return manifest;
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
        active_task TEXT,
        -- 放置级 additive 迁移的版本记账（世界模板架构 v2 P5，§6）：
        -- template 世界自持「当前模板放置版本」（作者加村民/加册后 bumpTemplateVersion 自增）；
        -- 每个 w_<player>/sandbox 世界持「克隆/迁移到的版本」，进入时若落后于模板即补入新放置。
        -- 旧库无此列，由 #migrateWorldsTemplateVersion 补齐（默认 0）。
        template_version INTEGER NOT NULL DEFAULT 0
      );
      -- 复合主键 (world_id, id)：世界模板架构 v2 P2——两玩家世界要各持同一 story 角色一份
      -- （instance id = defId = storyCharacterId，story_director 直接按此 id 查角色，不能 mangle 改名），
      -- 全局单列 PK 装不下同 id 两行。旧库的单列 PK 由 #migrateCharactersCompositePk 就地重建。
      CREATE TABLE IF NOT EXISTS characters (
        world_id TEXT NOT NULL,
        id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (world_id, id)
      );
      CREATE INDEX IF NOT EXISTS idx_characters_world ON characters(world_id);
      -- 角色【定义层】（世界模板架构 v2，docs/world-template-instancing-design.md §1）：
      -- 全局共享的角色身份（长相/性格/音色/能力/故事原型），按 def_id 引用、不随世界复制。
      -- 每世界的放置与可变状态仍在 characters 表（实例层）。P1a 只落表+读写方法，尚未接入 getCharacter。
      CREATE TABLE IF NOT EXISTS character_defs (
        def_id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
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
        ended_at INTEGER,
        -- 会话建立时的设备快照 JSON（DeviceSnapshot）。旧行为 NULL，见 #migrateVisitsDevice。
        device TEXT
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
      -- 玩家 onboarding 档案（docs/onboarding-avatar-redesign-design.md §2.5）：键=playerId。
      -- 独立于 players 表——world_info 的 Player upsert 是整行覆盖，并进去会被抹掉。
      CREATE TABLE IF NOT EXISTS player_onboarding (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
      -- 物品实体外观缩略图：物品在服务端没有图片，全靠客户端按 renderRef 现场渲染。
      -- debug 后台要看物品长什么样，就让客户端把每个 ItemDef 渲染成一张 PNG 上传（内容
      -- 寻址存进 assets），这里按 item id 记它的 hash。内置 def 与语音造物共用一张表。
      CREATE TABLE IF NOT EXISTS item_icons (
        item_id TEXT PRIMARY KEY,
        asset_hash TEXT NOT NULL
      );
      -- 设备画质档众包（见 device_profile.ts）：按 GPU 分桶，一台设备一行——
      -- 同一台机器重测会覆盖自己那行，不会往众包里重复灌票。
      CREATE TABLE IF NOT EXISTS device_samples (
        gpu           TEXT NOT NULL,
        bench_version INTEGER NOT NULL,
        device_id     TEXT NOT NULL,
        levels        TEXT NOT NULL,
        p95_ms        REAL NOT NULL,
        hit           INTEGER NOT NULL,
        PRIMARY KEY (gpu, bench_version, device_id)
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
      -- M2 章回剧情进度（docs/m2-story-director-design.md §3.1）：每玩家每世界一份 StoryProgress JSON。
      -- 只存 idle/interacting 稳态——performing 是内存态，断线/崩溃重进永远停在幕首。
      CREATE TABLE IF NOT EXISTS story_progress (
        world_id TEXT NOT NULL,
        player_id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (world_id, player_id)
      );
      -- 玩家已发现的玩法（造物/造角色/玩游戏…）：村民只漏【还没被发现】的心愿，
      -- 发现一个就再没人念叨它——「已发现的不再提」是发现感成立的前提（见 wishes.ts）。
      CREATE TABLE IF NOT EXISTS player_discovered (
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
      -- 物品实体（万物皆物品，docs/scene-item-refactor-design.md §2.1）：
      -- 只存语音造物（world 归属）；内置定义是代码常量（items.ts BUILTIN_ITEMS），不落库。
      -- 地形矩阵 palette / 背包引用的都是本表（或内置）的 id。
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY,
        world_id TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_items_world ON items(world_id);
      -- 背包：玩家持有的物品实体计数（与钱包同构，按 (world, player) 分）。
      -- 实例身份已消解为（tile + 实体引用），背包只记「哪种物品有几份」。
      CREATE TABLE IF NOT EXISTS bag (
        world_id  TEXT NOT NULL,
        player_id TEXT NOT NULL,
        item_id   TEXT NOT NULL,
        count     INTEGER NOT NULL,
        PRIMARY KEY (world_id, player_id, item_id)
      );
      -- 场景 = 世界里的一片区域（一张地图）。
      -- 地形矩阵 v2 起直接存 terrain 列（频繁 tile 编辑与内容寻址天然冲突），
      -- terrain_version 单调递增供客户端缓存/patch 对齐；terrain_asset 是
      -- 内容寻址时代的 hash，过渡期保留（老客户端仍按它拉 /assets）。
      CREATE TABLE IF NOT EXISTS scenes (
        world_id      TEXT NOT NULL,
        scene_id      TEXT NOT NULL,
        name          TEXT NOT NULL,
        terrain_asset TEXT NOT NULL,
        grid_tiles    INTEGER NOT NULL,
        pois          TEXT NOT NULL DEFAULT '[]',
        portals       TEXT NOT NULL DEFAULT '[]',
        terrain       BLOB,
        terrain_version INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (world_id, scene_id)
      );
    `);
    // 存量库的 scenes 表补新列（SQLite 无 IF NOT EXISTS 列语法，重复 ALTER 会抛，吞掉即可）
    for (const ddl of [
      'ALTER TABLE scenes ADD COLUMN terrain BLOB',
      "ALTER TABLE scenes ADD COLUMN terrain_version INTEGER NOT NULL DEFAULT 0",
    ]) {
      try {
        this.#db.exec(ddl);
      } catch {
        /* 列已存在 */
      }
    }
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

  /** 物品实体外观缩略图：某 item id 的资产 hash（客户端未上传返回空串）。 */
  getItemIcon(itemId: string): string {
    const row = this.#db.prepare('SELECT asset_hash FROM item_icons WHERE item_id = ?').get(itemId) as
      | { asset_hash: string }
      | undefined;
    return row?.asset_hash ?? '';
  }

  /** 记录/更新某物品实体的外观缩略图资产 hash（客户端渲染上传）。 */
  setItemIcon(itemId: string, assetHash: string): void {
    this.#db
      .prepare('INSERT INTO item_icons (item_id, asset_hash) VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET asset_hash = excluded.asset_hash')
      .run(itemId, assetHash);
  }

  /** 全部已上传的物品缩略图映射（item id → asset hash）。 */
  listItemIcons(): Record<string, string> {
    const rows = this.#db.prepare('SELECT item_id, asset_hash FROM item_icons').all() as
      { item_id: string; asset_hash: string }[];
    const out: Record<string, string> = {};
    for (const r of rows) out[r.item_id] = r.asset_hash;
    return out;
  }

  /** 记录一台设备的 benchmark 结果（同设备重测覆盖自己那行）。 */
  putDeviceSample(s: DeviceSample): void {
    this.#db
      .prepare(
        `INSERT INTO device_samples (gpu, bench_version, device_id, levels, p95_ms, hit)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(gpu, bench_version, device_id) DO UPDATE SET
           levels = excluded.levels, p95_ms = excluded.p95_ms, hit = excluded.hit`,
      )
      .run(s.gpu, s.benchVersion, s.deviceId, JSON.stringify(s.levels), s.p95Ms, s.hit ? 1 : 0);
  }

  /** 列出全部 benchmark 样本（后台体检用：看有没有测试探针灌进生产众包）。 */
  listDeviceSamples(): { gpu: string; benchVersion: number; deviceId: string; p95Ms: number }[] {
    const rows = this.#db
      .prepare('SELECT gpu, bench_version, device_id, p95_ms FROM device_samples ORDER BY gpu, device_id')
      .all() as { gpu: string; bench_version: number; device_id: string; p95_ms: number }[];
    return rows.map((r) => ({ gpu: r.gpu, benchVersion: r.bench_version, deviceId: r.device_id, p95Ms: r.p95_ms }));
  }

  /** 删掉某台设备的样本（清测试污染）。返回删了几行。 */
  deleteDeviceSample(gpu: string, deviceId: string): number {
    const before = this.#count('device_samples');
    this.#db.prepare('DELETE FROM device_samples WHERE gpu = ? AND device_id = ?').run(gpu, deviceId);
    return before - this.#count('device_samples');
  }

  /** 某 GPU（同一 benchmark 口径）下所有设备的档位样本；损坏的行跳过。 */
  listDeviceLevels(gpu: string, benchVersion: number): Levels[] {
    const rows = this.#db
      .prepare('SELECT levels FROM device_samples WHERE gpu = ? AND bench_version = ?')
      .all(gpu, benchVersion) as { levels: string }[];
    const out: Levels[] = [];
    for (const r of rows) {
      const lv = sanitizeLevels(JSON.parse(r.levels));
      if (lv) out.push(lv);
    }
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

  /**
   * 启动只加载**清单**（hash → mime），不读任何资产字节——字节等到 getAsset 时才回源读盘。
   *
   * 这里曾经是把 assets/ 下每个文件都 readFileSync 进内存，常驻内存随资产数线性增长
   * （生产 122 个资产 = 70MB 白占，且只会越来越多）。
   *
   * 仍然逐个 existsSync 过滤：清单里有、盘上没有的孤儿条目不登记，免得 exportSnapshot
   * 把它们写进备份的 assets.json（122 次 existsSync 在启动路径上可以忽略不计）。
   */
  #loadAssets(): void {
    const mf = join(this.#dir as string, 'assets.json');
    if (!existsSync(mf)) return;
    const mimes = JSON.parse(readFileSync(mf, 'utf8')) as Record<string, string>;
    for (const hash of Object.keys(mimes)) {
      if (existsSync(join(this.#assetsDir(), hash))) this.#assetMime.set(hash, mimes[hash]!);
    }
  }

  #persistAssetIndex(): void {
    if (this.#dir === null) return;
    const idx: Record<string, string> = {};
    for (const [hash, mime] of this.#assetMime) idx[hash] = mime;
    writeFileSync(join(this.#dir, 'assets.json'), JSON.stringify(idx));
  }

  /**
   * 放进 LRU 缓存，必要时把最久未用的挤出去。
   * 内存 store 不驱逐：那里没有磁盘可回源，挤掉一张 = 数据丢了。
   */
  #cachePut(hash: string, blob: ImageBlob): void {
    const old = this.#assetCache.get(hash);
    if (old) {
      this.#cacheBytes -= old.bytes.length;
      this.#assetCache.delete(hash);
    }
    this.#assetCache.set(hash, blob);
    this.#cacheBytes += blob.bytes.length;
    if (this.#dir === null) return;
    for (const [h, b] of this.#assetCache) {
      if (this.#cacheBytes <= this.#cacheBudget) break;
      if (h === hash) continue; // 刚放进来的这张别立刻又扔了
      this.#assetCache.delete(h);
      this.#cacheBytes -= b.bytes.length;
    }
  }

  createWorld(id: string = randomUUID()): World {
    // 钱包不再随世界创建：每个玩家首次读到自己的钱包时才发初始小红花（见 getWallet）。
    // inventory / active_task 两列已废弃，保留仅为兼容旧库文件。
    this.#db
      .prepare('INSERT OR IGNORE INTO worlds (id, inventory, active_task) VALUES (?, ?, ?)')
      .run(id, '{}', null);
    return { id, characters: new Map() };
  }

  getWorld(id: string): World | undefined {
    const row = this.#db.prepare('SELECT id, active_task FROM worlds WHERE id = ?').get(id) as
      | { id: string; active_task: string | null }
      | undefined;
    if (!row) return undefined;
    const characters = new Map<string, Character>();
    for (const c of this.listCharacters(id)) characters.set(c.id, c);
    return { id: row.id, characters };
  }

  #worldExists(id: string): boolean {
    return this.#db.prepare('SELECT 1 FROM worlds WHERE id = ?').get(id) !== undefined;
  }

  /** world 是否存在（轻量：只查主键，不加载角色）。调用方据此拒绝对不存在世界的注册/落库。 */
  worldExists(id: string): boolean {
    return this.#worldExists(id);
  }

  /**
   * 删除一个世界及其全部关联数据（级联，事务原子）。返回是否真的删了（world 不存在则 false）。
   * 唯一调用方：admin DELETE /admin/worlds/:id，清理无主的空壳世界（脏数据）。
   * 按 world_id 分区的表全清；memories/chat_turns 按该世界的角色 id 级联（这两表不带 world_id）；
   * locations 是纯内存态，一并清。players/creation_icons/item_icons 等全局表与世界无关，不动。
   * character_defs 是全局共享定义（世界模板架构 v2）——别的世界可能引用同一 defId，故删世界只清
   * 实例放置行、绝不删共享定义（玩家造物的私有定义留成孤儿是可接受的小泄漏，GC 归后续）。
   */
  deleteWorld(id: string): boolean {
    if (!this.#worldExists(id)) return false;
    const charIds = (this.#db.prepare('SELECT id FROM characters WHERE world_id = ?').all(id) as { id: string }[]).map((r) => r.id);
    this.#db.exec('BEGIN');
    try {
      if (charIds.length) {
        const ph = charIds.map(() => '?').join(',');
        this.#db.prepare(`DELETE FROM memories WHERE owner_character_id IN (${ph})`).run(...charIds);
        this.#db.prepare(`DELETE FROM chat_turns WHERE character_id IN (${ph})`).run(...charIds);
      }
      for (const t of ['characters', 'props', 'items', 'bag', 'wallets', 'player_tasks', 'player_discovered', 'player_positions', 'story_progress', 'scenes', 'visits']) {
        this.#db.prepare(`DELETE FROM ${t} WHERE world_id = ?`).run(id);
      }
      this.#db.prepare('DELETE FROM worlds WHERE id = ?').run(id);
      this.#db.exec('COMMIT');
    } catch (e) {
      this.#db.exec('ROLLBACK');
      throw e;
    }
    this.#locations.delete(id);
    return true;
  }

  addCharacter(character: Character): void {
    if (!this.#worldExists(character.worldId)) throw new Error(`world not found: ${character.worldId}`);
    this.saveCharacter(character);
  }

  /**
   * 角色状态变更后持久化（世界模板架构 v2 §5：拆写）。一次事务里 upsert 共享定义 + 写实例放置行：
   * 共享定义（name/性格/音色/长相/能力/故事原型）进 character_defs，改这里全世界引用者当场生效；
   * 实例放置（位置/场景/状态/关系/记忆/入住）进 characters 表，只此世界一份。对上层 API 不变。
   *
   * defId 归属：**沿用已存在实例行的 defId**（模板克隆放进来的实例引用共享 defId，不能被一次
   * setCharacterTile 悄悄改指回自身 id 而脱离共享），无既有行才落 = 自身 id（作者角色/玩家造物自有定义）。
   */
  saveCharacter(character: Character): void {
    const prevDefId = this.#existingInstanceDefId(character.id, character.worldId);
    const defId = prevDefId ?? character.id;
    const def = characterDefFromCharacter(character, defId);
    const inst = characterInstanceFromCharacter(character, defId);
    this.#db.exec('BEGIN');
    try {
      this.upsertCharacterDef(def);
      this.#writeInstanceRow(inst);
      this.#db.exec('COMMIT');
    } catch (e) {
      this.#db.exec('ROLLBACK');
      throw e;
    }
  }

  /** 直接放置一个引用共享定义的实例（世界模板架构 v2 §4.2 克隆原子；不碰定义层）。 */
  putCharacterInstance(inst: CharacterInstanceRecord): void {
    this.#writeInstanceRow(inst);
  }

  /**
   * 克隆世界的【实例层放置】：把 src 世界的每行实例复制进 dst 世界（世界模板架构 v2 §4.2）。
   * id/defId/位置/场景/状态原样，只换 worldId——**定义永不复制**（dst 的实例仍引用同一份共享定义，
   * 故「改共享定义→全世界当场生效」对克隆出的世界照样成立）。dst 不存在则先建（防空壳：调用方给的是
   * 有主的 w_<playerId>/template，非匿名 UUID）。事务原子。旧全量 blob（无 defId）兜底 defId=自身 id。
   */
  cloneWorldInstances(srcWorldId: string, dstWorldId: string): void {
    if (!this.#worldExists(dstWorldId)) this.createWorld(dstWorldId);
    const rows = this.#db.prepare('SELECT data FROM characters WHERE world_id = ?').all(srcWorldId) as { data: string }[];
    this.#db.exec('BEGIN');
    try {
      for (const r of rows) {
        const inst = JSON.parse(r.data) as CharacterInstanceRecord;
        const defId = typeof inst.defId === 'string' ? inst.defId : inst.id;
        this.#writeInstanceRow({ ...inst, worldId: dstWorldId, defId });
      }
      this.#db.exec('COMMIT');
    } catch (e) {
      this.#db.exec('ROLLBACK');
      throw e;
    }
  }

  /**
   * 确立模板世界：不存在则建 + 由现网 default 内容提升（复制 default 的实例放置成模板放置）。
   * 幂等：template 已存在直接返回（不重复克隆覆盖作者对模板的编辑）。template 不接客——
   * GET /worlds/:id 的自动建世界分支只对 id==='default' 生效，别的世界要显式经此路径或克隆产生。
   */
  ensureTemplateWorld(): void {
    if (this.#worldExists(TEMPLATE_WORLD_ID)) return;
    this.createWorld(TEMPLATE_WORLD_ID);
    this.cloneWorldInstances(DEFAULT_WORLD_ID, TEMPLATE_WORLD_ID);
  }

  /**
   * 每人一世界解析（世界模板架构 v2 §5 get-or-create-my-world）：按 playerId 得到 `w_<playerId>`，
   * 不存在则建 + 从 template 复制放置 + 保证有点点，返回其 world_id；已存在直接返回（**不重新克隆**，
   * 免得冲掉孩子对自己世界的改动——移动的 NPC/入住/造物）。
   *
   * 点点保证：template 通常已含点点（default 首访种入、随克隆带过来）；若模板缺点点，用调用方注入的
   * makeFairy 补种一个。seedFairy 落在 server.ts（用到 FAIRY_VISUAL_DESC 等），故以回调注入而非在此
   * 层重造轮子——persistence 不依赖 server。makeFairy 缺省则不补种（测试可依赖模板自带点点）。
   */
  getOrCreateMyWorld(playerId: string, makeFairy?: (worldId: string) => Character): string {
    const worldId = `${PLAYER_WORLD_PREFIX}${playerId}`;
    if (this.#worldExists(worldId)) {
      // P5：世界已存在时不再直接返回，先跑放置级 additive 迁移（模板加的新村民/新册补进来）。
      // additive 只加不改——绝不冲掉孩子对自己世界的改动（移动的 NPC/入住/造物），保住 P2 语义。
      this.#migrateWorldPlacements(worldId);
      return worldId;
    }
    this.#buildWorldFromTemplate(worldId, makeFairy);
    return worldId;
  }

  /**
   * 测试沙箱（世界模板架构 v2 §5 P4）：从 template 复制放置成一个**全新的临时世界**，返回其 id。
   * 与 getOrCreateMyWorld 同源（都从模板铺一个新世界），差别是 id 现生成、每次都是全新一份——
   * 作者「开沙箱 → harness 跑整册 → DELETE 丢掉」验隔离用，零污染 default/template。删走 admin DELETE（级联已有）。
   */
  createSandboxWorld(makeFairy?: (worldId: string) => Character): string {
    const worldId = `${SANDBOX_WORLD_PREFIX}${randomUUID()}`;
    this.#buildWorldFromTemplate(worldId, makeFairy);
    return worldId;
  }

  /** 从 template 铺一个新世界（ensure 模板 + 建世界 + 复制放置 + 保证点点）。getOrCreate/沙箱共用。 */
  #buildWorldFromTemplate(worldId: string, makeFairy?: (worldId: string) => Character): void {
    this.ensureTemplateWorld();
    this.createWorld(worldId);
    this.cloneWorldInstances(TEMPLATE_WORLD_ID, worldId);
    if (makeFairy && !this.listCharacters(worldId).some((c) => c.isFairy)) {
      this.saveCharacter(makeFairy(worldId));
    }
    // P5：新世界克隆时即拿到模板【全部】放置，故其已迁移版本就是模板当前版本——记账诚实，
    // 免得下次进入因 0<version 误触发一轮 no-op 迁移（补入的都已在，虽不出错但白跑）。
    this.#db
      .prepare('UPDATE worlds SET template_version = ? WHERE id = ?')
      .run(this.getTemplateVersion(TEMPLATE_WORLD_ID), worldId);
  }

  /** 读世界的模板版本记账（world 不存在 → 0）。template 世界的这个值 = 当前模板放置版本。 */
  getTemplateVersion(worldId: string): number {
    const row = this.#db.prepare('SELECT template_version FROM worlds WHERE id = ?').get(worldId) as
      | { template_version: number }
      | undefined;
    return row ? row.template_version : 0;
  }

  /**
   * 作者改完模板放置（加村民/挪 NPC/加新册）后自增模板版本，返回新版本（世界模板架构 v2 P5，§6）。
   * 这是触发存量世界 additive 迁移的唯一开关：版本一涨，各世界下次 getOrCreateMyWorld 就会补入
   * 模板里它还没有的放置。ensureTemplateWorld 保证模板存在。
   */
  bumpTemplateVersion(): number {
    this.ensureTemplateWorld();
    const next = this.getTemplateVersion(TEMPLATE_WORLD_ID) + 1;
    this.#db.prepare('UPDATE worlds SET template_version = ? WHERE id = ?').run(next, TEMPLATE_WORLD_ID);
    return next;
  }

  /**
   * 放置级 additive 迁移（世界模板架构 v2 P5，§6）：世界已存在时，把 template 里该世界【还没有】的
   * 放置补进去，据此把世界的已迁移版本追平模板。**只加不改**——按实例 id 查重，已存在的实例一律跳过，
   * 绝不覆盖孩子改过的放置（移动的 NPC/入住翻转/造物）；故模板里【挪已存在 NPC 的位置】这类改动
   * 【不会】传播到存量世界（只有新世界经 clone 才拿到新位置）。定义层共享，补入只复制实例行、不复制定义。
   * 查重键 = 实例 id：clone 保持模板 id，同 id 即同一放置；story 角色 id=defId=storyCharacterId 稳定。
   * 幂等：世界版本 >= 模板版本时直接返回。事务原子。迁移只覆盖 characters（与 cloneWorldInstances
   * 同口径——props/items/scenes 本就不从模板克隆，不在放置迁移范围）。
   */
  #migrateWorldPlacements(worldId: string): void {
    const templateVersion = this.getTemplateVersion(TEMPLATE_WORLD_ID);
    if (this.getTemplateVersion(worldId) >= templateVersion) return;
    const templateRows = this.#db
      .prepare('SELECT data FROM characters WHERE world_id = ?')
      .all(TEMPLATE_WORLD_ID) as { data: string }[];
    const existingIds = new Set(
      (this.#db.prepare('SELECT id FROM characters WHERE world_id = ?').all(worldId) as { id: string }[]).map(
        (r) => r.id,
      ),
    );
    this.#db.exec('BEGIN');
    try {
      for (const r of templateRows) {
        const inst = JSON.parse(r.data) as CharacterInstanceRecord;
        if (existingIds.has(inst.id)) continue; // additive 只加不改：孩子已有的实例一律不覆盖
        const defId = typeof inst.defId === 'string' ? inst.defId : inst.id;
        this.#writeInstanceRow({ ...inst, worldId, defId });
      }
      this.#db.prepare('UPDATE worlds SET template_version = ? WHERE id = ?').run(templateVersion, worldId);
      this.#db.exec('COMMIT');
    } catch (e) {
      this.#db.exec('ROLLBACK');
      throw e;
    }
  }

  /** 读某实例行现有的 defId（不存在或旧全量 blob 无 defId → undefined）。 */
  #existingInstanceDefId(id: string, worldId: string): string | undefined {
    const row = this.#db.prepare('SELECT data FROM characters WHERE id = ? AND world_id = ?').get(id, worldId) as
      | { data: string }
      | undefined;
    if (!row) return undefined;
    const parsed = JSON.parse(row.data) as { defId?: unknown };
    return typeof parsed.defId === 'string' ? parsed.defId : undefined;
  }

  /** 写一行实例放置记录（characters.data 存实例 JSON，按 defId 引用共享定义）。 */
  #writeInstanceRow(inst: CharacterInstanceRecord): void {
    this.#db
      .prepare(
        'INSERT INTO characters (id, world_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(world_id, id) DO UPDATE SET data = excluded.data',
      )
      .run(inst.id, inst.worldId, JSON.stringify(inst));
  }

  /**
   * 把一行 characters.data 还原成完整 Character（世界模板架构 v2）：有 defId 且能查到共享定义 →
   * 合并；否则视为旧全量 blob（迁移前的存量行）原样返回。合并/回退都不抛，坏定义只降级不崩。
   */
  #hydrateCharacter(parsed: unknown): Character {
    if (parsed && typeof parsed === 'object' && typeof (parsed as { defId?: unknown }).defId === 'string') {
      const inst = parsed as CharacterInstanceRecord;
      const def = this.getCharacterDef(inst.defId);
      if (def) return characterFromDefInstance(def, inst);
    }
    return parsed as Character; // 旧全量 blob（无 defId）或定义丢失兜底
  }

  // ── 角色定义层（character_defs，世界模板架构 v2 §1）──────────────────────────
  // 全局共享的角色身份，按 defId 引用（无 world_id）。P1a：只提供读写，尚未接入 getCharacter/saveCharacter。

  /** 读一份共享角色定义（不存在返回 undefined）。 */
  getCharacterDef(defId: string): CharacterDef | undefined {
    const row = this.#db.prepare('SELECT data FROM character_defs WHERE def_id = ?').get(defId) as { data: string } | undefined;
    if (!row) return undefined;
    return coerceCharacterDef(JSON.parse(row.data)) ?? undefined;
  }

  /** UPSERT 一份共享角色定义（改这里全世界引用者自动生效）。 */
  upsertCharacterDef(def: CharacterDef): void {
    const clean = coerceCharacterDef(def);
    if (!clean) throw new Error(`invalid character def: ${def?.defId}`);
    this.#db
      .prepare('INSERT INTO character_defs (def_id, data) VALUES (?, ?) ON CONFLICT(def_id) DO UPDATE SET data = excluded.data')
      .run(clean.defId, JSON.stringify(clean));
  }

  /** 列出全部共享角色定义（迁移/盘点用）。 */
  listCharacterDefs(): CharacterDef[] {
    const rows = this.#db.prepare('SELECT data FROM character_defs').all() as { data: string }[];
    return rows.map((r) => coerceCharacterDef(JSON.parse(r.data))).filter((d): d is CharacterDef => d !== null);
  }

  /**
   * 记一次玩家↔村民的实质互动，累进熟识度并持久化（村民视角，写 character.relationships[playerId]）。
   * kind='chat' 累加会话轮数（聊过→点头之交）；kind='wish' 累加完成心愿次数（完成过→朋友）。见 social.ts。
   * 仙子/空 playerId/角色不存在 → no-op。返回变化后的熟识度与本次是否跨级升级（供上层决定是否即时通知）。
   */
  recordVillagerBond(worldId: string, npcId: string, playerId: string, kind: 'chat' | 'wish', n = 1): { familiarity: Familiarity; changed: boolean } {
    const c = this.getCharacter(worldId, npcId);
    if (!c || c.isFairy || !playerId) return { familiarity: 'stranger', changed: false };
    const rels: Record<string, unknown> =
      c.relationships && typeof c.relationships === 'object' ? (c.relationships as Record<string, unknown>) : {};
    const before = deriveFamiliarity(rels[playerId]);
    const rel = coerceRelationship(rels[playerId]);
    if (kind === 'chat') rel.chats += n;
    else rel.wishesDone += n;
    rels[playerId] = rel;
    c.relationships = rels as Character['relationships'];
    this.saveCharacter(c);
    const after = deriveFamiliarity(rel);
    return { familiarity: after, changed: after !== before };
  }

  /**
   * 标记「这个村民已主动给这个玩家送过花」（防重复送）。首次 → 置位 + 持久化，返回 true（可送）；
   * 已送过 / 仙子 / 空 playerId / 角色不存在 → 返回 false（不再送）。收花不升熟识度（见 social.ts）。
   */
  markVillagerGifted(worldId: string, npcId: string, playerId: string): boolean {
    const c = this.getCharacter(worldId, npcId);
    if (!c || c.isFairy || !playerId) return false;
    const rels: Record<string, unknown> =
      c.relationships && typeof c.relationships === 'object' ? (c.relationships as Record<string, unknown>) : {};
    const rel = coerceRelationship(rels[playerId]);
    if (rel.gifted) return false;
    rel.gifted = true;
    rels[playerId] = rel;
    c.relationships = rels as Character['relationships'];
    this.saveCharacter(c);
    return true;
  }

  // ── 物品实体（items 表，只存语音造物；内置定义见 items.ts）─────────────

  /** 新增/更新物品实体（语音造物）。内置 id 由 upsert 侧拒绝，防止覆盖代码常量。 */
  upsertItem(def: ItemDef): void {
    if (def.worldId === null) throw new Error(`builtin item 不入库: ${def.id}`);
    if (getBuiltinItem(def.id)) throw new Error(`item id 与内置冲突: ${def.id}`);
    if (!this.#worldExists(def.worldId)) throw new Error(`world not found: ${def.worldId}`);
    this.#db
      .prepare(
        'INSERT INTO items (id, world_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(id) DO UPDATE SET world_id = excluded.world_id, data = excluded.data',
      )
      .run(def.id, def.worldId, JSON.stringify(def));
  }

  /** 物品实体定义：先查内置常量，再查该 world 的造物行。 */
  getItemDef(worldId: string, id: string): ItemDef | undefined {
    const b = getBuiltinItem(id);
    if (b) return b;
    const row = this.#db.prepare('SELECT data FROM items WHERE id = ? AND world_id = ?').get(id, worldId) as
      | { data: string }
      | undefined;
    return row ? (JSON.parse(row.data) as ItemDef) : undefined;
  }

  /** 该 world 的造物实体（不含内置）。 */
  listWorldItems(worldId: string): ItemDef[] {
    const rows = this.#db.prepare('SELECT data FROM items WHERE world_id = ? ORDER BY id').all(worldId) as { data: string }[];
    return rows.map((r) => JSON.parse(r.data) as ItemDef);
  }

  /** 地形矩阵校验用的实体解析器（内置 + 该 world 造物）。 */
  itemResolver(worldId: string): (id: string) => ItemDef | undefined {
    return (id) => this.getItemDef(worldId, id);
  }

  // ── 背包（bag 表：玩家持有的物品实体计数，与钱包同款 (world, player) 维度）──────
  //
  // 摆放 = tile 编辑挂引用 + bagTake；拾起 = tile 编辑清引用 + bagAdd（见 server.ts
  // item_place/item_pickup）。匿名兜底与钱包一致：playerId 为空落 ANON_PLAYER 键。

  /** 背包加 n 份某物品（造物落成/拾起）。 */
  bagAdd(worldId: string, playerId: string, itemId: string, n = 1): void {
    if (!this.#worldExists(worldId)) throw new Error(`world not found: ${worldId}`);
    this.#db
      .prepare(
        'INSERT INTO bag (world_id, player_id, item_id, count) VALUES (?, ?, ?, ?) ' +
          'ON CONFLICT(world_id, player_id, item_id) DO UPDATE SET count = count + excluded.count',
      )
      .run(worldId, this.#walletKey(playerId), itemId, n);
  }

  /** 背包扣 n 份某物品（摆放）。不足 → false 不动账；扣到 0 删行。 */
  bagTake(worldId: string, playerId: string, itemId: string, n = 1): boolean {
    const key = this.#walletKey(playerId);
    const r = this.#db
      .prepare('UPDATE bag SET count = count - ? WHERE world_id = ? AND player_id = ? AND item_id = ? AND count >= ?')
      .run(n, worldId, key, itemId, n);
    if (r.changes === 0) return false;
    this.#db.prepare('DELETE FROM bag WHERE world_id = ? AND player_id = ? AND item_id = ? AND count <= 0').run(worldId, key, itemId);
    return true;
  }

  /** 某玩家的背包（item id → 份数）。 */
  getBag(worldId: string, playerId: string): Record<string, number> {
    const rows = this.#db
      .prepare('SELECT item_id, count FROM bag WHERE world_id = ? AND player_id = ? ORDER BY item_id')
      .all(worldId, this.#walletKey(playerId)) as { item_id: string; count: number }[];
    const out: Record<string, number> = {};
    for (const r of rows) out[r.item_id] = r.count;
    return out;
  }

  /** 某世界所有玩家的背包行（debug 后台用）。 */
  listBags(worldId: string): { playerId: string; itemId: string; count: number }[] {
    const rows = this.#db
      .prepare('SELECT player_id, item_id, count FROM bag WHERE world_id = ? ORDER BY player_id, item_id')
      .all(worldId) as { player_id: string; item_id: string; count: number }[];
    return rows.map((r) => ({ playerId: r.player_id, itemId: r.item_id, count: r.count }));
  }

  /**
   * 存量迁移：props 表（旧 WorldProp 实例）→ items 实体行 + 矩阵 tile 引用/背包计数。
   * placed 且落位合法 → 写进所在场景矩阵（version+1）；场景无矩阵、tile 越界、占地冲突、
   * bagged、无主 → 收进匿名背包（ANON_PLAYER，与旧「全世界共用」行为一致）。
   * 迁移后删 props 行 → 幂等（第二次开库无行可迁）。必须与语义切换同版上线：
   * 旧协议（prop_place/store/take/move）已删，存量物件只能以新形态存在。
   */
  #migratePropsToItems(): void {
    const rows = this.#db.prepare('SELECT id, world_id, data FROM props').all() as
      { id: string; world_id: string; data: string }[];
    if (rows.length === 0) return;
    for (const r of rows) {
      try {
        const prop = JSON.parse(r.data) as WorldProp;
        const def = creationItemDef(r.world_id, prop.id, prop.spec);
        this.upsertItem(def);
        let inMatrix = false;
        if (prop.state === 'placed' && Array.isArray(prop.tile)) {
          const sceneId = prop.sceneId ?? DEFAULT_SCENE;
          const rec = this.getSceneTerrain(r.world_id, sceneId);
          if (rec) {
            try {
              const terrain = decodeTerrain(rec.bytes);
              const [x, y] = prop.tile;
              // tile 编辑对已有引用是覆写语义——目标 tile 已有物品时不许顶掉，收背包
              if (x < 0 || x >= terrain.gridW || y < 0 || y >= terrain.gridH || terrain.itemRef[y * terrain.gridW + x] !== 0) {
                throw new Error('tile occupied/out of range');
              }
              applyTileEdits(terrain, [{ x, y, item: { id: def.id } }], this.itemResolver(r.world_id));
              this.setSceneTerrain(r.world_id, sceneId, encodeTerrain(terrain), rec.version + 1);
              inMatrix = true;
            } catch {
              /* 越界/tile 被占/占地冲突/压水：收进背包，物件绝不凭空消失 */
            }
          }
        }
        if (!inMatrix) this.bagAdd(r.world_id, ANON_PLAYER, def.id);
      } catch (err) {
        console.warn(`props 迁移跳过坏行 ${r.id}：${String(err)}`);
      }
    }
    this.#db.exec('DELETE FROM props');
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
   * sceneId 给了就只返回该场景的地点（消化「委托指向别场景」的边界）；不传=全世界摊平（debug/兼容）。
   * 世界已有场景数据但指定场景无 POI → 返回空（不泄漏别场景地点）；世界完全没入库场景 → 回退客户端上报。
   */
  getLocations(worldId: string, sceneId?: string): string[] {
    const scenes = this.listScenes(worldId);
    if (scenes.length > 0) {
      const relevant = sceneId === undefined ? scenes : scenes.filter((s) => s.sceneId === sceneId);
      const names = relevant.flatMap((s) => s.pois.map((p) => p.name)).filter((n) => n.length > 0);
      if (names.length > 0) return [...new Set(names)];
      if (sceneId !== undefined) return []; // 指定场景无 POI：空，别摊平到别场景
    }
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
      terrainVersion: r.terrain_version,
    };
  }

  getScene(worldId: string, sceneId: string): Scene | undefined {
    const row = this.#db.prepare(`SELECT ${SCENE_COLS} FROM scenes WHERE world_id = ? AND scene_id = ?`).get(worldId, sceneId) as
      | SceneRow
      | undefined;
    return row ? this.#rowToScene(row) : undefined;
  }

  listScenes(worldId: string): Scene[] {
    const rows = this.#db.prepare(`SELECT ${SCENE_COLS} FROM scenes WHERE world_id = ? ORDER BY scene_id`).all(worldId) as unknown as SceneRow[];
    return rows.map((r) => this.#rowToScene(r));
  }

  /**
   * 存量场景迁移：terrain blob 为空但 terrain_asset 指向内容寻址库 → 把字节搬进
   * scenes.terrain（重编码为 v2，v1 存量物品层补零），version 置 1。
   * 幂等（blob 非空即跳过）；资产缺失/字节坏则跳过该场景（本就不可用）。
   */
  #migrateSceneTerrainBlobs(): void {
    const rows = this.#db
      .prepare("SELECT world_id, scene_id, terrain_asset FROM scenes WHERE terrain IS NULL AND terrain_asset != ''")
      .all() as { world_id: string; scene_id: string; terrain_asset: string }[];
    for (const r of rows) {
      const blob = this.getAsset(r.terrain_asset);
      if (!blob) continue;
      try {
        const bytes = encodeTerrain(decodeTerrain(blob.bytes));
        this.setSceneTerrain(r.world_id, r.scene_id, bytes, 1);
      } catch {
        /* 坏字节：跳过，别让一个坏场景拦启动 */
      }
    }
  }

  /** 场景地形矩阵（v2 blob）与版本。场景未入库/无地形 → undefined。 */
  getSceneTerrain(worldId: string, sceneId: string): { bytes: Uint8Array; version: number } | undefined {
    const row = this.#db
      .prepare('SELECT terrain, terrain_version FROM scenes WHERE world_id = ? AND scene_id = ?')
      .get(worldId, sceneId) as { terrain: Uint8Array | null; terrain_version: number } | undefined;
    if (!row || row.terrain === null) return undefined;
    return { bytes: new Uint8Array(row.terrain), version: row.terrain_version };
  }

  /** 写入场景地形矩阵与版本（唯一写入口是 terrain_edit.ts / /admin/scenes）。 */
  setSceneTerrain(worldId: string, sceneId: string, bytes: Uint8Array, version: number): void {
    const r = this.#db
      .prepare('UPDATE scenes SET terrain = ?, terrain_version = ? WHERE world_id = ? AND scene_id = ?')
      .run(bytes, version, worldId, sceneId);
    if (r.changes === 0) throw new Error(`scene not found: ${worldId}/${sceneId}`);
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
    if (!this.#worldExists(worldId)) return { flowers: 0, stampProgress: 0, stampsTotal: 0, hearts: 0 };
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
    if (!this.#worldExists(worldId)) return { flowerGained: false, wallet: { flowers: 0, stampProgress: 0, stampsTotal: 0, hearts: 0 } };
    const w = this.getWallet(worldId, playerId);
    w.stampsTotal += 1;
    w.stampProgress += 1;
    const flowerGained = settleWallet(w);
    this.#setWallet(worldId, playerId, w);
    return { flowerGained, wallet: w };
  }

  /** 收 1 颗爱心（玩家互动送❤）：只增不减、不动小红花。返回结算后的钱包；世界不存在返回空账。 */
  addHeart(worldId: string, playerId: string): Wallet {
    if (!this.#worldExists(worldId)) return { flowers: 0, stampProgress: 0, stampsTotal: 0, hearts: 0 };
    const w = this.getWallet(worldId, playerId);
    w.hearts += 1;
    this.#setWallet(worldId, playerId, w);
    return w;
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

  /** 某玩家在某世界已发现的玩法（wishes.ts 的 ability 名）。没有行 = 什么都还没发现。 */
  getDiscovered(worldId: string, playerId: string): string[] {
    const row = this.#db
      .prepare('SELECT data FROM player_discovered WHERE world_id = ? AND player_id = ?')
      .get(worldId, this.#walletKey(playerId)) as { data: string } | undefined;
    if (!row) return [];
    try {
      const raw: unknown = JSON.parse(row.data);
      return Array.isArray(raw) ? raw.filter((a): a is string => typeof a === 'string') : [];
    } catch {
      return []; // 行损坏当作没发现过：最坏结果是村民多念叨一次，不该因此崩
    }
  }

  /**
   * 记一个玩法为「已发现」。返回 true 表示这是【第一次】发现它——
   * 调用方据此决定要不要重发漏话（心愿池变了）+ 判定心愿达成。已发现过则原样返回 false、不写库。
   */
  addDiscovered(worldId: string, playerId: string, ability: string): boolean {
    if (!this.#worldExists(worldId)) return false;
    const cur = this.getDiscovered(worldId, playerId);
    if (cur.includes(ability)) return false;
    cur.push(ability);
    this.#db
      .prepare(
        'INSERT INTO player_discovered (world_id, player_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(world_id, player_id) DO UPDATE SET data = excluded.data',
      )
      .run(worldId, this.#walletKey(playerId), JSON.stringify(cur));
    return true;
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

  // ── M2 章回剧情进度（story_progress 表；键归一与钱包一致，匿名落 ANON_PLAYER）──

  /** 读某玩家在某世界的剧情进度。没有行/行损坏 → 空进度（不写库，懒惰到第一次 set）。 */
  getStoryProgress(worldId: string, playerId: string): StoryProgress {
    const row = this.#db
      .prepare('SELECT data FROM story_progress WHERE world_id = ? AND player_id = ?')
      .get(worldId, this.#walletKey(playerId)) as { data: string } | undefined;
    if (!row) return { books: {} };
    let raw: unknown = null;
    try {
      raw = JSON.parse(row.data);
    } catch {
      raw = null;
    }
    return coerceStoryProgress(raw);
  }

  setStoryProgress(worldId: string, playerId: string, sp: StoryProgress): void {
    if (!this.#worldExists(worldId)) return;
    this.#db
      .prepare(
        'INSERT INTO story_progress (world_id, player_id, data) VALUES (?, ?, ?) ' +
          'ON CONFLICT(world_id, player_id) DO UPDATE SET data = excluded.data',
      )
      .run(worldId, this.#walletKey(playerId), JSON.stringify(sp));
  }

  /** 列出某世界里所有玩家的进行中委托（debug 后台用）。 */
  listActiveTasks(worldId: string): { playerId: string; task: ActiveTask }[] {
    const rows = this.#db
      .prepare('SELECT player_id, data FROM player_tasks WHERE world_id = ? ORDER BY player_id')
      .all(worldId) as { player_id: string; data: string }[];
    return rows.map((r) => ({ playerId: r.player_id, task: JSON.parse(r.data) as ActiveTask }));
  }

  /**
   * 世界里的角色。传 sceneId 则只返回该场景的角色（缺 sceneId 的存量角色按 DEFAULT_SCENE 归入），
   * 但点点恒在——她跨场景跟随玩家，任何场景查询都带上她（委托候选/花名册在调用点各自排除 isFairy）；
   * 不传 = 全世界所有场景（保持既有调用点行为不变）。
   */
  listCharacters(worldId: string, sceneId?: string): Character[] {
    const rows = this.#db.prepare('SELECT data FROM characters WHERE world_id = ?').all(worldId) as { data: string }[];
    const all = rows.map((r) => this.#hydrateCharacter(JSON.parse(r.data)));
    if (sceneId === undefined) return all;
    return all.filter((c) => c.isFairy || (c.sceneId ?? DEFAULT_SCENE) === sceneId);
  }

  getCharacter(worldId: string, characterId: string): Character | undefined {
    const row = this.#db
      .prepare('SELECT data FROM characters WHERE id = ? AND world_id = ?')
      .get(characterId, worldId) as { data: string } | undefined;
    return row ? this.#hydrateCharacter(JSON.parse(row.data)) : undefined;
  }

  /**
   * 角色所在 tile 的落位回报（positions_report）。空间授权在客户端，服务端只记最后位置供重载读回。
   * 角色不存在 → false 不动账。tile 合法性由调用方（server.ts）先行校验。
   * sceneId 给了且与角色当前场景一致才落位；不一致整条拒绝（scene-drag-guard）——
   * NPC 不会走 portal，跨场景上报只可能是客户端脏数据（实锤案例：旧客户端初载把全库角色
   * 降生在村庄再上报，把森林村民整批拖回 village）。角色换场景走 admin 修数据端点。
   */
  setCharacterTile(worldId: string, characterId: string, tile: TilePos, sceneId?: string): boolean {
    const character = this.getCharacter(worldId, characterId);
    if (!character) return false;
    if (sceneId !== undefined && (character.sceneId ?? DEFAULT_SCENE) !== sceneId) return false;
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

  /** 玩家在某世界某场景的最后位置。没去过 → undefined（客户端按点点旁降生）。 */
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

  /** 落/更新玩家 onboarding 档案（键=playerId；整对象 UPSERT 一行，重跑 onboarding 覆盖旧档）。 */
  saveOnboardingProfile(profile: PlayerOnboardingProfile): void {
    this.#db
      .prepare('INSERT INTO player_onboarding (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data')
      .run(profile.playerId, JSON.stringify(profile));
  }

  getOnboardingProfile(playerId: string): PlayerOnboardingProfile | undefined {
    const row = this.#db.prepare('SELECT data FROM player_onboarding WHERE id = ?').get(playerId) as { data: string } | undefined;
    return row ? (JSON.parse(row.data) as PlayerOnboardingProfile) : undefined;
  }

  listOnboardingProfiles(): PlayerOnboardingProfile[] {
    const rows = this.#db.prepare('SELECT data FROM player_onboarding').all() as { data: string }[];
    return rows.map((r) => JSON.parse(r.data) as PlayerOnboardingProfile);
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

  /**
   * 删掉「无立绘」空玩家档：name 与 spriteAsset 均为空的行。历史上客户端在小朋友还没建
   * 角色时也会带全空 profile 上报 world_info，服务端旧逻辑据此建了一批空档（见 server.ts
   * world_info handler 与 test/player_registration.test.ts）。返回被删的 playerId 列表。
   * 只删 players 行本身——visits 等按 playerId 的关联记录留着（会话史/设备快照仍可追溯）。
   */
  deleteEmptyPlayers(): string[] {
    const empty = this.listPlayers().filter((p) => (p.name ?? '') === '' && (p.spriteAsset ?? '') === '');
    const del = this.#db.prepare('DELETE FROM players WHERE id = ?');
    for (const p of empty) del.run(p.id);
    return empty.map((p) => p.id);
  }

  /**
   * 某个资产存不存在——只查清单，不读字节（O(1)，不碰磁盘）。
   * 体检要扫全库的引用，用 getAsset 会把每张图都读进来，纯浪费。
   */
  hasAsset(hash: string): boolean {
    return this.#assetMime.has(hash);
  }

  /**
   * 体检：找出"库里引用了、但资产库里没有"的死引用。
   *
   * 这种引用会让客户端拿到一个 404 的立绘。已知成因：2026-07-09 切 ghcr 部署时
   * assets/ 里 7/9 之前的文件没搬过去（world.db 搬过去了）——库记得那张图，盘上没有。
   */
  listDeadSpriteRefs(): { kind: 'player' | 'character'; id: string; name: string; hash: string; worldId?: string }[] {
    const dead: { kind: 'player' | 'character'; id: string; name: string; hash: string; worldId?: string }[] = [];
    for (const p of this.listPlayers()) {
      if (p.spriteAsset && !this.hasAsset(p.spriteAsset)) {
        dead.push({ kind: 'player', id: p.id, name: p.nickname || p.name || '(无名)', hash: p.spriteAsset });
      }
    }
    // 复合 PK 后同 id 可跨世界共存：带上 world_id 供 clearDeadSpriteRefs 精确回写这一行。
    const rows = this.#db.prepare('SELECT id, world_id, data FROM characters').all() as { id: string; world_id: string; data: string }[];
    for (const r of rows) {
      const c = this.#hydrateCharacter(JSON.parse(r.data)); // 立绘在定义层：合并后才看得到 appearance/name
      const hash = c.appearance?.spriteAsset;
      if (hash && !this.hasAsset(hash)) {
        dead.push({ kind: 'character', id: c.id, name: c.name, hash, worldId: r.world_id });
      }
    }
    return dead;
  }

  /**
   * 把死引用置空（那张图已经不存在了，留着引用只会让客户端一直拿 404）。
   * 置空后玩家/角色回落到默认形象；真要形象，走各自的重生成端点。返回清了几条。
   */
  clearDeadSpriteRefs(): number {
    const dead = this.listDeadSpriteRefs();
    for (const d of dead) {
      if (d.kind === 'player') {
        const p = this.getPlayer(d.id);
        if (p) this.upsertPlayer({ ...p, spriteAsset: '' });
      } else {
        // 复合 PK：按 (world_id, id) 精确取这一行；appearance 虽在共享定义层、清一次即全世界生效，
        // 但仍精确回写自己那行避免 .get() 命中同 id 的另一世界实例（行为无害但不精确）。
        const row = this.#db.prepare('SELECT data FROM characters WHERE id = ? AND world_id = ?').get(d.id, d.worldId ?? '') as
          | { data: string }
          | undefined;
        if (row) {
          const c = this.#hydrateCharacter(JSON.parse(row.data)); // appearance 在定义层，合并后再改
          c.appearance = { ...c.appearance, spriteAsset: '' };
          this.saveCharacter(c); // 拆写会把清空后的 appearance upsert 回共享定义
        }
      }
    }
    return dead.length;
  }

  // ── 长期记忆（P3：结构化，按 owner NPC × aboutPlayer 维度；见 types.MemoryItem）──────

  /** 旧存量 Character.memory[] → memories 表（aboutPlayer='' 未绑定历史）。幂等：搬完清空 memory[]。 */
  #migrateLegacyMemories(): void {
    // 复合 PK 后 UPDATE 必须带 world_id，否则同 id 跨世界会被一起写脏（用 DB 列而非 blob 字段，稳）。
    const rows = this.#db.prepare('SELECT id, world_id, data FROM characters').all() as { id: string; world_id: string; data: string }[];
    for (const row of rows) {
      const c = JSON.parse(row.data) as Character;
      if (!Array.isArray(c.memory) || c.memory.length === 0) continue;
      for (const text of c.memory) {
        if (typeof text === 'string' && text.trim()) {
          this.addMemory(c.id, { text: text.trim(), kind: 'event', aboutPlayer: '', ts: 0 });
        }
      }
      c.memory = []; // 清空，避免重复迁移（幂等）
      this.#db.prepare('UPDATE characters SET data = ? WHERE id = ? AND world_id = ?').run(JSON.stringify(c), row.id, row.world_id);
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
    // 复合 PK 后 UPDATE 必须带 world_id（同 #migrateLegacyMemories），免得同 id 跨世界互相写脏。
    const rows = this.#db.prepare('SELECT id, world_id, data FROM characters').all() as { id: string; world_id: string; data: string }[];
    for (const row of rows) {
      const c = JSON.parse(row.data) as Character;
      if (!Array.isArray(c.chatHistory) || c.chatHistory.length === 0) continue;
      for (const t of c.chatHistory) {
        if (t && (t.role === 'child' || t.role === 'npc') && typeof t.text === 'string') {
          this.addChatTurn(c.id, '', t.role, t.text, typeof t.ts === 'number' ? t.ts : 0);
        }
      }
      c.chatHistory = []; // 清空，避免重复迁移（幂等）
      this.#db.prepare('UPDATE characters SET data = ? WHERE id = ? AND world_id = ?').run(JSON.stringify(c), row.id, row.world_id);
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

  /**
   * 开一段会话，返回 visitId（ended_at 置空=进行中）。startedAt 由调用方传（server 用 Date.now）。
   * device 为本次连接的设备快照（activity 记录）；无则 null。
   */
  startVisit(worldId: string, playerId: string, startedAt: number, device?: DeviceSnapshot | null): number {
    // 纵深护栏：world 不存在就不落 visit（否则 world_info 带个乱 worldId 连上来会留孤儿 visit 行）。
    // 返回 -1 表示未落库，调用方（startSessionVisit）据此不起会话。
    if (!this.#worldExists(worldId)) return -1;
    const info = this.#db
      .prepare('INSERT INTO visits (world_id, player_id, started_at, ended_at, device) VALUES (?, ?, ?, NULL, ?)')
      .run(worldId, playerId, startedAt, device ? JSON.stringify(device) : null);
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
        ? this.#db.prepare('SELECT id, world_id, player_id, started_at, ended_at, device FROM visits ORDER BY started_at DESC').all()
        : this.#db
            .prepare('SELECT id, world_id, player_id, started_at, ended_at, device FROM visits WHERE world_id = ? ORDER BY started_at DESC')
            .all(worldId)
    ) as { id: number; world_id: string; player_id: string; started_at: number; ended_at: number | null; device: string | null }[];
    return rows.map((r) => ({
      id: r.id,
      worldId: r.world_id,
      playerId: r.player_id,
      startedAt: r.started_at,
      endedAt: r.ended_at,
      device: r.device ? (JSON.parse(r.device) as DeviceSnapshot) : null,
    }));
  }

  /**
   * activity 记录：会话 + 设备快照，倒序分页。给管理台看"谁、用什么设备、何时来、玩多久"。
   * 只读，直连查询。带 limit/offset（管理台翻页）。
   */
  listActivity(limit = 100, offset = 0): Visit[] {
    const rows = this.#db
      .prepare('SELECT id, world_id, player_id, started_at, ended_at, device FROM visits ORDER BY started_at DESC LIMIT ? OFFSET ?')
      .all(Math.max(1, Math.min(500, limit)), Math.max(0, offset)) as {
      id: number; world_id: string; player_id: string; started_at: number; ended_at: number | null; device: string | null;
    }[];
    return rows.map((r) => ({
      id: r.id,
      worldId: r.world_id,
      playerId: r.player_id,
      startedAt: r.started_at,
      endedAt: r.ended_at,
      device: r.device ? (JSON.parse(r.device) as DeviceSnapshot) : null,
    }));
  }

  /** activity 总条数（分页用）。 */
  countVisits(): number {
    return this.#count('visits');
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
    this.#assetMime.set(hash, blob.mime);
    this.#cachePut(hash, blob);
    if (this.#dir !== null) {
      mkdirSync(this.#assetsDir(), { recursive: true });
      writeFileSync(join(this.#assetsDir(), hash), Buffer.from(blob.bytes));
      this.#persistAssetIndex();
    }
    return hash;
  }

  /**
   * 取资源字节。缓存命中直接给；未命中就回源读盘并放进缓存（内存 store 没有盘可回源，
   * 缓存里没有就是真没有）。清单里没登记 / 盘上文件不在 → undefined。
   */
  getAsset(hash: string): ImageBlob | undefined {
    const hit = this.#assetCache.get(hash);
    if (hit) {
      // LRU：命中的挪到队尾（Map 保序，delete + set 即"刚用过"）
      this.#assetCache.delete(hash);
      this.#assetCache.set(hash, hit);
      return hit;
    }
    if (this.#dir === null) return undefined;
    const mime = this.#assetMime.get(hash);
    if (mime === undefined) return undefined;
    const p = join(this.#assetsDir(), hash);
    if (!existsSync(p)) return undefined; // 清单有、盘上没有的孤儿条目
    const blob: ImageBlob = { bytes: new Uint8Array(readFileSync(p)), mime };
    this.#cachePut(hash, blob);
    return blob;
  }

  /** 取某立绘的 idle 动画记录（无则 undefined，客户端据此保留静态或轮询）。 */
  getSpriteAnim(spriteHash: string): SpriteAnimRecord | undefined {
    return this.#spriteAnims.get(spriteHash);
  }

  setSpriteAnimPending(spriteHash: string): void {
    this.#spriteAnims.set(spriteHash, { status: 'pending' });
    this.#persistSpriteAnims();
  }

  /**
   * 置 ready。extra 带图集版本与三段原片的资产 hash（v2 路径必传；v1 老路径不传，
   * 记录里就没有 version/clipVideos，回填会认出它是老版本并重跑）。
   */
  setSpriteAnimReady(
    spriteHash: string,
    animAsset: string,
    meta: SpriteSheetMeta,
    extra?: { version?: number; packVersion?: number; clipVideos?: Partial<Record<ClipName, string>> },
  ): void {
    this.#spriteAnims.set(spriteHash, { status: 'ready', animAsset, meta, ...extra });
    this.#persistSpriteAnims();
  }

  /** 所有「存有三段原片」的立绘 hash —— repack-all 的工作清单（v1 老记录没有原片，不在内）。 */
  listSpriteAnimsWithClips(): string[] {
    const out: string[] = [];
    for (const [hash, rec] of this.#spriteAnims) {
      if (rec.status === 'ready' && rec.clipVideos) out.push(hash);
    }
    return out;
  }

  setSpriteAnimFailed(spriteHash: string): void {
    this.#spriteAnims.set(spriteHash, { status: 'failed' });
    this.#persistSpriteAnims();
  }
}
