// s1-hood-activate P3（沙箱验证的确定性内核）：《小红帽》在合并主场景 village_forest 的引路集成。
// 《小红帽》是首个 hard-依赖服务端 scenes.pois 的册——互动是 task:visit「外婆家」，点点 guide_to 引路，
// planGuide 从 listScenes(worldId).pois 取 poi_grandma 的 tile。这里在一个注册了 village_forest 场景 +
// seed 了 hood 的世界里，端到端验：册引用的地点确实是场景 POI、引路能解析到 (66,63)、点点听懂「带我去外婆家」。
// 客户端引路状态机（她飞前领、孩子自己走、到点完成 visit）另由 test_fairy_guide.gd 覆盖。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { seedStoryCharacters } from '../src/story_seed.ts';
import { LITTLE_RED_HOOD, storyCharacterId } from '../src/story_books.ts';
import { planGuide, listGuideTargets } from '../src/guide.ts';
import { respondToTranscript } from '../src/voice.ts';
import { seedFairy } from '../src/server.ts';
import type { Scene, ScenePoi } from '../src/types.ts';

const VF = 'village_forest';
// tools/export_terrain.gd POIS_VF——服务端下发/沙箱注册的就是这份。
const POIS_VF: ScenePoi[] = [
  { tile: [34, 9], radius: 18, trigger: 'poi_pond', name: '池塘', aliases: ['湖', '水边', '河边'] },
  { tile: [66, 63], radius: 14, trigger: 'poi_grandma', name: '外婆家', aliases: ['外婆', '奶奶家', '小屋'] },
  { tile: [30, 86], radius: 16, trigger: 'poi_forest_deep', name: '森林深处', aliases: ['深林', '大森林', '林子深处'] },
];

/** 复刻沙箱验证：建世界 + 注册 village_forest 场景（POIS_VF）+ 补点点 + seed 《小红帽》。 */
async function seedHoodWorld(): Promise<WorldStore> {
  const store = new WorldStore();
  store.createWorld('w1');
  const scene: Scene = {
    worldId: 'w1', sceneId: VF, name: '林边村庄', terrainAsset: '', gridTiles: 100,
    pois: POIS_VF, portals: [], terrainVersion: 1,
  };
  store.upsertScene(scene);
  store.addCharacter(seedFairy('w1')); // 点点：引路的施法者
  await seedStoryCharacters(createMockAdapters(), store, 'w1', LITTLE_RED_HOOD);
  return store;
}

test('hood 册引用的 visit 地点「外婆家」确实是 village_forest 场景里的 POI（册↔场景不漂移）', async () => {
  const store = await seedHoodWorld();
  const chapter1 = LITTLE_RED_HOOD.chapters[0]!;
  assert.equal(chapter1.interaction?.kind, 'task');
  const locName = (chapter1.interaction as { locationName?: string }).locationName;
  assert.equal(locName, '外婆家', 'hood 幕1 visit 指向外婆家');
  // 该地点必须能在世界里解析出来（getLocations 走 scenes.pois）——否则 visit 无处可去
  const locations = store.getLocations('w1', VF);
  assert.ok(locations.includes('外婆家'), `外婆家须是 village_forest 的 POI，实得 [${locations.join(', ')}]`);
});

test('planGuide：外婆家 → poi_grandma tile (66,63)，同场景 legs 为空（引路有真目标）', async () => {
  const store = await seedHoodWorld();
  const plan = planGuide(store, 'w1', VF, { location_name: '外婆家' });
  assert.ok(plan, 'planGuide 必须返回计划——否则点点应了却不动');
  assert.equal(plan!.targetKind, 'location');
  assert.equal(plan!.targetName, '外婆家');
  assert.deepEqual(plan!.targetTile, { tileX: 66, tileY: 63 });
  assert.equal(plan!.targetScene, VF);
  assert.deepEqual(plan!.legs, [], '同场景引路不走 portal');
});

test('listGuideTargets：从 village_forest 出发，外婆家在可引路菜单里', async () => {
  const store = await seedHoodWorld();
  const targets = listGuideTargets(store, 'w1', VF);
  const names = targets.filter((t) => t.kind === 'location').map((t) => t.name);
  assert.ok(names.includes('外婆家'), `外婆家须在引路菜单，实得 [${names.join(', ')}]`);
});

test('respondToTranscript：点点听「带我去外婆家」→ 下发引路计划到 (66,63)', async () => {
  const store = await seedHoodWorld();
  const r = await respondToTranscript('w1', storyFairyId(store), 'p1', '带我去外婆家', createMockAdapters(), store, undefined, false, VF);
  assert.ok(r.guide, '应下发引路计划');
  assert.equal(r.guide!.targetName, '外婆家');
  assert.deepEqual(r.guide!.targetTile, { tileX: 66, tileY: 63 });
  assert.equal(r.guide!.targetScene, VF);
});

test('seed hood：红帽/外婆都落 village_forest（进主场景 roster 才搭得上话）', async () => {
  const store = await seedHoodWorld();
  const red = store.getCharacter('w1', storyCharacterId('hood', 'red_hood'))!;
  const granny = store.getCharacter('w1', storyCharacterId('hood', 'granny'))!;
  assert.equal(red.sceneId, VF, '小红帽在主场景');
  assert.equal(granny.sceneId, VF, '外婆在主场景');
});

/** 取世界里点点的 id（seedFairy 生成的）。 */
function storyFairyId(store: WorldStore): string {
  return store.listCharacters('w1').find((c) => c.isFairy)!.id;
}
