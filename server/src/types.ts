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
export type GenStage =
  | 'spec'
  | 'moderate_text'
  | 'image'
  | 'cutout'
  | 'moderate_image'
  | 'persist';

export const GEN_STAGES: readonly GenStage[] = [
  'spec',
  'moderate_text',
  'image',
  'cutout',
  'moderate_image',
  'persist',
];

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
