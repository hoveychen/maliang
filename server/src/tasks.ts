// NPC 委托模板池与完成判定。
// 委托由服务端确定性生成（目标/判定条件都定死），LLM 只负责用角色口吻把请求说出来
// （见 openrouter_llm.routeIntent 的 offerTask）；完成判定是客户端上报的确定性事件，不靠 LLM 猜。
// 完成任一委托 = 盖 1 个集邮章；每满 3 章换 1 朵小红花（见 docs/reward-flower-design.md）。
import { randomUUID } from 'node:crypto';
import { MAX_FLOWERS, STAMPS_PER_FLOWER, STAMP_STYLES, type ActiveTask, type TaskType, type Wallet } from './types.ts';
import type { WorldStore } from './persistence.ts';
import { wishFor, pickThanks, WISHES } from './wishes.ts';
import { sizeToScale, type CreatureSize } from './creation_options.ts';
import { REFINE_MAX_TRIES, refineDirFor } from './refinements.ts';

/** deliver 委托的带话内容池（判定不依赖文本，纯演出）。 */
const DELIVER_MESSAGES = [
  '今天的天气真好呀',
  '一起来广场玩吧',
  '晚上一起看星星哦',
  '我这儿有好吃的，快来呀',
];

function pick<T>(arr: readonly T[], rand: () => number): T {
  return arr[Math.floor(rand() * arr.length)]!;
}

/**
 * 生成一个可发起的委托候选：无进行中委托、按世界现状挑可行类型
 * （没有其他村民就没有带话/带人，没有地点就没有探访）。完成奖励统一是盖 1 章（stampStyle 纯演出）。
 * sceneId 给了就只在该场景内挑目标角色/地点——委托不再跨场景指人指地（消化「委托指向别场景」的边界）。
 */
export function pickTaskCandidate(
  worldId: string,
  npcId: string,
  playerId: string,
  store: WorldStore,
  rand: () => number = Math.random,
  sceneId?: string,
): ActiveTask | null {
  if (store.getActiveTask(worldId, playerId)) return null;
  const npc = store.getCharacter(worldId, npcId);
  if (!npc || npc.isFairy) return null;
  const base = {
    id: randomUUID(),
    npcId,
    npcName: npc.name,
    stampStyle: pick(STAMP_STYLES, rand),
  };

  // 心愿优先：这个村民刚才可能就在旁边漏过这句话，小朋友凑上来问的正是它——
  // 此刻塞一个「带话给小蓝」的跑腿委托是驴唇不对马嘴。
  // 心愿池空（玩法全发现）或买不起（没花了，见 WishDef.costsFlower）时回落跑腿委托，
  // 后者正是赚小红花的路子——这条回落线扛着新手期的死锁。
  const canAfford = store.getWallet(worldId, playerId).flowers > 0;
  const wish = wishFor(npcId, store.getDiscovered(worldId, playerId), canAfford);
  if (wish) return { ...base, type: 'wish', wishAbility: wish.ability };

  const others = store.listCharacters(worldId, sceneId).filter((c) => c.id !== npcId && !c.isFairy);
  const locations = store.getLocations(worldId, sceneId);
  const types: TaskType[] = [];
  if (others.length > 0) types.push('deliver', 'bring');
  if (locations.length > 0) types.push('visit');
  if (types.length === 0) return null;
  const type = pick(types, rand);
  switch (type) {
    case 'deliver':
      return { ...base, type, targetName: pick(others, rand).name, message: pick(DELIVER_MESSAGES, rand) };
    case 'bring':
      return { ...base, type, targetName: pick(others, rand).name };
    case 'visit':
      return { ...base, type, locationName: pick(locations, rand) };
    default:
      return null; // 'wish' 已在上面早返回；这里只是让 switch 对 TaskType 穷尽
  }
}

/** 委托给意图 LLM 的一句话描述（prompt 用）。 */
export function describeTask(task: ActiveTask): string {
  switch (task.type) {
    case 'deliver':
      return `请小朋友把一句话带给${task.targetName}：「${task.message}」`;
    case 'bring':
      return `请小朋友把${task.targetName}带到你身边来`;
    case 'visit':
      return `请小朋友去「${task.locationName}」看一看`;
    case 'wish':
      // 心愿的兑现人是小仙子（村民不会魔法）。这句会注入【所有】角色的 prompt——
      // 包括始终跟在小朋友身边飞的小仙子，她据此知道要造什么，哪怕小朋友只说「帮帮他」。
      return `${task.npcName}心里的一个念想还没实现（${WISHES[task.wishAbility ?? '']?.context ?? ''}）——` +
        `${task.npcName}自己变不出来，只有小仙子的魔法才能帮它实现`;
  }
}

/** 完成时委托类型对应的表扬前缀。 */
function taskIntro(task: ActiveTask, rand: () => number = Math.random): string {
  switch (task.type) {
    case 'deliver':
      return '太棒啦！话带到了！';
    case 'bring':
      return `谢谢你把${task.targetName}带来啦！`;
    case 'visit':
      return `你真的去过${task.locationName}啦！`;
    case 'wish': {
      const wish = WISHES[task.wishAbility ?? ''];
      return wish ? pickThanks(wish, rand) : '谢谢你呀！';
    }
  }
}

/**
 * 完成委托时委托人的口头表扬（TTS 用，纯中文不含 emoji）。
 * 升花时报喜；未升花时按当前进度说还差几个盖章；花已满则夸满仓。
 */
export function praiseLine(
  task: ActiveTask,
  result: { flowerGained: boolean; wallet: Wallet },
  rand: () => number = Math.random,
): string {
  const intro = taskIntro(task, rand);
  if (result.flowerGained) {
    return `${intro}集满三个盖章，换到一朵小红花啦！`;
  }
  if (result.wallet.flowers >= MAX_FLOWERS) {
    return `${intro}这个盖章送给你！你的小红花已经满满的啦，真厉害！`;
  }
  const remain = STAMPS_PER_FLOWER - result.wallet.stampProgress;
  return `${intro}这个盖章送给你！再帮${remain}个小伙伴，就能换一朵小红花啦！`;
}

/**
 * 心愿达成：某个玩法【成功】了（造出物件/造出伙伴/开了一局游戏…），若进行中的委托正是盼着它的心愿，
 * 就盖 1 章 + 清委托，返回完成的委托——调用方据此让【委托的那个村民】用自己的音色道谢（pushPraiseTts）。
 *
 * 与 completeTaskOnEvent 的区别：跑腿委托的完成由客户端上报事件判定（服务端看不见小朋友走没走到），
 * 心愿的完成服务端自己就在现场——造物成功的那行代码就是判定点，不需要也不该信客户端。
 *
 * ability 不匹配（盼着树、结果造了个贴纸）则返回 null，委托原样留着：
 * 心愿没实现就是没实现，不能拿别的东西糊弄过去。
 */
export function completeWishOnAbility(
  worldId: string,
  playerId: string,
  ability: string,
  store: WorldStore,
): { task: ActiveTask; flowerGained: boolean; wallet: Wallet } | null {
  const task = store.getActiveTask(worldId, playerId);
  if (!task || task.type !== 'wish' || task.wishAbility !== ability) return null;
  const { flowerGained, wallet } = store.addStamp(worldId, playerId);
  store.setActiveTask(worldId, playerId, null);
  // 帮它了却心愿 = 一次实质互动，升熟识度（→朋友），供内向村民日后主动来打招呼。
  store.recordVillagerBond(worldId, task.npcId, playerId, 'wish');
  return { task, flowerGained, wallet };
}

/**
 * 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §4.1）：造物类心愿造成功后开一次「试用」——
 * 不当场盖章，而是标记 tried + 按造出来的档定调整方向 + 记造出来那件东西的引用。返回抱怨方向，
 * 调用方据此挑抱怨句、让【委托的那个村民】用自己音色漏出「还差一点」，仙子接一句问句。
 *
 * 只对进行中且盼着这个能力的 wish（且还在 pending）生效；不匹配返回 null（调用方回落一段完成）。
 * completeWishOnAbility 保留给不带试用轴的能力（play_game/guide_to 无体型可调，仍一段完成）。
 */
export function beginWishTrial(
  worldId: string,
  playerId: string,
  ability: string,
  itemRef: string,
  createdSize: CreatureSize,
  store: WorldStore,
): { task: ActiveTask; dir: 'smaller' | 'bigger' } | null {
  const task = store.getActiveTask(worldId, playerId);
  if (!task || task.type !== 'wish' || task.wishAbility !== ability) return null;
  if ((task.wishStage ?? 'pending') !== 'pending') return null; // 已在试用中，别重开
  const dir = refineDirFor(createdSize);
  task.wishStage = 'tried';
  task.refineItemRef = itemRef;
  task.refineDir = dir;
  task.refineFromSize = createdSize;
  task.refineTries = 0;
  store.setActiveTask(worldId, playerId, task);
  return { task, dir };
}

/**
 * 试用·还差一点（A1 §4.1）：小朋友把体型调了一次。
 *  - 方向对（往抱怨方向调了）**或** 已达调整上限 → 盖 1 章 + 清委托，返回 satisfied（走现成盖章结算）。
 *  - 方向反且未达上限 → 不动账、refineTries++，返回 retry（调用方让仙子再问一句更具体的问句）。
 * 到 REFINE_MAX_TRIES 无论调成什么都盖章——终止性写死，绝不第三次挑刺（§3.2）。
 * 只匹配 tried 且 refineItemRef 一致的委托；不匹配返回 null（不该发生，防御）。
 */
export function completeWishRefine(
  worldId: string,
  playerId: string,
  itemRef: string,
  newSize: CreatureSize,
  store: WorldStore,
):
  | { task: ActiveTask; satisfied: true; flowerGained: boolean; wallet: Wallet }
  | { task: ActiveTask; satisfied: false; tries: number }
  | null {
  const task = store.getActiveTask(worldId, playerId);
  if (!task || task.type !== 'wish' || task.wishStage !== 'tried' || task.refineItemRef !== itemRef) return null;
  const from = sizeToScale(task.refineFromSize);
  const to = sizeToScale(newSize);
  const correct = task.refineDir === 'smaller' ? to < from : to > from;
  const tries = (task.refineTries ?? 0) + 1;
  if (correct || tries >= REFINE_MAX_TRIES) {
    const { flowerGained, wallet } = store.addStamp(worldId, playerId);
    store.setActiveTask(worldId, playerId, null);
    store.recordVillagerBond(worldId, task.npcId, playerId, 'wish');
    return { task, satisfied: true, flowerGained, wallet };
  }
  task.refineTries = tries;
  store.setActiveTask(worldId, playerId, task);
  return { task, satisfied: false, tries };
}

/**
 * 小红花用完时的仙子引导语（造物/造角色被拦时说）。
 *
 * 这是没花了必须给的解释（不说，小朋友只会看见「按了没反应」），但说法要像仙子在说心里话，
 * 不是系统在播报规则——旧版「集满盖章换到小红花」是记账口吻，念给 3 岁小朋友听等于噪音。
 * 指向也换了：帮小伙伴了却一桩心事，就是现在赚花的正路（见 wishes.ts）。
 */
export function flowerDeniedLine(): string {
  return '呀…我的魔法用完啦。要是能帮小伙伴做成一件他心心念念的事，魔法就会回来的。';
}

/** 客户端上报的完成事件。 */
export interface TaskEvent {
  kind: string; // deliver_done | bring_done | visit_done
  targetName?: string;
  locationName?: string;
}

/** 名字匹配：精确 > 互相包含（ASR 多字/少字）。 */
function sameName(got: string | undefined, want: string | undefined): boolean {
  if (!got || !want) return false;
  const g = got.trim();
  return g === want || g.includes(want) || want.includes(g);
}

/**
 * 事件与进行中委托匹配则完成：盖 1 章（满 3 结算 1 花）+ 清委托，返回完成的委托与结算结果；
 * 不匹配返回 null 不动状态。
 */
export function completeTaskOnEvent(
  worldId: string,
  playerId: string,
  event: TaskEvent,
  store: WorldStore,
): { task: ActiveTask; flowerGained: boolean; wallet: Wallet } | null {
  const task = store.getActiveTask(worldId, playerId);
  if (!task) return null;
  const ok =
    (task.type === 'deliver' && event.kind === 'deliver_done' && sameName(event.targetName, task.targetName)) ||
    (task.type === 'bring' && event.kind === 'bring_done' && sameName(event.targetName, task.targetName)) ||
    (task.type === 'visit' && event.kind === 'visit_done' && sameName(event.locationName, task.locationName));
  if (!ok) return null;
  const { flowerGained, wallet } = store.addStamp(worldId, playerId);
  store.setActiveTask(worldId, playerId, null);
  // 跑腿委托完成同样加深与委托村民的熟识度。
  store.recordVillagerBond(worldId, task.npcId, playerId, 'wish');
  return { task, flowerGained, wallet };
}
