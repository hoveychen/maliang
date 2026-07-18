// 角色专属委托链（M1 断环修复，docs/m1-wish-supply-design.md §2.1）：新角色的「见面礼」。
// 链只带「语义与话术」（漏话/请求/道谢），围绕同一个小主题递进（如面包师：想认识邻居→想要烤炉→请大家吃面包）；
// deliver/bring/visit 的目标由 pickTaskCandidate 发起当刻现选，完成判定全走现有确定性路径。
//
// 生成：LLM 按人设出 3-5 步（designTaskChain）→ validateChainSteps 把关 →
// 失败/超时/产物不合格一律回退【确定性模板链】（按 greetingStyle 选主题）——绝不让角色无链，
// 这是零挫败纪律在供给侧的体现。链走完即止（不循环）：角色回落通用池，链是见面礼不是永动机。

import type { ChainStep, Character, TaskChain, TaskType } from './types.ts';
import type { LLMAdapter } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import { styleForCharacter, type GreetingStyle } from './greetings.ts';
import { WISHES } from './wishes.ts';

export const CHAIN_MIN_STEPS = 3;
export const CHAIN_MAX_STEPS = 5;

/**
 * 确定性模板回退链：每种招呼风格一套主题（热情→办小茶会 / 害羞→悄悄交朋友 /
 * 俏皮→张罗游戏 / 温和→惦记风景），与角色既有性格口径一致。
 * 漏话全部过自言自语纪律（validateChainSteps 的同一把尺子，有单测互证）。
 */
export const TEMPLATE_CHAINS: Record<GreetingStyle, readonly ChainStep[]> = {
  warm: [
    {
      type: 'visit',
      leak: '我想在村里办一场小茶会…可是在哪儿办好呢？得先找个好地方。',
      ask: '我想办一场小茶会！请你帮我去那个地方看一看，合不合适呀？',
      thanks: '你真的去看过啦！就在那儿办茶会！',
    },
    {
      type: 'deliver',
      message: '茶会就要开始啦，请来玩呀',
      leak: '茶会的事儿只有我自己知道…真想让大家也知道呀。',
      ask: '茶会的消息还没人知道呢，请你帮我把这句话带给他好不好？',
      thanks: '太好啦，消息带到啦！茶会又热闹一分！',
    },
    {
      type: 'wish',
      wishAbility: 'create_prop',
      desire: '一张摆点心的小桌子',
      leak: '点心做好了却没地方摆…要是有张小桌子就好啦。',
      ask: '茶会还缺一张摆点心的小桌子…我自己变不出来，只有小仙子的魔法才行呀。',
      thanks: '哇，小桌子有啦！茶会马上就能开啦，谢谢你！',
    },
    {
      type: 'bring',
      leak: '茶会都快开始啦…人还没到齐呢。',
      ask: '茶会要开始啦，请你把他带到我身边来好不好？',
      thanks: '人到齐啦！这是最棒的一场茶会！',
    },
  ],
  shy: [
    {
      type: 'deliver',
      message: '那个…我一直想跟你做朋友…',
      leak: '有句话…我一直没敢当面说出口…',
      ask: '我…我想跟他说句话，可我不好意思…你能帮我带给他吗？',
      thanks: '你帮我说啦…谢谢你…我心里暖暖的。',
    },
    {
      type: 'wish',
      wishAbility: 'create_sticker',
      desire: '一枚亮晶晶的小星星贴纸',
      leak: '要是身上有颗亮晶晶的小星星…我说话就有勇气啦。',
      ask: '我想要一枚小星星贴纸壮壮胆…可我自己做不出来，得靠小仙子的魔法。',
      thanks: '亮晶晶的…我感觉勇敢多啦！',
    },
    {
      type: 'bring',
      leak: '我想跟他玩…可我不敢自己走过去…',
      ask: '你能…把他带到我身边来吗？有你在我就不怕啦。',
      thanks: '我们…我们成为朋友啦！都是你的功劳…',
    },
  ],
  playful: [
    {
      type: 'visit',
      leak: '嘿嘿，我想找块又大又平的地方撒欢儿…哪儿有呢？',
      ask: '我想找个撒欢儿的好地方！你帮我去那儿看看好不好？',
      thanks: '哈哈，你去过啦？那儿听起来就好玩！',
    },
    {
      type: 'bring',
      leak: '一个人玩没意思…人越多越好玩呀。',
      ask: '玩游戏人越多越热闹！把他也叫来嘛！',
      thanks: '嘿嘿，人齐啦！马上开玩！',
    },
    {
      type: 'wish',
      wishAbility: 'play_game',
      desire: '来一局大家一起玩的游戏',
      leak: '场地有了伙伴也有了…就差开一局热热闹闹的游戏啦！',
      ask: '万事俱备！就差一局游戏啦，一起来玩嘛！',
      thanks: '刚才太好玩啦！下次还要一起玩哦！',
    },
  ],
  gentle: [
    {
      type: 'wish',
      wishAbility: 'guide_to',
      desire: '去远处那个好地方看一看',
      leak: '听说远处有个很美的地方…我一个人可走不到呢。',
      ask: '我一直惦记着远处那个好地方…要是小仙子肯带路，一起去看看就好了。',
      thanks: '我们真的到啦…风景真好，谢谢你陪我。',
    },
    {
      type: 'deliver',
      message: '远处有个特别美的地方，风景可好啦',
      leak: '这么好的风景，光我一个人知道有点可惜呀。',
      ask: '这么美的事儿，请你帮我讲给他听好不好？',
      thanks: '你帮我把美景讲给别人听啦，真好。',
    },
    {
      type: 'visit',
      leak: '村子里还有个安静的角落…我也一直想去坐坐。',
      ask: '还有个安静的小角落，请你替我去看一看它还好吗？',
      thanks: '它还好好的呀，那我就放心啦。',
    },
  ],
};

/** 按角色的招呼风格（缺省 id 稳定哈希，同 greetings.ts）选一套模板链。返回深拷贝，别脏共享模板。 */
export function templateChainFor(c: { id: string; greetingStyle?: string }): ChainStep[] {
  return structuredClone(TEMPLATE_CHAINS[styleForCharacter(c)]) as ChainStep[];
}

const TASK_TYPES: readonly TaskType[] = ['deliver', 'bring', 'visit', 'wish'];
/** 漏话自言自语纪律（同 wishes.ts 头注）：出现对着小朋友说话的词就是广告，整链拒绝。 */
const LEAK_AD_WORDS = /你可以|要不要|告诉我/;

function cleanText(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

/**
 * LLM 产物把关：形状、步数（不足 3 拒绝，超 5 裁到 5）、type 合法、话术齐全、
 * wish 步必须带心愿库里真实存在的 wishAbility、漏话过自言自语纪律。
 * 任一步不合格 → 整链返回 null（调用方回退模板）：人设连续性是链的价值，缺步的链不如整套模板。
 */
export function validateChainSteps(raw: unknown): ChainStep[] | null {
  if (!Array.isArray(raw)) return null;
  const steps: ChainStep[] = [];
  for (const r of raw.slice(0, CHAIN_MAX_STEPS)) {
    if (!r || typeof r !== 'object') return null;
    const s = r as Record<string, unknown>;
    if (typeof s.type !== 'string' || !TASK_TYPES.includes(s.type as TaskType)) return null;
    const leak = cleanText(s.leak);
    const ask = cleanText(s.ask);
    const thanks = cleanText(s.thanks);
    if (!leak || !ask || !thanks) return null;
    if (LEAK_AD_WORDS.test(leak)) return null;
    const step: ChainStep = { type: s.type as TaskType, leak, ask, thanks };
    if (step.type === 'wish') {
      const ability = cleanText(s.wishAbility);
      if (!(ability in WISHES)) return null;
      step.wishAbility = ability;
      const desire = cleanText(s.desire);
      if (desire) step.desire = desire;
    }
    if (step.type === 'deliver') {
      const message = cleanText(s.message);
      if (message) step.message = message; // 可选：不带则物化时回落通用 DELIVER_MESSAGES 池
    }
    steps.push(step);
  }
  return steps.length >= CHAIN_MIN_STEPS ? steps : null;
}

/** 生成中的角色去重：同一角色并发要链时只生成一次（fire-and-forget 与懒生成可能撞车）。 */
const inflight = new Map<string, Promise<TaskChain | null>>();

/**
 * 确保角色有委托链（懒生成，幂等）：
 *  - 已有链（包括走完的）→ 原样返回，绝不重生成——链走完即止，角色回落通用池；
 *  - 无链 → LLM 生成 + 校验，失败回退模板链，落库后返回。
 * 仙子/角色不存在 → null（她是兑现心愿的人，不是许愿的人）。本函数不抛。
 */
export async function ensureTaskChain(
  worldId: string,
  npcId: string,
  llm: LLMAdapter,
  store: WorldStore,
): Promise<TaskChain | null> {
  const c = store.getCharacter(worldId, npcId);
  if (!c || c.isFairy) return null;
  if (c.taskChain) return c.taskChain;
  const key = `${worldId}:${npcId}`;
  const pending = inflight.get(key);
  if (pending) return pending;
  const p = generateChain(worldId, npcId, c, llm, store);
  inflight.set(key, p);
  try {
    return await p;
  } finally {
    inflight.delete(key);
  }
}

/**
 * 该村民下一个「待发」的链步（漏话/A4 清单用）：从游标起找，买不起的 wish 步跳过
 * （costsFlower 口径同 pickChainTask——被勾起兴趣却造不起是挫败）。
 * 刻意不做场景目标可行性判断：deliver 没对象也可以想念这件事，那是物化（发起）时的事。
 * 链尽/无链 → null。
 */
export function pendingChainStep(chain: TaskChain | undefined, canAfford: boolean): ChainStep | null {
  if (!chain) return null;
  for (let i = chain.nextIndex; i < chain.steps.length; i++) {
    const step = chain.steps[i]!;
    if (step.type === 'wish' && WISHES[step.wishAbility ?? '']?.costsFlower && !canAfford) continue;
    return step;
  }
  return null;
}

/**
 * 完成结算推进链游标（供 tasks.ts 三个结算点调用）：完成第 chainIndex 步 → nextIndex = chainIndex+1。
 * 游标是「跳步不回头」语义：物化时若跳过了不可行步（买不起/场景没目标），完成后面的步就把游标
 * 一并越过它们——链是「见面礼」不是任务清单，供给持续比步步全勤重要（docs/m1-wish-supply-design.md §2.2）。
 * 非链步（无 chainNpcId/chainIndex）no-op。
 */
export function advanceChainOnComplete(
  worldId: string,
  task: { chainNpcId?: string; chainIndex?: number },
  store: WorldStore,
): void {
  if (!task.chainNpcId || task.chainIndex === undefined) return;
  const c = store.getCharacter(worldId, task.chainNpcId);
  if (!c?.taskChain) return;
  if (task.chainIndex >= c.taskChain.nextIndex) {
    c.taskChain.nextIndex = task.chainIndex + 1;
    store.saveCharacter(c);
  }
}

async function generateChain(
  worldId: string,
  npcId: string,
  c: Character,
  llm: LLMAdapter,
  store: WorldStore,
): Promise<TaskChain | null> {
  let steps: ChainStep[] | null = null;
  try {
    steps = validateChainSteps(await llm.designTaskChain({ name: c.name, personality: c.personality }));
  } catch {
    steps = null; // LLM 挂了/超时：走模板回退，不打断任何上层流程
  }
  if (!steps) steps = templateChainFor(c);
  // LLM 期间角色可能被并发改写（位置上报等）：重读再写，缩小覆盖窗口
  const fresh = store.getCharacter(worldId, npcId) ?? c;
  if (fresh.taskChain) return fresh.taskChain;
  fresh.taskChain = { steps, nextIndex: 0 };
  store.saveCharacter(fresh);
  return fresh.taskChain;
}
