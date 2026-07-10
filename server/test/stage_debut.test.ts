// 开演入口：选角层(buildDebut) + 管理端点 POST /admin/worlds/:id/stage。
// 选角的关键契约：actor.id 是世界里真实的角色/玩家 id，actor.name 是**剧中角色名**。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { WorldHub } from '../src/world_hub.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildDebut, DebutError } from '../src/stage_debut.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character, type Player } from '../src/types.ts';

function seedChar(store: WorldStore, id: string, name: string, isFairy = false, sceneId = DEFAULT_SCENE): void {
  const c: Character = {
    id, worldId: 'w1', isFairy, name, personality: 'p', voiceId: `voice-${id}`,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId, abilities: [], relationships: {},
  };
  store.addCharacter(c);
}

/** 种一个世界：一个仙子 + n 个村民 + 两个地点名。 */
function seedWorld(names = ['阿花', '阿牛', '阿土']): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'f1', '小仙子', true);
  names.forEach((n, i) => seedChar(store, `c${i + 1}`, n));
  store.setLocations('w1', ['池塘', '大山']);
  return store;
}

/**
 * 多场景世界：森林先入库（listScenes 里排在前面），村庄后入库。
 * prod 的 default 世界就是这个形状——摊平取 POI 会先拿到森林的地名。
 */
function seedTwoScenes(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  store.upsertScene({
    worldId: 'w1', sceneId: 'forest', name: '森林', terrainAsset: 'h-forest', gridTiles: 75,
    pois: [{ tile: [2, 2], radius: 5, trigger: 't', name: '小河深潭', aliases: [] },
           { tile: [4, 4], radius: 5, trigger: 't', name: '林间空地', aliases: [] }],
    portals: [],
  });
  store.upsertScene({
    worldId: 'w1', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h-village', gridTiles: 75,
    pois: [{ tile: [6, 6], radius: 5, trigger: 't', name: '池塘', aliases: [] },
           { tile: [8, 8], radius: 5, trigger: 't', name: '大山', aliases: [] }],
    portals: [],
  });
  seedChar(store, 'f1', '小仙子', true);
  ['阿花', '阿牛', '阿土'].forEach((n, i) => seedChar(store, `c${i + 1}`, n));
  ['林中甲', '林中乙', '林中丙'].forEach((n, i) => seedChar(store, `w${i + 1}`, n, false, 'forest'));
  return store;
}

/** 往 hub 里塞一个在场的小朋友。 */
function joinKid(hub: WorldHub, playerId: string): void {
  hub.join('w1', { clientId: `conn-${playerId}`, playerId, send: () => {} });
}

test('选角(躲猫猫)：首个非仙子村民当鬼 + 在场小朋友演自己，玩家 actor id 即 playerId', () => {
  const store = seedWorld();
  const p: Player = { id: 'p1', name: '王小明', nickname: '明明', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
  store.upsertPlayer(p);
  const hub = new WorldHub();
  joinKid(hub, 'p1');

  const opts = buildDebut(store, hub, 'w1', 'hide_and_seek');
  assert.deepEqual(opts.actors, [
    { id: 'c1', name: '阿花', isPlayer: false, voiceId: 'voice-c1' }, // 仙子被跳过
    { id: 'p1', name: '明明', isPlayer: true },                        // 优先小名
  ]);
  // catchDist 是世界坐标(TILE_SIZE=2.0)，不是格子数
  assert.deepEqual(opts.params, { hideSec: 10, gameSec: 90, catchDist: 2 });
  assert.match(opts.code, /躲猫猫/);
});

test('选角(躲猫猫)：档案还没建出来的孩子也能演，称呼退化成「小朋友」', () => {
  const hub = new WorldHub();
  joinKid(hub, 'p-unknown');
  const opts = buildDebut(seedWorld(), hub, 'w1', 'hide_and_seek');
  assert.equal(opts.actors[1].name, '小朋友');
});

test('选角(躲猫猫)：世界里没在线的孩子 → 拒演（演给谁看）', () => {
  assert.throws(() => buildDebut(seedWorld(), new WorldHub(), 'w1', 'hide_and_seek'), DebutError);
});

test('选角(躲猫猫)：只有仙子没有村民 → 拒演（没人当鬼）', () => {
  const store = seedWorld([]);
  const hub = new WorldHub();
  joinKid(hub, 'p1');
  assert.throws(() => buildDebut(store, hub, 'w1', 'hide_and_seek'), DebutError);
});

test('选角(三幕)：前三个村民顶剧中角色名，id/音色仍是本人；落点取本场景 POI', () => {
  const opts = buildDebut(seedWorld(), new WorldHub(), 'w1', 'three_act_play');
  assert.deepEqual(opts.actors, [
    { id: 'c1', name: '丑小鸭', isPlayer: false, voiceId: 'voice-c1' },
    { id: 'c2', name: '鸭妈妈', isPlayer: false, voiceId: 'voice-c2' },
    { id: 'c3', name: '天鹅', isPlayer: false, voiceId: 'voice-c3' },
  ], '演的是戏中角色，但走位/说话找的是真实村民');
  assert.deepEqual(opts.params, { pond: '池塘', lake: '大山' });
});

test('选角(三幕)：村民不够三个 → 拒演，错误里说清缺几个', () => {
  assert.throws(
    () => buildDebut(seedWorld(['阿花', '阿牛']), new WorldHub(), 'w1', 'three_act_play'),
    (e: Error) => e instanceof DebutError && /场景「village」里只有 2 个/.test(e.message),
  );
});

test('落点：只有一个 POI 就两幕共用它；一个都没有 → 拒演（演员不知道往哪走）', () => {
  const one = seedWorld();
  one.setLocations('w1', ['池塘']);
  assert.deepEqual(buildDebut(one, new WorldHub(), 'w1', 'three_act_play').params, { pond: '池塘', lake: '池塘' });

  const none = seedWorld();
  none.setLocations('w1', []);
  assert.throws(() => buildDebut(none, new WorldHub(), 'w1', 'three_act_play'), DebutError);
});

test('多场景：选角和落点只取当前场景，不把村庄的演员支去森林的地名', () => {
  const store = seedTwoScenes();
  // 缺省场景 = village：演员必须是村庄村民，落点必须是村庄 POI
  const village = buildDebut(store, new WorldHub(), 'w1', 'three_act_play');
  assert.deepEqual(village.actors.map((a) => a.id), ['c1', 'c2', 'c3'], '村庄的戏不能选森林的演员');
  assert.deepEqual(village.params, { pond: '池塘', lake: '大山' }, '村庄的演员走不到「小河深潭」，客户端解析不了会整场 abort');

  // 显式点名 forest：换成森林的演员和地名
  const forest = buildDebut(store, new WorldHub(), 'w1', 'three_act_play', 'forest');
  assert.deepEqual(forest.actors.map((a) => a.id), ['w1', 'w2', 'w3']);
  assert.deepEqual(forest.params, { pond: '小河深潭', lake: '林间空地' });
});

test('多场景(躲猫猫)：鬼从当前场景里挑', () => {
  const hub = new WorldHub();
  joinKid(hub, 'p1');
  const store = seedTwoScenes();
  assert.equal(buildDebut(store, hub, 'w1', 'hide_and_seek').actors[0].id, 'c1');
  assert.equal(buildDebut(store, hub, 'w1', 'hide_and_seek', 'forest').actors[0].id, 'w1');
});

test('端点 /admin/worlds/:id/stage：token 门禁 → 404 → 未知剧本 400 → 开演 200 带演员表', async (t) => {
  const store = seedWorld();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  const url = '/admin/worlds/w1/stage';

  delete process.env.MALIANG_ADMIN_TOKEN;
  assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const h = { 'x-admin-token': 'sesame' };
    assert.equal((await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } })).statusCode, 403);
    assert.equal((await app.inject({ method: 'POST', url: '/admin/worlds/nope/stage', headers: h })).statusCode, 404);

    const bad = await app.inject({ method: 'POST', url, headers: h, payload: { screenplay: 'macbeth' } });
    assert.equal(bad.statusCode, 400);
    assert.match(bad.json().error, /screenplay must be one of/);

    // 世界里没在线的孩子 → 躲猫猫开不了，报得明明白白
    const noKid = await app.inject({ method: 'POST', url, headers: h, payload: { screenplay: 'hide_and_seek' } });
    assert.equal(noKid.statusCode, 400);
    assert.match(noKid.json().error, /没有在线的小朋友/);

    // 三幕不需要玩家：开演，回演员表（世界里没观众，演出随即自行 abort，不影响这次回包）
    const ok = await app.inject({ method: 'POST', url, headers: h, payload: { screenplay: 'three_act_play' } });
    assert.equal(ok.statusCode, 200);
    const body = ok.json() as { screenplay: string; actors: { id: string; name: string }[] };
    assert.equal(body.screenplay, 'three_act_play');
    assert.deepEqual(body.actors.map((a) => [a.id, a.name]), [['c1', '丑小鸭'], ['c2', '鸭妈妈'], ['c3', '天鹅']]);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
