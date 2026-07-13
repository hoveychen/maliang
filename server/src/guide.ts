/**
 * 小仙子引路（guide_to）—— 见 docs/fairy-guide-design.md。
 *
 * 她不会走路（LOCOMOTION_ABILITIES 对 isFairy 剔除，客户端 _run_behavior 也早返回），所以引路
 * 不是行为脚本：这里把「带我去风车」「我想找小明」解析成一份 GuidePlan 下发，由客户端的引路
 * 状态机驱动她「飞到前面 → 回头等 → 孩子自己走过来」。玩家的 avatar 全程由孩子自己操控。
 *
 * P1 只做同场景（legs 恒为空）；跨场景的 portal 寻路在 P3 接进来。
 */
import type { WorldStore } from './persistence.ts';
import type { GuidePlan, GuideTarget } from './types.ts';
import { matchByName } from './names.ts';

/** guide_to 的 params 形状（LLM 二选一填）。 */
export interface GuideParams {
  location_name?: string;
  character_name?: string;
}

/**
 * 可以带小朋友去的地方和人（喂给意图 LLM，让它把「找小明」对上真实角色名）。
 * 排除小仙子自己——「带我去找小仙子」没有意义，她就贴在孩子身边。
 */
export function listGuideTargets(store: WorldStore, worldId: string, sceneId: string): GuideTarget[] {
  const scene = store.getScene(worldId, sceneId);
  const locations: GuideTarget[] = (scene?.pois ?? [])
    .filter((p) => p.name.length > 0)
    .map((p) => ({ name: p.name, kind: 'location' as const, sceneId, sceneName: scene?.name ?? sceneId }));
  const characters: GuideTarget[] = store
    .listCharacters(worldId, sceneId)
    .filter((c) => !c.isFairy)
    .map((c) => ({ name: c.name, kind: 'character' as const, sceneId, sceneName: scene?.name ?? sceneId }));
  return [...locations, ...characters];
}

/**
 * 把 guide_to 的 params 解析成引路计划。
 *
 * 返回 null = 带不了（目标不存在）。调用方**必须**此时不下发 guide、只留口头回应——
 * 绝不能出现「好呀跟我来」然后没人动，那正是 types.ts:28 当初剔除仙子移动能力要防的病。
 */
export function planGuide(
  store: WorldStore,
  worldId: string,
  fromScene: string,
  params: GuideParams,
): GuidePlan | null {
  const charName = String(params.character_name ?? '').trim();
  const locName = String(params.location_name ?? '').trim();

  if (charName) {
    const roster = store.listCharacters(worldId, fromScene).filter((c) => !c.isFairy);
    const target = matchByName(roster, charName);
    if (!target) return null;
    return {
      targetKind: 'character',
      targetName: target.name,
      targetScene: fromScene,
      // 快照：村民自己会走动，客户端到场后按名字重解析他的实时位置（决策 §6.2 不钉住他）
      targetTile: target.position,
      legs: [],
    };
  }

  if (locName) {
    const scene = store.getScene(worldId, fromScene);
    const poi = matchByName(scene?.pois ?? [], locName);
    if (!poi) return null;
    return {
      targetKind: 'location',
      targetName: poi.name,
      targetScene: fromScene,
      targetTile: { tileX: poi.tile[0], tileY: poi.tile[1] }, // POI 存的是元组，统一成 TilePos 下发
      legs: [],
    };
  }

  return null;
}
