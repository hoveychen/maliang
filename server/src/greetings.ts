// 进对话时对方先开口的招呼词库。按「招呼风格」分组，每组一批儿童向短句，随机选一条。
// 不同角色分到不同风格（创建时可显式设 greetingStyle；缺省按角色 id 稳定哈希落到一种），
// 从而「不同角色打招呼方式不一样」。招呼词经各角色自己的 voiceId 走流式 TTS 出声（见 voice.ts greetCharacter）。

export type GreetingStyle = 'warm' | 'shy' | 'playful' | 'gentle';

/** 招呼风格 → 一组招呼词（儿童向、短、口语）。随机选一条。 */
export const GREETING_STYLES: Record<GreetingStyle, string[]> = {
  warm: [
    '嗨！你来啦，我好开心呀！',
    '你好呀！快过来一起玩吧！',
    '哇，是你！我正想你呢！',
    '欢迎欢迎！今天想玩点什么呀？',
  ],
  shy: [
    '啊……你好呀……',
    '嗯……你来了呀……',
    '你、你好……很高兴见到你……',
    '悄悄跟你说声……你好呀……',
  ],
  playful: [
    '嘿嘿，被你抓到啦！',
    '哟，是你呀！猜猜我在想什么？',
    '嘻嘻，来跟我玩个游戏好不好？',
    '你来啦你来啦！我藏了个小秘密哦！',
  ],
  gentle: [
    '你好呀，慢慢来，不着急。',
    '很高兴见到你，小朋友。',
    '你来啦，坐下歇会儿吧。',
    '今天也要开开心心的哦。',
  ],
};

const STYLES = Object.keys(GREETING_STYLES) as GreetingStyle[];

/** 角色 id → 稳定风格（同一 id 每次结果一致）。用于未显式设 greetingStyle 时的兜底。 */
export function styleForCharacter(c: { id: string; greetingStyle?: string }): GreetingStyle {
  if (c.greetingStyle && c.greetingStyle in GREETING_STYLES) return c.greetingStyle as GreetingStyle;
  let h = 0;
  for (let i = 0; i < c.id.length; i++) h = (h * 31 + c.id.charCodeAt(i)) >>> 0;
  return STYLES[h % STYLES.length];
}

/** 按角色风格随机选一条招呼词。rng 可注入以便测试确定性。 */
export function pickGreeting(c: { id: string; greetingStyle?: string }, rng: () => number = Math.random): string {
  const pool = GREETING_STYLES[styleForCharacter(c)];
  return pool[Math.floor(rng() * pool.length)];
}
