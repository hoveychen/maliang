// 村民主动社交的派生逻辑（见 docs/villager-social-design.md）。
//
// 两个概念，都不落新字段、不进 LLM：
//  - 性格类型 socialType：从既有招呼风格 greetingStyle 派生。外向(warm/playful)主动迎【陌生人】，
//    内向(shy/gentle)只主动迎【熟人】。缺省风格由 greetings.styleForCharacter 按 id 稳定哈希兜底。
//  - 熟识度 familiarity：相对【某个玩家】，读该村民 Character.relationships[playerId] 的累计互动派生。
//    「实质互动才算熟」——完成过它的心愿=朋友，聊过=点头之交，只挥过手/被送过花不升级。
//
// 这两个字段本身不持久化：socialType 恒可从 greetingStyle 现算；familiarity 从 relationships 现算。
// 下发时经 server.projectCharacterFor 附加到 Character 上，供客户端判定谁该主动迎上来。

import type { Character, Familiarity, RelationshipState, SocialType } from './types.ts';
import { styleForCharacter, type GreetingStyle } from './greetings.ts';

const EXTROVERT_STYLES: readonly GreetingStyle[] = ['warm', 'playful'];

/** 性格类型：外向(warm/playful) vs 内向(shy/gentle)。派生自招呼风格，零新字段。 */
export function deriveSocialType(c: { id: string; greetingStyle?: string }): SocialType {
  return EXTROVERT_STYLES.includes(styleForCharacter(c)) ? 'extrovert' : 'introvert';
}

/** 一段全新的关系（没有任何实质互动）。 */
export function freshRelationship(): RelationshipState {
  return { chats: 0, wishesDone: 0, gifted: false, lastSeen: 0 };
}

/**
 * 容错读取 relationships[playerId]：老档是 `{}`、历史 string 值或缺失，一律归一成合法 RelationshipState。
 * relationships 曾是死字段（只初始化为 `{}`、无人读写），故运行时几乎只可能是空——但仍防御老 JSON 形状。
 */
export function coerceRelationship(raw: unknown): RelationshipState {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    const r = raw as Partial<RelationshipState>;
    return {
      chats: Math.max(0, Math.floor(Number(r.chats) || 0)),
      wishesDone: Math.max(0, Math.floor(Number(r.wishesDone) || 0)),
      gifted: r.gifted === true,
      lastSeen: Math.max(0, Math.floor(Number(r.lastSeen) || 0)),
    };
  }
  return freshRelationship();
}

/** 实质互动才算熟：完成过它的心愿→朋友；聊过→点头之交；否则陌生。 */
export function deriveFamiliarity(rel: unknown): Familiarity {
  const r = coerceRelationship(rel);
  if (r.wishesDone > 0) return 'friend';
  if (r.chats > 0) return 'acquaintance';
  return 'stranger';
}

/** 某玩家眼中这个村民的熟识度（读村民视角持久化的 relationships）。 */
export function familiarityFor(c: Character, playerId: string): Familiarity {
  return deriveFamiliarity(c.relationships?.[playerId]);
}
