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
  props: number;
  visits: { total: number; active: number };
  creationIcons: number;
  recentVisits: Visit[];
}

export interface Player {
  id: string;
  name: string;
  nickname: string;
  gender: string;
  color: string;
  spriteAsset: string;
  createdAt: string;
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

export interface PlayerDetail {
  player: Player;
  visits: Visit[];
  memories: { worldId: string; characterId: string; characterName: string; items: MemoryItem[] }[];
  chats: { worldId: string; characterId: string; characterName: string; turns: ChatTurn[] }[];
  spriteAnim: SpriteAnimRecord;
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
  propCount: number;
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
  footprintW: number;
  footprintH: number;
  blocking: boolean;
  pathOk: boolean;
  wander: number;
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

export interface WorldProp {
  id: string;
  spec: { name?: string; [k: string]: unknown };
  tile: [number, number] | null;
  state: 'placed' | 'bagged';
  /** 物件所在场景（后端缺省归 DEFAULT_SCENE）。 */
  sceneId?: string;
}

export interface WorldDetail extends WorldRow {
  scenes: Scene[];
  characters: CharacterSummary[];
  props: WorldProp[];
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
  appearance: { visualDescription: string; spriteAsset: string; scale: number };
  state: string;
  behaviorScript: { commands: { type: string; params: Record<string, unknown> }[]; loop: boolean };
  position: { tileX: number; tileY: number };
  abilities: string[];
  relationships: Record<string, string>;
}

/** 图集动画 meta（与 server sprite_sheet.ts SpriteSheetMeta 对齐）。 */
export interface SpriteAnimMeta {
  cols: number;
  rows: number;
  frameCount: number;
  fps: number;
  cellW: number;
  cellH: number;
}

/** /sprite-anim/:hash 的返回（none/pending/ready/failed）。 */
export interface SpriteAnimRecord {
  status: string;
  animAsset?: string;
  meta?: SpriteAnimMeta;
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
};

export const TASK_TYPE_LABELS: Record<string, string> = {
  deliver: '带话',
  bring: '带来',
  visit: '到访',
  gift: '送礼',
};
