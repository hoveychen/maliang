import type { MemoryKind, PlayerOnboardingProfile } from './types.ts';

// 系统性闲聊话题池：给对话一点「主动找话题」的种子，避免每次都说一样的话（复读机）。
//  · 村民用「了解型」——开放问题，既能闲聊又能借机问出小朋友的喜好；问到的答案会在会话结束被
//    flushMemory 抽成该村民私有的 preference 记忆，下次就记得（这就是「靠交朋友积累了解」）。
//  · 点点用「已知型」——她先天知道喜好，话题基于已知喜好往深里聊。
// 都排除「已经聊过的」（记忆里已提到该 key），并随关系推进轮换，让不同次见面话题错开。

/** 一个话题种子：key 用来和已有记忆做「聊过没」粗匹配，text 是给 LLM 的话题提示。 */
interface TopicSeed {
  key: string;
  text: string;
}

// 了解型（村民）：开放且能引出喜好的小问题，3–6 岁口吻。
const DISCOVERY_TOPICS: TopicSeed[] = [
  { key: '名字', text: '还不知道TA叫什么，可以问问TA的名字' },
  { key: '动物', text: '问问TA最喜欢什么小动物' },
  { key: '颜色', text: '问问TA最喜欢什么颜色' },
  { key: '玩', text: '问问TA平时最喜欢玩什么' },
  { key: '吃', text: '问问TA最喜欢吃什么东西' },
  { key: '开心', text: '问问TA今天有没有遇到开心的事' },
];

// 已知型（点点）：基于 profile 已知喜好参数化；无 profile 时为空，pickChatTopics 会回落到了解型。
function familiarTopics(profile: PlayerOnboardingProfile | undefined): TopicSeed[] {
  const seeds: TopicSeed[] = [];
  for (const m of (profile?.attrs?.motifs ?? []).slice(0, 3)) {
    seeds.push({ key: m, text: `TA喜欢${m}，可以聊聊${m}的事` });
  }
  const color = profile?.attrs?.color;
  if (color) seeds.push({ key: color, text: `TA喜欢${color}，可以一起找找周围${color}的东西` });
  return seeds;
}

/**
 * 挑本轮可提的闲聊话题（返回 1–2 个话题提示；无则空数组）。
 * 村民→了解型、点点→已知型（无 profile 回落了解型）；排除记忆里已聊过的；随记忆条数轮换起点。
 * 纯函数，可单测。刻意做小：常量 + 关键词去重 + 轮换，不引状态机、不引 LLM。
 */
export function pickChatTopics(opts: {
  isFairy: boolean;
  profile: PlayerOnboardingProfile | undefined;
  memory: { text: string; kind: MemoryKind }[];
}): string[] {
  const primary = opts.isFairy ? familiarTopics(opts.profile) : DISCOVERY_TOPICS;
  const pool = primary.length > 0 ? primary : DISCOVERY_TOPICS; // 点点没 profile 时也有话聊
  const memText = opts.memory.map((m) => m.text).join('\n');
  // 排除已经聊过的（记忆里已提到该 key）：问过就记得，不再重复问。全聊过了回落整池。
  const fresh = pool.filter((t) => !memText.includes(t.key));
  const use = fresh.length > 0 ? fresh : pool;
  // 随记忆条数轮换起点，让不同次见面的话题错开（确定性，可单测）。
  const offset = opts.memory.length % use.length;
  const rotated = [...use.slice(offset), ...use.slice(0, offset)];
  return rotated.slice(0, 2).map((t) => t.text);
}
