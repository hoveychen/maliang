// /debug/api/* 响应类型（与 server/src/debug_api.ts、server/src/types.ts 口径对齐）

export interface Visit {
  id: number;
  worldId: string;
  playerId: string;
  startedAt: number;
  endedAt: number | null;
}

export interface Overview {
  players: number;
  worlds: number;
  characters: number;
  items: number;
  visits: { total: number; active: number };
  creationIcons: number;
  recentVisits: Visit[];
}

// 贴纸锚点：归一化到 trim 后立绘（x,y ∈ [0,1]，原点左上），后端 debug API 整对象透出（见 debug_api.ts）。
export interface AnchorPoint { x: number; y: number; }
export interface CharacterAnchors {
  headTop: AnchorPoint;
  handL: AnchorPoint;
  handR: AnchorPoint;
  source: 'vision' | 'fallback';
}

export interface Player {
  id: string;
  name: string;
  nickname: string;
  gender: string;
  color: string;
  spriteAsset: string;
  createdAt: string;
  anchors?: CharacterAnchors; // 玩家形象的贴纸锚点（随 world_info 上报落 Player，见服务端 §5）
}

export interface PlayerRow extends Player {
  visitCount: number;
  lastVisitAt: number | null;
}

export interface MemoryItem {
  text: string;
  kind: string;
  aboutPlayer: string;
  aboutCharacter?: string;
  ts: number;
}

export interface ChatTurn {
  playerId: string;
  role: 'child' | 'npc';
  text: string;
  ts: number;
}

/** onboarding 形象对话累积的结构化属性（服务端 AvatarAttrs 同形）。 */
export interface AvatarAttrs {
  gender?: string;
  hairstyle?: string;
  outfit?: string;
  color?: string;
  motifs: string[];
  extras: string[];
  accessory?: string;
}

/** 玩家 onboarding 档案（服务端 PlayerOnboardingProfile 同形；玩家详情 additive 字段 + 总表端点）。 */
export interface OnboardingProfile {
  playerId: string;
  name: string;
  nickname: string;
  attrs: AvatarAttrs;
  visualDescription: string;
  refineNotes: string[];
  spriteAsset: string;
  createdAt: string;
}

export interface PlayerDetail {
  player: Player;
  visits: Visit[];
  memories: { worldId: string; characterId: string; characterName: string; items: MemoryItem[] }[];
  chats: { worldId: string; characterId: string; characterName: string; turns: ChatTurn[] }[];
  spriteAnim: SpriteAnimRecord;
  /** onboarding 档案（无档案 null——升级前的服务端也可能不带此字段）。 */
  onboarding?: OnboardingProfile | null;
}

export interface ActiveTask {
  id: string;
  type: string;
  npcId: string;
  npcName: string;
  targetName?: string;
  locationName?: string;
  message?: string;
  /** 完成时盖的章款式 id（STAMP_STYLES 之一，纯演出）。 */
  stampStyle: string;
}

/** 玩家钱包：小红花代币 + 集邮盖章进度（与 server/src/types.ts Wallet 对齐）。 */
export interface Wallet {
  flowers: number;
  stampProgress: number;
  stampsTotal: number;
}

/** 与 server/src/types.ts 对齐：小红花上限 / 每满几章换一朵花。 */
export const MAX_FLOWERS = 9;
export const STAMPS_PER_FLOWER = 3;

/** 钱包/委托按 (worldId, playerId) 分（playerId='' 为匿名连接共用）。 */
export interface WalletEntry {
  playerId: string;
  wallet: Wallet;
}

export interface ActiveTaskEntry {
  playerId: string;
  task: ActiveTask;
}

export interface WorldRow {
  id: string;
  wallets: WalletEntry[];
  activeTasks: ActiveTaskEntry[];
  locations: string[];
  sceneCount: number;
  characterCount: number;
  fairyCount: number;
  itemCount: number;
  visitCount: number;
  activeVisitCount: number;
}

/** 场景里的一个地点（与 server/src/types.ts ScenePoi 对齐）。 */
export interface ScenePoi {
  tile: [number, number];
  radius: number;
  trigger: string;
  name: string;
  aliases: string[];
}

/** 场景之间的传送点（与 server/src/types.ts ScenePortal 对齐）。 */
export interface ScenePortal {
  tile: [number, number];
  radius: number;
  toScene: string;
  toTile: [number, number];
}

/** 场景 = 世界里的一片区域（模型 B，与 server/src/types.ts Scene 对齐）。 */
export interface Scene {
  worldId: string;
  sceneId: string;
  name: string;
  terrainAsset: string;
  gridTiles: number;
  pois: ScenePoi[];
  portals: ScenePortal[];
  /** 地形矩阵版本（tile 编辑每次 +1；0 = 尚无矩阵 blob）。 */
  terrainVersion: number;
}

/** 物品实体定义（与 server/src/types.ts ItemDef 对齐；矩阵 palette 的解引用）。 */
export interface AdminItemDef {
  id: string;
  worldId: string | null;
  name: string;
  renderRef: string;
  spec?: { name?: string; [k: string]: unknown };
  footprintW: number;
  footprintH: number;
  blocking: boolean;
  pathOk: boolean;
  wander: number;
}

/** 物品实体 + 外观缩略图 hash + 用量（/debug/api/items 每行；内置 def 与造物共用）。 */
export interface ItemDefWithIcon extends AdminItemDef {
  themes?: string[];
  mount?: 'tile' | 'edge';
  /** 客户端渲染上传的缩略图资产 hash（空串 = 尚未渲染）。 */
  iconHash: string;
  /** 被多少场景的矩阵 palette 引用（粗略用量指标）。 */
  sceneRefs: number;
}

/** 物品全景（/debug/api/items）：内置 def + 各世界造物，带缩略图与计数。 */
export interface ItemsResponse {
  builtin: ItemDefWithIcon[];
  creations: ItemDefWithIcon[];
  counts: { builtin: number; creations: number; withIcon: number };
}

/** 背包计数行（与 server listBags 对齐；playerId='' 为匿名）。 */
export interface BagEntry {
  playerId: string;
  itemId: string;
  count: number;
}

/** 场景地形矩阵（/debug/api/worlds/:id/scenes/:sid/terrain-grid 的解码 JSON）。 */
export interface TerrainGrid {
  version: number;
  gridW: number;
  gridH: number;
  types: number[];    // 0 草 / 1 路 / 2 水
  heights: number[];  // 台阶级
  depths: number[];   // 水深（仅水 tile 非零）
  itemRef: number[];  // 0=无 / 1..=palette 索引
  itemArg: number[];  // 朝向 256 档
  palette: string[];
  items: (AdminItemDef | null)[]; // 与 palette 同序（无法解析的为 null）
}

export interface CharacterSummary {
  id: string;
  name: string;
  isFairy: boolean;
  state: string;
  position: { tileX: number; tileY: number };
  /** 角色所在场景（后端缺省归 DEFAULT_SCENE）；后台地图按场景归位。 */
  sceneId: string;
  personality: string;
  spriteAsset: string;
  scale: number;
  voiceId: string;
  greetingStyle: string;
  abilities: string[];
  memoryCount: number;
  chatTurnCount: number;
  spriteAnimStatus: string;
}

export interface WorldDetail extends WorldRow {
  scenes: Scene[];
  characters: CharacterSummary[];
  /** 世界的语音造物实体（摆着的引用在场景矩阵里，见 terrain-grid）。 */
  items: AdminItemDef[];
  /** 各玩家背包计数。 */
  bags: BagEntry[];
  visits: Visit[];
}

export interface Character {
  id: string;
  worldId: string;
  isFairy: boolean;
  name: string;
  personality: string;
  voiceId: string;
  greetingStyle?: string;
  appearance: { visualDescription: string; spriteAsset: string; scale: number; anchors?: CharacterAnchors };
  state: string;
  behaviorScript: { commands: { type: string; params: Record<string, unknown> }[]; loop: boolean };
  position: { tileX: number; tileY: number };
  abilities: string[];
  relationships: Record<string, string>;
}

/** 图集分段名（与 server sprite_sheet.ts CLIP_NAMES 对齐；moving 不生成、走客户端程序化）。 */
export type ClipName = 'idle' | 'talking' | 'moving';
/** 某一段在图集里的起止：start 起始帧、count 帧数（行主序全局下标）。 */
export interface ClipRange { start: number; count: number }

/** 图集动画 meta（与 server sprite_sheet.ts SpriteSheetMeta 对齐）。 */
export interface SpriteAnimMeta {
  cols: number;
  rows: number;
  frameCount: number;
  fps: number;
  cellW: number;
  cellH: number;
  /** 多段图集（v2）：idle/talking 各自的起止帧；缺省（v1 单段）时整张当 idle。 */
  clips?: Partial<Record<ClipName, ClipRange>>;
}

/** 分段中文标签，后台预览用。 */
export const CLIP_LABELS: Record<ClipName, string> = {
  idle: 'idle · 待机',
  talking: 'talking · 说话',
  moving: 'moving · 走动',
};

/** /sprite-anim/:hash 的返回（none/pending/ready/failed）。 */
export interface SpriteAnimRecord {
  status: string;
  animAsset?: string;
  meta?: SpriteAnimMeta;
  /** Seedance 生成的原始绿幕 mp4：ClipName → 原片 asset hash（存了原片可纯本地重抽帧，见服务端 idle_animation.ts）。 */
  clipVideos?: Partial<Record<ClipName, string>>;
}

export interface CharacterDetail {
  character: Character;
  memories: MemoryItem[];
  chatTurns: ChatTurn[];
  spriteAnim: SpriteAnimRecord;
}

/** 盖章款式 id → emoji（与 server/src/types.ts STAMP_STYLES 对齐；后台展示用）。 */
export const STAMP_GLYPHS: Record<string, string> = {
  star: '⭐',
  smile: '😊',
  paw: '🐾',
  medal: '🏅',
  heart: '❤️',
};

export const MEMORY_KIND_LABELS: Record<string, string> = {
  identity: '身份',
  preference: '喜好',
  promise: '约定',
  event: '事件',
  relation: '关系',
  creation: '造物',
};

export const TASK_TYPE_LABELS: Record<string, string> = {
  deliver: '带话',
  bring: '带来',
  visit: '到访',
  gift: '送礼',
};

/** 备份包的 manifest（服务端 persistence.ts BackupManifest 的手工副本，改一处必须改两处）。 */
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

/** POST /admin/restore 的返回。 */
export interface RestoreResponse {
  ok: boolean;
  manifest: BackupManifest;
  /** 被覆盖的旧数据另存成了哪个包（服务器上的路径）。 */
  preRestoreBackup: string;
}

/** GET /admin/integrity —— 库体检结果。 */
export interface Integrity {
  /** 库里记着、但资产库里没有那个文件的引用（客户端会一直拿 404）。 */
  deadSpriteRefs: { kind: 'player' | 'character'; id: string; name: string; hash: string }[];
  deviceSamples: { gpu: string; benchVersion: number; deviceId: string; p95Ms: number }[];
}

/** POST /admin/integrity/fix 的返回（dryRun 与 apply 两种形态）。 */
export interface IntegrityFix {
  dryRun: boolean;
  clearedSpriteRefs?: number;
  deletedDeviceSamples?: number;
  wouldClearSpriteRefs?: Integrity['deadSpriteRefs'];
}

/** GET /debug/api/activity 的一行：会话 + 设备快照。 */
export interface ActivityRow {
  id: number;
  worldId: string;
  playerId: string;
  playerName: string;
  startedAt: number;
  endedAt: number | null;
  durationMs: number | null;
  device: {
    ip?: string;
    ua?: string;
    model?: string;
    os?: string;
    osVersion?: string;
    screen?: string;
    godot?: string;
    app?: string;
  } | null;
}

export interface ActivityResp {
  total: number;
  limit: number;
  offset: number;
  activity: ActivityRow[];
}
