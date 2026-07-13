// 小仙子引路（guide_to / guide_stop）服务端测试 —— 见 docs/fairy-guide-design.md。
//
// 关键契约：引路是她**唯一**能兑现的位移（走路的是小朋友，她只在前面飞），所以 guide_to 不能像
// move_to/follow 那样被 effectiveAbilities 剔掉；而目标不存在时**绝不下发 guide**——「好呀跟我来」
// 却没人动，正是当初剔除她移动能力要防的病。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { respondToTranscript } from '../src/voice.ts';
import { planGuide, listGuideTargets } from '../src/guide.ts';
import { routeScenes } from '../src/scene_graph.ts';
import type { Character, IntentContext, IntentResult, Scene } from '../src/types.ts';
import { effectiveAbilities } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string, name: string, isFairy = false): Character {
  const c: Character = {
    id,
    worldId,
    isFairy,
    name,
    personality: '活泼开朗',
    voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 10, tileY: 20 },
    sceneId: 'village',
    abilities: isFairy
      ? ['create_character', 'create_prop', 'create_sticker', 'play_game', 'guide_to', 'guide_stop']
      : ['move_to', 'deliver_message'],
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function seedScene(store: WorldStore, worldId: string): void {
  const scene: Scene = {
    worldId,
    sceneId: 'village',
    name: '村庄',
    terrainAsset: '',
    gridTiles: 75,
    pois: [
      { tile: [30, 40], radius: 6, trigger: 'poi_windmill', name: '风车', aliases: [] },
      { tile: [50, 12], radius: 6, trigger: 'poi_pond', name: '池塘', aliases: [] },
    ],
    portals: [],
    terrainVersion: 0,
  };
  store.upsertScene(scene);
}

/** routeIntent 的上下文探针：既跑真 mock 路由，又把 ctx 抓出来看喂了什么。 */
function spyAdapters(ctxs: IntentContext[]) {
  const base = createMockAdapters();
  return {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(t: string, ctx: IntentContext): Promise<IntentResult> {
        ctxs.push(ctx);
        return base.llm.routeIntent(t, ctx);
      },
    },
  };
}

function freshWorld(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  seedScene(store, 'w1');
  seedChar(store, 'w1', 'fairy', '小神仙', true);
  seedChar(store, 'w1', 'blue', '小蓝');
  return store;
}

test('effectiveAbilities：guide_to/guide_stop 不被当成走动能力剔掉（她的唯一位移）', () => {
  const store = freshWorld();
  const fairy = store.getCharacter('w1', 'fairy')!;
  const got = effectiveAbilities(fairy);
  assert.ok(got.includes('guide_to'), `小仙子必须保留 guide_to，实得 [${got.join(', ')}]`);
  assert.ok(got.includes('guide_stop'), `小仙子必须保留 guide_stop，实得 [${got.join(', ')}]`);
  // 同时不能把真正走不了的能力放回来
  for (const a of ['move_to', 'follow', 'chat_with']) {
    assert.ok(!got.includes(a), `小仙子不该有 ${a}`);
  }
});

test('respondToTranscript：「带我去风车」→ 下发引路计划（地点，同场景 legs 为空）', async () => {
  const store = freshWorld();
  const r = await respondToTranscript('w1', 'fairy', 'p1', '带我去风车', createMockAdapters(), store, undefined, false, 'village');
  assert.ok(r.guide, '应下发引路计划');
  assert.equal(r.guide!.targetKind, 'location');
  assert.equal(r.guide!.targetName, '风车');
  assert.deepEqual(r.guide!.targetTile, { tileX: 30, tileY: 40 });
  assert.equal(r.guide!.targetScene, 'village');
  assert.deepEqual(r.guide!.legs, [], '同场景不需要走 portal');
  // guide 不是行为脚本：绝不能漏进 behaviorScript 让 BehaviorExecutor 去执行（她也不吃）
  assert.equal(r.behaviorScript, undefined, 'guide_to 必须从 behaviorScript 里摘干净');
  assert.ok(r.replyText.length > 0, '引路要出声招呼小朋友跟上');
});

test('respondToTranscript：「我想找小蓝」→ 下发引路计划（角色，坐标取他当下位置）', async () => {
  const store = freshWorld();
  const r = await respondToTranscript('w1', 'fairy', 'p1', '我想找小蓝', createMockAdapters(), store, undefined, false, 'village');
  assert.ok(r.guide, '应下发引路计划');
  assert.equal(r.guide!.targetKind, 'character');
  assert.equal(r.guide!.targetName, '小蓝');
  assert.deepEqual(r.guide!.targetTile, { tileX: 10, tileY: 20 });
});

test('respondToTranscript：目标不存在 →【不发 guide】，只留口头回应', async () => {
  const store = freshWorld();
  const r = await respondToTranscript('w1', 'fairy', 'p1', '带我去月亮', createMockAdapters(), store, undefined, false, 'village');
  assert.equal(r.guide, undefined, '带不了就绝不能下发引路计划——否则她应下了却不动');
  assert.ok(r.replyText.length > 0, '仍要老实回应一句');
});

test('respondToTranscript：「不去了」→ guideStop', async () => {
  const store = freshWorld();
  const r = await respondToTranscript('w1', 'fairy', 'p1', '不去了', createMockAdapters(), store, undefined, false, 'village');
  assert.equal(r.guideStop, true, '应下发取消');
  assert.equal(r.guide, undefined);
  assert.equal(r.behaviorScript, undefined, 'guide_stop 必须从 behaviorScript 里摘干净');
});

test('respondToTranscript：引路候选喂给小仙子，且不含她自己', async () => {
  const store = freshWorld();
  const ctxs: IntentContext[] = [];
  await respondToTranscript('w1', 'fairy', 'p1', '你好呀', spyAdapters(ctxs), store, undefined, false, 'village');
  const targets = ctxs[0]!.guideTargets ?? [];
  const names = targets.map((t) => t.name);
  assert.ok(names.includes('风车'), `引路候选应含地点，实得 [${names.join(', ')}]`);
  assert.ok(names.includes('小蓝'), `引路候选应含角色，实得 [${names.join(', ')}]`);
  assert.ok(!names.includes('小神仙'), '「带我去找小仙子」没有意义——她就贴在孩子身边');
});

test('respondToTranscript：普通村民没有 guide_to，也不白算引路候选', async () => {
  const store = freshWorld();
  const ctxs: IntentContext[] = [];
  await respondToTranscript('w1', 'blue', 'p1', '你好呀', spyAdapters(ctxs), store, undefined, false, 'village');
  assert.ok(!ctxs[0]!.abilities.includes('guide_to'), '引路是小仙子专属');
  assert.equal(ctxs[0]!.guideTargets, undefined, '村民带不了路，不该白搭 prompt token');
});

test('planGuide：名字模糊匹配（ASR 多字，「风车那儿」→ 风车）', () => {
  const store = freshWorld();
  const plan = planGuide(store, 'w1', 'village', { location_name: '风车那儿' });
  assert.ok(plan, 'ASR 转写多字时也要认得出来');
  assert.equal(plan!.targetName, '风车');
});

test('listGuideTargets：带场景名（LLM 才能说「小明在森林」）', () => {
  const store = freshWorld();
  const targets = listGuideTargets(store, 'w1', 'village');
  const windmill = targets.find((t) => t.name === '风车');
  assert.equal(windmill?.sceneName, '村庄');
});

// ── 跨场景（P3）：portal 图 BFS + 2 跳上限 ───────────────────────────────────
//
// 拓扑（只有 village↔forest↔cave 这一条链，desert 孤立）：
//   village ──> forest ──> cave        desert（没有任何 portal 连过来）
//   village <── forest <── cave

/** 建一条 village → forest → cave 的链，外加一个不连通的 desert。 */
function seedChain(store: WorldStore): void {
  const mk = (sceneId: string, name: string, portals: Scene['portals']): Scene => ({
    worldId: 'w1', sceneId, name, terrainAsset: '', gridTiles: 75, pois: [], portals, terrainVersion: 0,
  });
  store.upsertScene(mk('forest', '森林', [
    { tile: [5, 5], radius: 3, toScene: 'village', toTile: [70, 70] },
    { tile: [60, 60], radius: 3, toScene: 'cave', toTile: [1, 1] },
  ]));
  store.upsertScene(mk('cave', '山洞', [{ tile: [1, 1], radius: 3, toScene: 'forest', toTile: [60, 60] }]));
  store.upsertScene(mk('desert', '沙漠', [])); // 孤岛：没有 portal 连过来
  // village 已由 seedScene 建好（带 POI），补一条通往 forest 的门
  const village = store.getScene('w1', 'village')!;
  village.portals = [{ tile: [70, 70], radius: 3, toScene: 'forest', toTile: [5, 5] }];
  store.upsertScene(village);
}

test('routeScenes：同场景 = 空路径；相邻 = 1 跳', () => {
  const store = freshWorld();
  seedChain(store);
  assert.deepEqual(routeScenes(store, 'w1', 'village', 'village'), []);
  const legs = routeScenes(store, 'w1', 'village', 'forest');
  assert.equal(legs?.length, 1);
  assert.equal(legs![0]!.sceneId, 'village');
  assert.equal(legs![0]!.toScene, 'forest');
  assert.deepEqual(legs![0]!.portalTile, { tileX: 70, tileY: 70 }, '要给出这一段该走的那道门');
});

test('routeScenes：2 跳可达（village → forest → cave）', () => {
  const store = freshWorld();
  seedChain(store);
  const legs = routeScenes(store, 'w1', 'village', 'cave');
  assert.equal(legs?.length, 2);
  assert.deepEqual(legs!.map((l) => l.toScene), ['forest', 'cave']);
});

test('routeScenes：不可达 → null（孤立场景带不过去）', () => {
  const store = freshWorld();
  seedChain(store);
  assert.equal(routeScenes(store, 'w1', 'village', 'desert'), null);
});

test('routeScenes：超过 2 跳上限 → null（老板：小朋友扛不住长途跋涉）', () => {
  const store = freshWorld();
  seedChain(store);
  // 把链接长一节：cave → deep（village 到 deep 要 3 跳）
  store.upsertScene({
    worldId: 'w1', sceneId: 'deep', name: '深洞', terrainAsset: '', gridTiles: 75, pois: [], portals: [], terrainVersion: 0,
  });
  const cave = store.getScene('w1', 'cave')!;
  cave.portals = [...cave.portals, { tile: [9, 9], radius: 3, toScene: 'deep', toTile: [2, 2] }];
  store.upsertScene(cave);
  assert.equal(routeScenes(store, 'w1', 'village', 'cave')?.length, 2, '2 跳仍然可以');
  assert.equal(routeScenes(store, 'w1', 'village', 'deep'), null, '3 跳超上限，宁可让她说「太远啦」');
});

test('planGuide：跨场景找村民 → 带 portal 逐跳', () => {
  const store = freshWorld();
  seedChain(store);
  const ming = seedChar(store, 'w1', 'ming', '小明');
  ming.sceneId = 'forest';
  ming.position = { tileX: 33, tileY: 44 };
  store.saveCharacter(ming);

  const plan = planGuide(store, 'w1', 'village', { character_name: '小明' });
  assert.ok(plan, '小明在森林，村庄能走过去 → 应给出计划');
  assert.equal(plan!.targetScene, 'forest');
  assert.deepEqual(plan!.targetTile, { tileX: 33, tileY: 44 });
  assert.equal(plan!.legs.length, 1, '村庄 → 森林 一道门');
  assert.equal(plan!.legs[0]!.toScene, 'forest');
});

test('planGuide：目标在够不着的场景 → null（不发 guide，只留口头回应）', () => {
  const store = freshWorld();
  seedChain(store);
  const lost = seedChar(store, 'w1', 'lost', '小远');
  lost.sceneId = 'desert'; // 孤岛，走不过去
  store.saveCharacter(lost);

  assert.equal(planGuide(store, 'w1', 'village', { character_name: '小远' }), null);
});

test('listGuideTargets：够不着的目标不上菜单（列了 LLM 就会应下，而 planGuide 又会拒）', () => {
  const store = freshWorld();
  seedChain(store);
  const ming = seedChar(store, 'w1', 'ming', '小明');
  ming.sceneId = 'forest';
  store.saveCharacter(ming);
  const lost = seedChar(store, 'w1', 'lost', '小远');
  lost.sceneId = 'desert';
  store.saveCharacter(lost);

  const names = listGuideTargets(store, 'w1', 'village').map((t) => t.name);
  assert.ok(names.includes('小明'), '森林可达 → 该上菜单');
  assert.ok(!names.includes('小远'), '沙漠不可达 → 不该上菜单，免得她应下却带不了');
});
