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
  itemId?: string;
  message?: string;
  rewardId: string;
}

export interface WorldRow {
  id: string;
  inventory: Record<string, number>;
  activeTask: ActiveTask | null;
  locations: string[];
  characterCount: number;
  fairyCount: number;
  propCount: number;
  visitCount: number;
  activeVisitCount: number;
}

export interface CharacterSummary {
  id: string;
  name: string;
  isFairy: boolean;
  state: string;
  position: { tileX: number; tileY: number };
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
}

export interface WorldDetail extends WorldRow {
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

/** 贴纸 id → emoji（与 server/src/types.ts STICKERS 对齐；后台展示用）。 */
export const STICKER_GLYPHS: Record<string, string> = {
  flower: '🌸',
  apple: '🍎',
  star: '⭐',
  shell: '🐚',
  ladybug: '🐞',
  candy: '🍬',
  clover: '🍀',
  gem: '💎',
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
