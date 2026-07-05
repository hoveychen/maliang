// NPC 委托模板池与完成判定。
// 委托由服务端确定性生成（目标/奖励/判定条件都定死），LLM 只负责用角色口吻把请求说出来
// （见 openrouter_llm.routeIntent 的 offerTask）；完成判定是客户端上报的确定性事件，不靠 LLM 猜。
import { randomUUID } from 'node:crypto';
import { STICKERS, type ActiveTask, type TaskType } from './types.ts';
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
 * （没有其他村民就没有带话/带人，没有地点就没有探访，没有贴纸就没有送礼）。
 */
export function pickTaskCandidate(
  worldId: string,
  npcId: string,
  store: WorldStore,
  rand: () => number = Math.random,
): ActiveTask | null {
  if (store.getActiveTask(worldId)) return null;
  const npc = store.getCharacter(worldId, npcId);
  if (!npc || npc.isFairy) return null;
  const others = store.listCharacters(worldId).filter((c) => c.id !== npcId && !c.isFairy);
  const locations = store.getLocations(worldId);
  const inventory = store.getInventory(worldId);
  const stickers = Object.keys(inventory).filter((k) => (inventory[k] ?? 0) > 0);
  const types: TaskType[] = [];
  if (others.length > 0) types.push('deliver', 'bring');
  if (locations.length > 0) types.push('visit');
  if (stickers.length > 0) types.push('gift');
  if (types.length === 0) return null;
  const type = pick(types, rand);
  const base = {
    id: randomUUID(),
    type,
    npcId,
    npcName: npc.name,
    rewardId: pick(STICKERS, rand).id,
  };
  switch (type) {
    case 'deliver':
      return { ...base, targetName: pick(others, rand).name, message: pick(DELIVER_MESSAGES, rand) };
    case 'bring':
      return { ...base, targetName: pick(others, rand).name };
    case 'visit':
      return { ...base, locationName: pick(locations, rand) };
    case 'gift':
      return { ...base, itemId: pick(stickers, rand) };
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
    case 'gift':
      return `请小朋友送你一个贴纸(${task.itemId})`;
  }
}

/** 客户端上报的完成事件。 */
export interface TaskEvent {
  kind: string; // deliver_done | bring_done | visit_done | gift_done
  targetName?: string;
  locationName?: string;
  npcId?: string;
  itemId?: string;
}

/** 名字匹配：精确 > 互相包含（ASR 多字/少字）。 */
function sameName(got: string | undefined, want: string | undefined): boolean {
  if (!got || !want) return false;
  const g = got.trim();
  return g === want || g.includes(want) || want.includes(g);
}

/**
 * 事件与进行中委托匹配则完成：发奖励贴纸+清委托，返回完成的委托；不匹配返回 null 不动状态。
 */
export function completeTaskOnEvent(worldId: string, event: TaskEvent, store: WorldStore): ActiveTask | null {
  const task = store.getActiveTask(worldId);
  if (!task) return null;
  const ok =
    (task.type === 'deliver' && event.kind === 'deliver_done' && sameName(event.targetName, task.targetName)) ||
    (task.type === 'bring' && event.kind === 'bring_done' && sameName(event.targetName, task.targetName)) ||
    (task.type === 'visit' && event.kind === 'visit_done' && sameName(event.locationName, task.locationName)) ||
    (task.type === 'gift' && event.kind === 'gift_done' && event.npcId === task.npcId && event.itemId === task.itemId);
  if (!ok) return null;
  store.addSticker(worldId, task.rewardId);
  store.setActiveTask(worldId, null);
  return task;
}
