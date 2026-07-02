// maliang 后端核心类型与造角色协议。客户端是 GDScript，不共享代码，
// 但 WS/REST 协议字段以本文件为准（见 docs/tech-design.md §5.1、§6）。

export interface ChatTurn {
  role: 'child' | 'npc';
  text: string;
  ts: number;
}

export interface BehaviorCommand {
  type: string; // move_to | wander | wait | say | emote | face | deliver_message | create_character
  params: Record<string, unknown>;
}

export interface BehaviorScript {
  commands: BehaviorCommand[];
  loop: boolean;
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
}

/** 意图路由的上下文（喂给 LLM）。 */
export interface IntentContext {
  characterName: string;
  personality: string;
  abilities: string[];
  recentHistory?: ChatTurn[]; // 近 N 轮对话，给角色上下文让回应连贯
  memory?: string[]; // 角色长期记忆要点（自我累积，跨对话保留）
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
}
