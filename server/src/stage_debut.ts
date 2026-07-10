// 开演入口的选角层：把「世界里现有的角色 + 在场的孩子」映射成手写剧本要的演员表。
//
// 这是 debug/试演用的**固定选角**，Plan 2 (screenplay-gen) 会用 LLM 大纲取代它——
// 但映射的形状是一样的：actor.id 指向世界里真实的角色/玩家，actor.name 是**剧中角色名**
// （cast('丑小鸭') 按 name 匹配），所以同一个村民今天演丑小鸭、明天演天鹅都不用改剧本。
//
// 设计: docs/script-runtime-design.md

import { loadScreenplay, type ScreenplayName } from './screenplays.ts';
import type { WorldStore } from './persistence.ts';
import type { WorldHub } from './world_hub.ts';
import type { StageStartOpts } from './stage_session.ts';
import type { StageActorInfo } from './stage_types.ts';

/** 三幕小剧场的戏中角色名，按顺序分给世界里的前三个村民。 */
const PLAY_ROLES = ['丑小鸭', '鸭妈妈', '天鹅'] as const;

/** 落点名兜底：世界一个 POI 都没有时，moveTo 会解析失败，宁可不演也别演一半炸。 */
export class DebutError extends Error {}

/**
 * 为一个剧本组一份开演参数。角色/落点都取自世界现状，取不到就抛 DebutError（调用方转 4xx）。
 * 玩家演员的 id 约定即 playerId——服务端 near 求值和位置流都以它为键（见 stage_session.ts）。
 */
export function buildDebut(
  store: WorldStore,
  hub: WorldHub,
  worldId: string,
  screenplay: ScreenplayName,
  sceneId?: string,
): StageStartOpts {
  const villagers = store.listCharacters(worldId).filter((c) => !c.isFairy);
  const code = loadScreenplay(screenplay);

  if (screenplay === 'hide_and_seek') {
    const seeker = villagers[0];
    if (!seeker) throw new DebutError('世界里一个村民都没有，没人当鬼');
    const kid = hub.membersIn(worldId).find((m) => m.playerId);
    if (!kid) throw new DebutError('世界里没有在线的小朋友，演给谁看');
    const actors: StageActorInfo[] = [
      { id: seeker.id, name: seeker.name, isPlayer: false, voiceId: seeker.voiceId },
      { id: kid.playerId, name: playerName(store, kid.playerId), isPlayer: true },
    ];
    // catchDist 用世界坐标（TILE_SIZE=2.0），2 ≈ 一格：贴上了才算抓到。
    return { code, actors, params: { hideSec: 10, gameSec: 90, catchDist: 2 } };
  }

  if (villagers.length < PLAY_ROLES.length) {
    throw new DebutError(`三幕小剧场要 ${PLAY_ROLES.length} 个村民，世界里只有 ${villagers.length} 个`);
  }
  const actors: StageActorInfo[] = PLAY_ROLES.map((role, i) => ({
    id: villagers[i].id,
    name: role, // 剧中角色名：cast('丑小鸭') 认的是这个，不是村民本名
    isPlayer: false,
    voiceId: villagers[i].voiceId,
  }));
  const [pond, lake] = pickSpots(store, worldId, sceneId);
  return { code, actors, params: { pond, lake } };
}

/** 玩家在剧本里的称呼：优先小名。档案没建出来就叫「小朋友」。 */
function playerName(store: WorldStore, playerId: string): string {
  const p = store.getPlayer(playerId);
  return p?.nickname || p?.name || '小朋友';
}

/**
 * 两个落点：从本场景的 POI 里挑。只有一个就两幕都用它（走位退化成原地，比解析失败强）。
 * moveTo 的落点名由客户端对 scenes.pois 解析（见 world.gd _stage_move_params）。
 */
function pickSpots(store: WorldStore, worldId: string, sceneId?: string): [string, string] {
  const pois = store.getLocations(worldId, sceneId);
  if (pois.length === 0) throw new DebutError('本场景没有任何地点名，演员不知道往哪走');
  return [pois[0], pois[1] ?? pois[0]];
}
