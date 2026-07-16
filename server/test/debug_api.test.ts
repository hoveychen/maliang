import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { ANON_PLAYER } from '../src/types.ts';
import type { Character, ItemDef } from '../src/types.ts';
import { emptyTerrain, encodeTerrain, REQUIRED_GRID } from '../src/terrain.ts';
import { BUILTIN_ITEMS } from '../src/items.ts';

function makeCharacter(id: string, worldId: string, name: string, isFairy = false): Character {
  return {
    id, worldId, isFairy, name, personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: '一只小兔', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 2, tileY: 3 }, abilities: ['move_to'], relationships: {},
  };
}

/** 造两个世界：w1 有角色/记忆/对话/造物实体/背包/会话，w2 空。玩家 p1。 */
function seed(store: WorldStore): void {
  store.createWorld('w1');
  store.createWorld('w2');
  store.addCharacter(makeCharacter('c1', 'w1', '小兔'));
  store.addCharacter(makeCharacter('fairy1', 'w1', '小神仙', true));
  store.upsertPlayer({ id: 'p1', name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉', spriteAsset: '', createdAt: '2026-07-08' });
  store.addMemory('c1', { text: '小朋友叫朵朵', kind: 'identity', aboutPlayer: 'p1', ts: 0 });
  store.addChatTurn('c1', 'p1', 'child', '你好', 0);
  store.addChatTurn('c1', 'p1', 'npc', '你好朵朵', 0);
  const item: ItemDef = {
    id: 'item1', worldId: 'w1', name: '小花', renderRef: 'sdf_inline',
    spec: { name: '小花', parts: [] } as unknown as ItemDef['spec'],
    footprintW: 1, footprintH: 1, blocking: true, pathOk: true, wander: 0,
  };
  store.upsertItem(item);
  store.bagAdd('w1', ANON_PLAYER, 'item1');
  store.addStamp('w1', ANON_PLAYER); // 盖 1 章：stampProgress=1（初始 3 花不变）
  store.setLocations('w1', ['小池塘']);
  // 场景（模型 B）：debug 详情要能透出场景 + POI + 传送门的结构化数据
  store.upsertScene({
    worldId: 'w1', sceneId: 'village', name: '村庄',
    terrainAsset: 'terrain-hash-abc', gridTiles: 75, terrainVersion: 1,
    pois: [{ tile: [3, 4], radius: 2, trigger: 'pond', name: '小池塘', aliases: ['池塘', '水塘'] }],
    portals: [{ tile: [10, 10], radius: 1, toScene: 'forest', toTile: [1, 1] }],
  });
  const v1 = store.startVisit('w1', 'p1', 1000);
  store.endVisit(v1, 2000);
  store.startVisit('w1', 'p1', 3000); // 进行中
}

async function makeApp() {
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  return app;
}

test('GET /debug/api/overview：各资源计数 + 最近会话', async () => {
  const app = await makeApp();
  try {
    const res = await app.inject({ method: 'GET', url: '/debug/api/overview' });
    assert.equal(res.statusCode, 200);
    const s = res.json();
    assert.equal(s.players, 1);
    assert.equal(s.worlds, 2);
    assert.equal(s.characters, 2);
    assert.equal(s.items, 1);
    assert.equal(s.visits.total, 2);
    assert.equal(s.visits.active, 1);
    assert.equal(s.recentVisits.length, 2);
    assert.equal(s.recentVisits[0].startedAt, 3000, '最近会话按开始时间倒序');
  } finally {
    await app.close();
  }
});

test('GET /debug/api/players 与 /debug/api/players/:id：列表带会话统计，详情带记忆/对话归属', async () => {
  const app = await makeApp();
  try {
    const list = await app.inject({ method: 'GET', url: '/debug/api/players' });
    assert.equal(list.statusCode, 200);
    const ps = list.json().players;
    assert.equal(ps.length, 1);
    assert.equal(ps[0].name, '朵朵');
    assert.equal(ps[0].visitCount, 2);
    assert.equal(ps[0].lastVisitAt, 3000);

    const detail = await app.inject({ method: 'GET', url: '/debug/api/players/p1' });
    assert.equal(detail.statusCode, 200);
    const d = detail.json();
    assert.equal(d.player.id, 'p1');
    assert.equal(d.visits.length, 2);
    assert.equal(d.memories.length, 1);
    assert.equal(d.memories[0].characterName, '小兔');
    assert.equal(d.memories[0].items[0].text, '小朋友叫朵朵');
    assert.equal(d.chats.length, 1);
    assert.equal(d.chats[0].turns.length, 2);

    const missing = await app.inject({ method: 'GET', url: '/debug/api/players/nope' });
    assert.equal(missing.statusCode, 404);
  } finally {
    await app.close();
  }
});

test('GET /debug/api/worlds 与 /debug/api/worlds/:id：列表计数摘要，详情带角色/造物/背包/会话', async () => {
  const app = await makeApp();
  try {
    const list = await app.inject({ method: 'GET', url: '/debug/api/worlds' });
    assert.equal(list.statusCode, 200);
    const ws = list.json().worlds;
    assert.equal(ws.length, 2);
    const w1 = ws.find((w: { id: string }) => w.id === 'w1');
    assert.equal(w1.characterCount, 2);
    assert.equal(w1.fairyCount, 1);
    assert.equal(w1.itemCount, 1);
    assert.equal(w1.visitCount, 2);
    assert.equal(w1.activeVisitCount, 1);
    // 钱包按玩家分：这里只有匿名玩家（addStamp 走 ANON_PLAYER）盖过章
    assert.equal(w1.wallets.length, 1);
    assert.equal(w1.wallets[0].playerId, ANON_PLAYER);
    assert.equal(w1.wallets[0].wallet.flowers, 3);
    assert.equal(w1.wallets[0].wallet.stampProgress, 1);
    assert.deepEqual(w1.locations, ['小池塘']);
    assert.equal(w1.sceneCount, 1, '列表摘要带场景数');

    const detail = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1' });
    assert.equal(detail.statusCode, 200);
    const d = detail.json();
    assert.equal(d.characters.length, 2);
    const c1 = d.characters.find((c: { id: string }) => c.id === 'c1');
    assert.equal(c1.memoryCount, 1);
    assert.equal(c1.chatTurnCount, 2);
    assert.equal(c1.sceneId, 'village', '角色摘要带场景（存量缺省归 village），供后台地图按场景归位');
    assert.equal(d.items.length, 1);
    assert.deepEqual(d.bags, [{ playerId: ANON_PLAYER, itemId: 'item1', count: 1 }], '背包计数透出');
    assert.equal(d.visits.length, 2);
    // 场景 + POI + 传送门的结构化数据都要透出（此前 debug 只给拍平的 locations 名字）
    assert.equal(d.scenes.length, 1);
    const village = d.scenes[0];
    assert.equal(village.sceneId, 'village');
    assert.equal(village.name, '村庄');
    assert.equal(village.terrainAsset, 'terrain-hash-abc');
    assert.equal(village.gridTiles, 75);
    assert.equal(village.pois.length, 1);
    assert.equal(village.pois[0].name, '小池塘');
    assert.deepEqual(village.pois[0].tile, [3, 4]);
    assert.equal(village.pois[0].trigger, 'pond');
    assert.deepEqual(village.pois[0].aliases, ['池塘', '水塘']);
    assert.equal(village.portals.length, 1);
    assert.equal(village.portals[0].toScene, 'forest');
    assert.deepEqual(village.portals[0].toTile, [1, 1]);

    const missing = await app.inject({ method: 'GET', url: '/debug/api/worlds/nope' });
    assert.equal(missing.statusCode, 404);
  } finally {
    await app.close();
  }
});

test('角色摘要 spriteAnimStatus 与玩家详情 spriteAnim：无立绘 none，有动画 ready', async () => {
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    // 无立绘 → none（角色表 + 玩家详情都兜底）
    const before = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1' });
    assert.equal(before.json().characters.find((c: { id: string }) => c.id === 'c1').spriteAnimStatus, 'none');
    const pBefore = await app.inject({ method: 'GET', url: '/debug/api/players/p1' });
    assert.equal(pBefore.json().spriteAnim.status, 'none');

    // 给角色/玩家挂上立绘并置动画 ready → 状态透出
    const meta = { cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60 };
    const sprite = store.putAsset({ bytes: Uint8Array.from([1]), mime: 'image/png' });
    const c1 = store.getCharacter('w1', 'c1')!;
    c1.appearance.spriteAsset = sprite;
    store.saveCharacter(c1);
    store.setSpriteAnimReady(sprite, 'atlasA', meta);
    const p1 = store.getPlayer('p1')!;
    store.upsertPlayer({ ...p1, spriteAsset: sprite });

    const after = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1' });
    assert.equal(after.json().characters.find((c: { id: string }) => c.id === 'c1').spriteAnimStatus, 'ready');
    const pAfter = await app.inject({ method: 'GET', url: '/debug/api/players/p1' });
    assert.equal(pAfter.json().spriteAnim.status, 'ready');
    assert.equal(pAfter.json().spriteAnim.animAsset, 'atlasA');
  } finally {
    await app.close();
  }
});

test('GET /debug/api/worlds/:id/characters/:cid：完整角色 + 记忆 + 对话 + 动画状态', async () => {
  const app = await makeApp();
  try {
    const res = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1/characters/c1' });
    assert.equal(res.statusCode, 200);
    const d = res.json();
    assert.equal(d.character.name, '小兔');
    assert.equal(d.character.personality, '活泼');
    assert.equal(d.memories.length, 1);
    assert.equal(d.chatTurns.length, 2);
    assert.equal(d.spriteAnim.status, 'none');

    const missing = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1/characters/nope' });
    assert.equal(missing.statusCode, 404);
  } finally {
    await app.close();
  }
});

test('/debug/api/*：配置 MALIANG_ADMIN_TOKEN 后无 token 拒绝、带 token 放行', async () => {
  const prev = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'secret-abc';
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    for (const url of ['/debug/api/overview', '/debug/api/players', '/debug/api/worlds', '/debug/api/worlds/w1', '/debug/api/worlds/w1/characters/c1']) {
      const denied = await app.inject({ method: 'GET', url });
      assert.equal(denied.statusCode, 403, `${url} 无 token 应拒绝`);
      const okQuery = await app.inject({ method: 'GET', url: `${url}?token=secret-abc` });
      assert.equal(okQuery.statusCode, 200, `${url} ?token= 应放行`);
      const okHeader = await app.inject({ method: 'GET', url, headers: { 'x-admin-token': 'secret-abc' } });
      assert.equal(okHeader.statusCode, 200, `${url} x-admin-token 应放行`);
    }
  } finally {
    await app.close();
    if (prev === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prev;
  }
});

test('GET /debug/api/worlds/:id/scenes/:sid/terrain-grid：解码矩阵 + palette 实体', async () => {
  const store = new WorldStore();
  seed(store);
  const t = emptyTerrain();
  t.palette = ['tree_puff_a'];
  t.itemRef[10 * REQUIRED_GRID + 10] = 1;
  t.types[0] = 2; t.depths[0] = 1; t.heights[5] = 3;
  store.setSceneTerrain('w1', 'village', encodeTerrain(t), 4);
  process.env.MALIANG_ADMIN_TOKEN = 'sesame'; // 门禁 token 在 buildServer 时捕获，必须先设
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const denied = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1/scenes/village/terrain-grid' });
    assert.equal(denied.statusCode, 403, 'admin token 门禁');

    const res = await app.inject({
      method: 'GET', url: '/debug/api/worlds/w1/scenes/village/terrain-grid',
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(res.statusCode, 200);
    const g = res.json() as { version: number; gridW: number; types: number[]; heights: number[]; depths: number[]; itemRef: number[]; palette: string[]; items: { id: string; name: string }[] };
    assert.equal(g.version, 4);
    assert.equal(g.gridW, REQUIRED_GRID);
    assert.equal(g.types[0], 2);
    assert.equal(g.depths[0], 1);
    assert.equal(g.heights[5], 3);
    assert.equal(g.itemRef[10 * REQUIRED_GRID + 10], 1);
    assert.deepEqual(g.palette, ['tree_puff_a']);
    assert.equal(g.items[0]!.name, '蓬蓬树·甲', 'palette 实体定义已解引用');

    const missing = await app.inject({
      method: 'GET', url: '/debug/api/worlds/w1/scenes/ghost/terrain-grid',
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(missing.statusCode, 404);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});

test('GET /debug/api/items：内置 def + 各世界造物聚合，带 iconHash / sceneRefs', async () => {
  const store = new WorldStore();
  seed(store); // w1 有造物 item1；无 terrain
  // 给 village 铺一张引用内置 tree_puff_a 的矩阵 → 该 id 的 sceneRefs 应为 1
  const t = emptyTerrain();
  t.palette = ['tree_puff_a'];
  t.itemRef[10 * REQUIRED_GRID + 10] = 1;
  store.setSceneTerrain('w1', 'village', encodeTerrain(t), 1);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const res = await app.inject({ method: 'GET', url: '/debug/api/items' });
    assert.equal(res.statusCode, 200);
    const body = res.json() as {
      builtin: { id: string; worldId: null; iconHash: string; sceneRefs: number }[];
      creations: { id: string; worldId: string; iconHash: string; sceneRefs: number }[];
      counts: { builtin: number; creations: number; withIcon: number };
    };
    assert.equal(body.builtin.length, BUILTIN_ITEMS.length, '内置 def 全部透出');
    assert.equal(body.counts.builtin, BUILTIN_ITEMS.length);
    const tree = body.builtin.find((i) => i.id === 'tree_puff_a');
    assert.ok(tree, '内置 tree_puff_a 在列表里');
    assert.equal(tree!.worldId, null, '内置 def worldId 为 null');
    assert.equal(tree!.sceneRefs, 1, '被 village 矩阵引用 → sceneRefs=1');
    assert.equal(tree!.iconHash, '', '未上传缩略图 → iconHash 空');
    // 造物 item1（w1）在 creations 里
    assert.equal(body.creations.length, 1);
    assert.equal(body.creations[0]!.id, 'item1');
    assert.equal(body.creations[0]!.worldId, 'w1');
    assert.equal(body.counts.creations, 1);
    assert.equal(body.counts.withIcon, 0);
  } finally {
    await app.close();
  }
});

test('POST /admin/item-icon/:id：客户端上传缩略图 → 入库 + 绑定 + /debug/api/items 可见', async () => {
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  // 最小合法 PNG 签名字节（sniffImageMime 认前两字节 0x89 0x50）
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
  const pngBase64 = Buffer.from(png).toString('base64');
  try {
    // 内置 id 上传
    const up = await app.inject({
      method: 'POST', url: '/admin/item-icon/tree_puff_a',
      payload: { pngBase64 },
    });
    assert.equal(up.statusCode, 200);
    const { itemId, iconAsset } = up.json() as { itemId: string; iconAsset: string };
    assert.equal(itemId, 'tree_puff_a');
    assert.ok(iconAsset.length > 0, '返回内容寻址 hash');

    // 资产可取回，字节一致
    const asset = await app.inject({ method: 'GET', url: `/assets/${iconAsset}` });
    assert.equal(asset.statusCode, 200);
    assert.deepEqual(new Uint8Array(asset.rawPayload), png);

    // /debug/api/items 里该 id 的 iconHash 已回填
    const items = await app.inject({ method: 'GET', url: '/debug/api/items' });
    const body = items.json() as { builtin: { id: string; iconHash: string }[]; counts: { withIcon: number } };
    const tree = body.builtin.find((i) => i.id === 'tree_puff_a');
    assert.equal(tree!.iconHash, iconAsset, 'iconHash 指向刚上传的资产');
    assert.equal(body.counts.withIcon, 1);

    // 造物 id 也可上传
    const upc = await app.inject({ method: 'POST', url: '/admin/item-icon/item1', payload: { pngBase64 } });
    assert.equal(upc.statusCode, 200);

    // 未知 id → 404
    const unknown = await app.inject({ method: 'POST', url: '/admin/item-icon/nope-xyz', payload: { pngBase64 } });
    assert.equal(unknown.statusCode, 404);

    // 缺 pngBase64 → 400
    const empty = await app.inject({ method: 'POST', url: '/admin/item-icon/tree_puff_a', payload: {} });
    assert.equal(empty.statusCode, 400);
  } finally {
    await app.close();
  }
});

test('GET /item-icons：公开只读映射（无 token 放行），admin GET 仍门禁', async () => {
  const prev = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'sesame'; // 门禁 token 在 buildServer 时捕获，必须先设
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  const pngBase64 = Buffer.from(png).toString('base64');
  try {
    // 先经 admin 通道上传一张（需 token）
    const up = await app.inject({
      method: 'POST', url: '/admin/item-icon/tree_puff_a',
      headers: { 'x-admin-token': 'sesame' }, payload: { pngBase64 },
    });
    assert.equal(up.statusCode, 200);
    const { iconAsset } = up.json() as { iconAsset: string };

    // 公开 GET /item-icons：无 token 也放行，映射含刚上传的 id→hash
    const pub = await app.inject({ method: 'GET', url: '/item-icons' });
    assert.equal(pub.statusCode, 200, '公开读半边无 token 放行');
    const icons = (pub.json() as { icons: Record<string, string> }).icons;
    assert.equal(icons['tree_puff_a'], iconAsset, '映射回刚上传的资产 hash');

    // 对照：admin GET /admin/item-icons 无 token 仍拒绝（写入通道保持门禁）
    const adminDenied = await app.inject({ method: 'GET', url: '/admin/item-icons' });
    assert.equal(adminDenied.statusCode, 403, 'admin 映射端点仍门禁');
  } finally {
    if (prev === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prev;
    await app.close();
  }
});

test('POST /admin/item-icon/:id：配置 token 后无 token 拒绝、带 token 放行', async () => {
  const prev = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  const pngBase64 = Buffer.from(png).toString('base64');
  try {
    const denied = await app.inject({ method: 'POST', url: '/admin/item-icon/tree_puff_a', payload: { pngBase64 } });
    assert.equal(denied.statusCode, 403, 'admin token 门禁');
    const ok = await app.inject({
      method: 'POST', url: '/admin/item-icon/tree_puff_a',
      headers: { 'x-admin-token': 'sesame' }, payload: { pngBase64 },
    });
    assert.equal(ok.statusCode, 200);
  } finally {
    if (prev === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prev;
    await app.close();
  }
});
