// NPC 委托模板池与完成判定。
// 委托由服务端确定性生成（目标/判定条件都定死），LLM 只负责用角色口吻把请求说出来
// （见 openrouter_llm.routeIntent 的 offerTask）；完成判定是客户端上报的确定性事件，不靠 LLM 猜。
// 完成任一委托 = 盖 1 个集邮章；每满 3 章换 1 朵小红花（见 docs/reward-flower-design.md）。
import { randomUUID } from 'node:crypto';
import { MAX_FLOWERS, STAMPS_PER_FLOWER, STAMP_STYLES, type ActiveTask, type TaskType, type Wallet } from './types.ts';
import type { WorldStore } from './persistence.ts';

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
  const others = store.listCharacters(worldId, sceneId).filter((c) => c.id !== npcId && !c.isFairy);
  const locations = store.getLocations(worldId, sceneId);
  const types: TaskType[] = [];
  if (others.length > 0) types.push('deliver', 'bring');
  if (locations.length > 0) types.push('visit');
  if (types.length === 0) return null;
  const type = pick(types, rand);
  const base = {
    id: randomUUID(),
    type,
    npcId,
    npcName: npc.name,
    stampStyle: pick(STAMP_STYLES, rand),
  };
  switch (type) {
    case 'deliver':
      return { ...base, targetName: pick(others, rand).name, message: pick(DELIVER_MESSAGES, rand) };
    case 'bring':
      return { ...base, targetName: pick(others, rand).name };
    case 'visit':
      return { ...base, locationName: pick(locations, rand) };
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
  }
}

/** 完成时委托类型对应的表扬前缀。 */
function taskIntro(task: ActiveTask): string {
  switch (task.type) {
    case 'deliver':
      return '太棒啦！话带到了！';
    case 'bring':
      return `谢谢你把${task.targetName}带来啦！`;
    case 'visit':
      return `你真的去过${task.locationName}啦！`;
  }
}

/**
 * 完成委托时委托人的口头表扬（TTS 用，纯中文不含 emoji）。
 * 升花时报喜；未升花时按当前进度说还差几个盖章；花已满则夸满仓。
 */
export function praiseLine(task: ActiveTask, result: { flowerGained: boolean; wallet: Wallet }): string {
  const intro = taskIntro(task);
  if (result.flowerGained) {
    return `${intro}集满三个盖章，换到一朵小红花啦！`;
  }
  if (result.wallet.flowers >= MAX_FLOWERS) {
    return `${intro}这个盖章送给你！你的小红花已经满满的啦，真厉害！`;
  }
  const remain = STAMPS_PER_FLOWER - result.wallet.stampProgress;
  return `${intro}这个盖章送给你！再帮${remain}个小伙伴，就能换一朵小红花啦！`;
}

/** 小红花用完时的仙子引导语（造物/造角色被拦时说）。 */
export function flowerDeniedLine(): string {
  return '你的小红花用完啦！去帮小伙伴完成心愿，集满盖章换到小红花，就能再造一个新朋友或新玩具啦！';
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
  return { task, flowerGained, wallet };
}
