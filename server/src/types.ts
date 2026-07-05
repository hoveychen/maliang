// maliang 后端核心类型与造角色协议。客户端是 GDScript，不共享代码，
// 但 WS/REST 协议字段以本文件为准（见 docs/tech-design.md §5.1、§6）。

export interface ChatTurn {
  role: 'child' | 'npc';
  text: string;
  ts: number;
}

export interface BehaviorCommand {
  type: string; // move_to | wander | wait | follow | stop_follow | do_action | chat_with | deliver_message | give | say | emote | face | create_character
  params: Record<string, unknown>;
}

export interface BehaviorScript {
  commands: BehaviorCommand[];
  loop: boolean;
}

/** 所有村民共有的基础交互能力（与 scripts/behavior_executor.gd 的指令集对齐）。
 * 存量角色 abilities 里可能只有旧的两项，意图 prompt 按「基础集 ∪ 角色自带」取并集，免数据迁移。 */
export const BASE_ABILITIES = ['move_to', 'follow', 'stop_follow', 'do_action', 'chat_with', 'deliver_message'];

// ── 奖赏系统：贴纸收集册 + NPC 委托 ────────────────────────────────────────

/** 贴纸目录：委托奖励的收集品（去文字化，大 emoji 图标）。id 稳定入存档，glyph 供客户端展示。 */
export const STICKERS: readonly { id: string; glyph: string }[] = [
  { id: 'flower', glyph: '🌸' },
  { id: 'apple', glyph: '🍎' },
  { id: 'star', glyph: '⭐' },
  { id: 'shell', glyph: '🐚' },
  { id: 'ladybug', glyph: '🐞' },
  { id: 'candy', glyph: '🍬' },
  { id: 'clover', glyph: '🍀' },
  { id: 'gem', glyph: '💎' },
];

export function stickerGlyph(id: string): string {
  return STICKERS.find((s) => s.id === id)?.glyph ?? '⭐';
}

/** 贴纸的中文叫法 → id（意图 prompt 词汇表与 mock 解析共用；小朋友说「把花送给小蓝」）。 */
export const STICKER_NAMES: Record<string, string> = {
  花: 'flower',
  苹果: 'apple',
  星星: 'star',
  贝壳: 'shell',
  瓢虫: 'ladybug',
  糖果: 'candy',
  四叶草: 'clover',
  宝石: 'gem',
};

/** 委托类型：完成判定全部是客户端确定性事件（送达回调/相邻/到点/交接），不靠 LLM 猜。 */
export type TaskType = 'deliver' | 'bring' | 'visit' | 'gift';

/** 进行中的委托。同一时刻至多一个（幼儿单任务心智，完成判定也无歧义）。 */
export interface ActiveTask {
  id: string;
  type: TaskType;
  npcId: string; // 委托人（完成后由它庆祝/表扬）
  npcName: string;
  targetName?: string; // deliver/bring：对象角色名
  locationName?: string; // visit：地点名（客户端 POI 判定）
  itemId?: string; // gift：要送给委托人的贴纸 id
  message?: string; // deliver：要带的话
  rewardId: string; // 完成奖励的贴纸 id
}

/** LLM 从玩家意图产出的角色设定（落地前）。 */
export interface CharacterSpec {
  name: string;
  personality: string;
  visualDescription: string;
  voiceId: string;
  scale: number;
  abilities: string[];
}

/** 落地后的完整角色。 */
export interface Character {
  id: string;
  worldId: string;
  isFairy: boolean;
  name: string;
  personality: string;
  voiceId: string;
  appearance: { visualDescription: string; spriteAsset: string; scale: number };
  memory: string[];
  chatHistory: ChatTurn[];
  state: string;
  behaviorScript: BehaviorScript;
  position: { tileX: number; tileY: number };
  abilities: string[];
  relationships: Record<string, string>;
}

/** 造角色编排的阶段，顺序固定，用于进度推送。 */
export type GenStage = 'spec' | 'moderate_text' | 'image' | 'cutout' | 'persist';

export const GEN_STAGES: readonly GenStage[] = ['spec', 'moderate_text', 'image', 'cutout', 'persist'];

export interface CreateCharacterInput {
  worldId: string;
  intentText: string; // M1 文字驱动；M2 由讯飞 ASR 产出
  byFairy: boolean;
  position?: { tileX: number; tileY: number };
}

export interface ModerationResult {
  allowed: boolean;
  reason?: string;
}

/** 意图路由结果：闲聊还是预设能力指令。 */
export interface IntentResult {
  kind: 'chat' | 'command';
  replyText: string; // 闲聊回应 / 指令的口头确认（中文）
  behaviorScript?: BehaviorScript; // command 时
  emotion: string; // happy | think | wave | ...（图标化情绪）
  /** 指令执行者的名字：小朋友点名让「别的」角色做时才有（如对小绿说「小蓝跟我来」）。缺省=正在对话的角色。 */
  performerName?: string;
  /** LLM 在这句回应里发起了上下文给的委托候选（taskCandidate）→ 服务端把它设为进行中。 */
  offerTask?: boolean;
}

/** 意图路由的上下文（喂给 LLM）。 */
export interface IntentContext {
  characterName: string;
  personality: string;
  abilities: string[];
  recentHistory?: ChatTurn[]; // 近 N 轮对话，给角色上下文让回应连贯
  memory?: string[]; // 角色长期记忆要点（自我累积，跨对话保留）
  /** 世界里的其他角色花名册（不含自己/小神仙）：让 LLM 能把「小蓝跟我来」「去找小绿聊天」对上真实角色名。 */
  worldCharacters?: { id: string; name: string }[];
  /** 世界地点名清单（客户端 world_info 上报的 POI 名）：move_to 的 location_name 优先归一到这些名字。 */
  locations?: string[];
  /** 进行中的委托（若有）：让角色记得催/答疑，且不再发起新委托。 */
  activeTask?: ActiveTask;
  /** 可发起的委托候选（无进行中委托时服务端生成）：LLM 觉得时机合适就用自己口吻发起并置 offerTask。 */
  taskCandidate?: ActiveTask;
  /** 玩家的贴纸背包（id→数量）：give 的词汇依据；空背包时对送贴纸请求温柔说明还没有。 */
  inventory?: Record<string, number>;
}

/** 对话后让角色「自己决定记什么」的上下文（extractMemory 用）。 */
export interface MemoryExtractionContext {
  characterName: string;
  personality: string;
  transcript: string; // 小朋友这轮说的
  replyText: string; // 角色这轮的回应
  existingMemory: string[]; // 已记住的，用于去重/避免重复记
}

/** voice_input 编排的返回（推给客户端 character_response）。 */
export interface VoiceResponse {
  characterId: string;
  transcript: string;
  replyText: string;
  /** 非流式：资源 hash（/assets/:hash）。流式时为空串，完整音频 hash 由 tts_end 携带。 */
  ttsAsset: string;
  behaviorScript?: BehaviorScript;
  emotion: string;
  /** 流式 TTS：character_response 先行，音频随 tts_chunk 推送（PCM16，mime 见 ttsMime）。 */
  ttsStreaming?: boolean;
  ttsMime?: string; // 如 audio/L16;rate=24000，客户端据此设采样率
  /** behaviorScript 的执行者角色 id：小朋友点名让别的角色做时才有，缺省=characterId。 */
  performerId?: string;
  /** 这句回应里新发起的委托（LLM offerTask 且服务端已设为进行中）→ 客户端显示任务提示。 */
  task?: ActiveTask;
}
