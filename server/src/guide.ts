/**
 * 小仙子引路（guide_to）—— 见 docs/fairy-guide-design.md。
 *
 * 她不会走路（LOCOMOTION_ABILITIES 对 isFairy 剔除，客户端 _run_behavior 也早返回），所以引路
 * 不是行为脚本：这里把「带我去风车」「我想找小明」解析成一份 GuidePlan 下发，由客户端的引路
 * 状态机驱动她「飞到前面 → 回头等 → 孩子自己走过来」。玩家的 avatar 全程由孩子自己操控。
 *
 * 跨场景不传送：把「去森林找小明」翻译成「先带你走到通往森林的门，你自己走进去，我在那边接着带」。
 * portal 触发照旧走客户端既有的 _step_portal——服务端一条传送下行报文都不需要。
 */
import type { WorldStore } from './persistence.ts';
import type { Character, GuidePlan, GuideTarget, Scene, TilePos } from './types.ts';
import { DEFAULT_SCENE } from './types.ts';
import { matchByName } from './names.ts';
import { routeScenes } from './scene_graph.ts';

/** guide_to 的 params 形状（LLM 二选一填）。 */
export interface GuideParams {
  location_name?: string;
  character_name?: string;
}

function sceneOf(c: Character): string {
  return c.sceneId ?? DEFAULT_SCENE;
}

/** 全世界可引路的角色（排除小仙子自己——「带我去找小仙子」没有意义，她就贴在孩子身边）。 */
function guideableCharacters(store: WorldStore, worldId: string): Character[] {
  return store.listCharacters(worldId).filter((c) => !c.isFairy);
}

/**
 * 可以带小朋友去的地方和人（喂给意图 LLM）。
 *
 * 刻意**跨场景**：孩子在村庄说「找小明」而小明在森林时，若 prompt 里没有小明，LLM 连他存在
 * 都不知道，只会答「没有这个人」。花名册（voice.ts 的 roster）仍是 scene-scoped，那是对的——
 * 你没法命令一个不在场的人；但你可以被带去找他。两者的作用域不同，别合并。
 */
export function listGuideTargets(store: WorldStore, worldId: string, fromScene: string): GuideTarget[] {
  const scenes = store.listScenes(worldId);
  const sceneName = (id: string): string => scenes.find((s) => s.sceneId === id)?.name ?? id;

  const locations: GuideTarget[] = scenes.flatMap((s: Scene) =>
    s.pois
      .filter((p) => p.name.length > 0)
      .map((p) => ({ name: p.name, kind: 'location' as const, sceneId: s.sceneId, sceneName: s.name })),
  );
  const characters: GuideTarget[] = guideableCharacters(store, worldId).map((c) => ({
    name: c.name,
    kind: 'character' as const,
    sceneId: sceneOf(c),
    sceneName: sceneName(sceneOf(c)),
  }));

  // 太远（超 MAX_GUIDE_LEGS 跳）的目标压根不列：列了 LLM 就会应下，而 planGuide 又会拒掉，
  // 白白让她说一句「好呀跟我来」然后没有下文。够不着的东西不要摆上菜单。
  return [...locations, ...characters].filter(
    (t) => t.sceneId === fromScene || routeScenes(store, worldId, fromScene, t.sceneId) !== null,
  );
}

/** POI 存的是元组，统一成 TilePos 下发。 */
function poiTile(t: [number, number]): TilePos {
  return { tileX: t[0], tileY: t[1] };
}

/**
 * 把 guide_to 的 params 解析成引路计划。
 *
 * 返回 null = 带不了（目标不存在，或远过 MAX_GUIDE_LEGS 跳）。调用方**必须**此时不下发 guide、
 * 只留口头回应——绝不能出现「好呀跟我来」然后没人动，那正是 types.ts:28 当初剔除她移动能力要防的病。
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
    // 先找本场景（同名时优先眼前这个），再放眼全世界
    const here = guideableCharacters(store, worldId).filter((c) => sceneOf(c) === fromScene);
    const target = matchByName(here, charName) ?? matchByName(guideableCharacters(store, worldId), charName);
    if (!target) return null;
    const legs = routeScenes(store, worldId, fromScene, sceneOf(target));
    if (legs === null) return null; // 不可达或太远
    return {
      targetKind: 'character',
      targetName: target.name,
      targetScene: sceneOf(target),
      // 快照：村民自己会走动，客户端到场后按名字重解析他的实时位置（老板拍板：不钉住他）
      targetTile: target.position,
      legs,
    };
  }

  if (locName) {
    const scenes = store.listScenes(worldId);
    // 同上：本场景的同名地点优先（每个场景都可能有「池塘」）
    const local = scenes.find((s) => s.sceneId === fromScene);
    const hit = local ? matchByName(local.pois, locName) : undefined;
    if (hit) {
      return { targetKind: 'location', targetName: hit.name, targetScene: fromScene, targetTile: poiTile(hit.tile), legs: [] };
    }
    for (const s of scenes) {
      const poi = matchByName(s.pois, locName);
      if (!poi) continue;
      const legs = routeScenes(store, worldId, fromScene, s.sceneId);
      if (legs === null) continue; // 这个场景太远，看看别的场景有没有同名地点
      return { targetKind: 'location', targetName: poi.name, targetScene: s.sceneId, targetTile: poiTile(poi.tile), legs };
    }
    return null;
  }

  return null;
}
