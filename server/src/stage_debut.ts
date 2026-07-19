// 开演入口的选角层：把「世界里现有的角色 + 在场的孩子」映射成手写剧本要的演员表。
//
// 这是 debug/试演用的**固定选角**，Plan 2 (screenplay-gen) 会用 LLM 大纲取代它——
// 但映射的形状是一样的：actor.id 指向世界里真实的角色/玩家，actor.name 是**剧中角色名**
// （cast('丑小鸭') 按 name 匹配），所以同一个村民今天演丑小鸭、明天演天鹅都不用改剧本。
//
// 设计: docs/script-runtime-design.md

import { loadScreenplay, type ScreenplayName } from './screenplays.ts';
import { storyCharacterId, type StoryBook } from './story_books.ts';
import { DEFAULT_SCENE } from './types.ts';
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
 *
 * 演员和落点必须来自**同一个场景**（缺省村庄）：跨场景选角会让村庄的村民走向森林的地名，
 * 客户端 _stage_move_params 解析不了，第一条 move_to 就 abort 整场。
 */
export function buildDebut(
  store: WorldStore,
  hub: WorldHub,
  worldId: string,
  screenplay: ScreenplayName,
  sceneId: string = DEFAULT_SCENE,
): StageStartOpts {
  // listCharacters 按场景过滤时恒带点点（她跨场景跟随），照旧靠 isFairy 剔除。
  const villagers = store.listCharacters(worldId, sceneId).filter((c) => !c.isFairy);
  const code = loadScreenplay(screenplay);

  if (screenplay === 'hide_and_seek') {
    const seeker = villagers[0];
    if (!seeker) throw new DebutError(`场景「${sceneId}」里一个村民都没有，没人当鬼`);
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
    throw new DebutError(`三幕小剧场要 ${PLAY_ROLES.length} 个村民，场景「${sceneId}」里只有 ${villagers.length} 个`);
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

/**
 * 章回剧情选角（M2 §4.2）：不走 buildDebut 的 roster 随机——演员就是册 cast 本人，
 * 按 storyCharacterId 约定直取（seed 时已落 roster），actor.name 用角色本名（剧本 cast('猪大哥')）。
 * 在线的小朋友也进演员表（剧本可 cast 到他/对他说话；不用则闲置无害）。
 * 幕的 screenplay 名在 P3 随剧本文件注册进 SCREENPLAYS；名字对不上 loadScreenplay 会抛，
 * 与角色缺席一样转成 DebutError——宁可不演也别演一半炸。
 */
export function buildStoryStageOpts(
  store: WorldStore,
  hub: WorldHub,
  worldId: string,
  playerId: string,
  book: StoryBook,
  chapter: number,
): StageStartOpts {
  const ch = book.chapters[chapter];
  if (!ch) throw new DebutError(`册「${book.id}」没有第 ${chapter} 幕`);
  let code: string;
  try {
    code = loadScreenplay(ch.screenplay as ScreenplayName);
  } catch {
    throw new DebutError(`剧本「${ch.screenplay}」不存在`);
  }
  const actors: StageActorInfo[] = book.cast.map((c) => {
    const char = store.getCharacter(worldId, storyCharacterId(book.id, c.castId));
    if (!char) throw new DebutError(`故事角色「${c.name}」还没落进这个世界`);
    return { id: char.id, name: c.name, isPlayer: false, voiceId: char.voiceId };
  });
  const kid = playerId && hub.membersIn(worldId).some((m) => m.playerId === playerId) ? playerId : '';
  if (kid) actors.push({ id: kid, name: playerName(store, kid), isPlayer: true });
  return { code, actors };
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
function pickSpots(store: WorldStore, worldId: string, sceneId: string): [string, string] {
  const pois = store.getLocations(worldId, sceneId);
  if (pois.length === 0) throw new DebutError(`场景「${sceneId}」没有任何地点名，演员不知道往哪走`);
  return [pois[0], pois[1] ?? pois[0]];
}
