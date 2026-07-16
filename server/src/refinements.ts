// 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md）：造物类心愿在「造出来」和「盖章」之间插一拍——
// 村民走过去用它、发现「还差一点」，小朋友调一个维度（当前是体型 size），村民才满意盖章。
//
// 抱怨词库是静态的、按方向分组、确定性挑（形状照抄 wishes.ts 的 leaks）：零 LLM 成本、可单测、可预制 TTS。
// 「差一点」永远只指向一条纯标量轴（size），且方向按造出来的档反推 → 目标档一定存在、一定够得到（§3.1/§3.2）。

import type { CreatureSize } from './creation_options.ts';

/** 调整次数上限：到顶无论调成什么都盖章——终止性写死在数据里，绝不无止境挑刺（§3.2）。 */
export const REFINE_MAX_TRIES = 2;

/** 仙子问句（客户端预制 WAV 的 key，见 assets/voice/fairy/lines.json）——她只问不给答案（§3.3）。 */
export const REFINE_HINT = 'refine_hint';       // 第一次：把注意力引到那根轴上
export const REFINE_HINT_2 = 'refine_hint_2';   // 卡住/调反后升一级：更具体但仍是问句

/**
 * 抱怨词库：按调整方向分组。村民用自己音色漏出来（走道谢同一条 TTS 通道）。
 * smaller = 造出来偏大，抱怨「太大/太高/够不着」（能变小）；bigger = 造出来偏小，抱怨「太小/看不见」（能变大）。
 */
export const COMPLAINTS: Record<'smaller' | 'bigger', readonly string[]> = {
  smaller: [
    '这个…好像有点太大啦，我都够不着呢…',
    '哎呀，它太高啦，我搬不动呀…',
    '这么大一个…放哪儿都嫌挤呢。',
  ],
  bigger: [
    '这个…是不是有点太小啦？我都快看不见它啦。',
    '哎呀，它太小啦，我用不上呀…',
    '这么小小的一个…要是能大一点点就好啦。',
  ],
};

/**
 * 造出来的档 → 抱怨方向：small → bigger（能变大），big/medium → smaller（能变小）。
 * 关键：方向按造出来的档反推，保证目标档一定存在、一定够得到——绝不抱怨一个够不到的方向（§3.2）。
 */
export function refineDirFor(size: CreatureSize): 'smaller' | 'bigger' {
  return size === 'small' ? 'bigger' : 'smaller';
}

/** 按方向确定性挑一句抱怨（默认 Math.random，测试可注入 rng）。 */
export function pickComplaint(dir: 'smaller' | 'bigger', rng: () => number = Math.random): string {
  const pool = COMPLAINTS[dir];
  return pool[Math.floor(rng() * pool.length)] ?? pool[0]!;
}
