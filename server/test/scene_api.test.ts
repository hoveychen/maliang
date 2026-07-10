import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { encodeTerrain, REQUIRED_GRID, DEFAULT_TILE_SIZE, T_WATER, type Terrain } from '../src/terrain.ts';
import { DEFAULT_SCENE } from '../src/types.ts';

const N = REQUIRED_GRID * REQUIRED_GRID;

function terrainB64(mut?: (t: Terrain) => void): string {
  const t: Terrain = {
    gridW: REQUIRED_GRID, gridH: REQUIRED_GRID, tileSize: DEFAULT_TILE_SIZE,
    types: new Uint8Array(N), heights: new Uint8Array(N), depths: new Uint8Array(N),
  };
  t.types[0] = T_WATER; t.depths[0] = 2;
  mut?.(t);
  return Buffer.from(encodeTerrain(t)).toString('base64');
}

async function app() {
  const store = new WorldStore();
  store.createWorld('w1');
  const a = await buildServer({ adapters: createMockAdapters(), store });
  return { a, store };
}

const POIS = [{ tile: [24, 24] as [number, number], radius: 20, trigger: 'poi_pond', name: '池塘', aliases: ['湖'] }];

test('POST /admin/scenes：token 门禁', async (t) => {
  const { a } = await app();
  t.after(() => a.close());
  delete process.env.MALIANG_ADMIN_TOKEN;
  assert.equal((await a.inject({ method: 'POST', url: '/admin/scenes' })).statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const bad = await a.inject({ method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'nope' } });
    assert.equal(bad.statusCode, 403);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('POST /admin/scenes：入库后 GET /worlds/:id 带上 scenes，地形可从 /assets 取回', async (t) => {
  const { a, store } = await app();
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const res = await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', sceneId: DEFAULT_SCENE, name: '村庄', terrainBase64: terrainB64(), pois: POIS },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { scene: { terrainAsset: string; gridTiles: number }; bytes: number };
    assert.equal(body.bytes, 16886);
    assert.equal(body.scene.gridTiles, REQUIRED_GRID);
    assert.ok(body.scene.terrainAsset.length > 0);

    // 世界返回体带 scenes
    const world = await a.inject({ method: 'GET', url: '/worlds/w1' });
    const ws = (world.json() as { scenes: { sceneId: string; terrainAsset: string; pois: unknown[] }[] }).scenes;
    assert.equal(ws.length, 1);
    assert.equal(ws[0]!.sceneId, DEFAULT_SCENE);
    assert.equal(ws[0]!.terrainAsset, body.scene.terrainAsset);
    assert.equal(ws[0]!.pois.length, 1);

    // 地形二进制经 /assets/:hash 原样取回
    const asset = await a.inject({ method: 'GET', url: `/assets/${body.scene.terrainAsset}` });
    assert.equal(asset.statusCode, 200);
    assert.equal(asset.headers['content-type'], 'application/octet-stream');
    assert.equal(asset.rawPayload.length, 16886);
    assert.deepEqual(new Uint8Array(asset.rawPayload), new Uint8Array(Buffer.from(terrainB64(), 'base64')));

    assert.equal(store.getScene('w1', DEFAULT_SCENE)!.pois[0]!.name, '池塘');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('POST /admin/scenes：同一份地形重复入库 → hash 不变（客户端不重下）', async (t) => {
  const { a } = await app();
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const post = () => a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', terrainBase64: terrainB64() },
    });
    const h1 = ((await post()).json() as { scene: { terrainAsset: string } }).scene.terrainAsset;
    const h2 = ((await post()).json() as { scene: { terrainAsset: string } }).scene.terrainAsset;
    assert.equal(h1, h2, '内容寻址：同字节同 hash');

    // 地形改一格 → hash 必须变
    const h3 = ((await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', terrainBase64: terrainB64((t2) => { t2.heights[500] = 3; }) },
    })).json() as { scene: { terrainAsset: string } }).scene.terrainAsset;
    assert.notEqual(h3, h1, '地形变了 hash 就得变——这是版本协商的全部机制');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('POST /admin/scenes：坏地形当场拒收（400），不入库', async (t) => {
  const { a, store } = await app();
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const buf = Buffer.from(terrainB64(), 'base64');
    buf[0] = 'X'.charCodeAt(0); // 砸掉 magic
    const res = await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', terrainBase64: buf.toString('base64') },
    });
    assert.equal(res.statusCode, 400);
    assert.match((res.json() as { error: string }).error, /magic/);
    assert.equal(store.listScenes('w1').length, 0, '坏地形没留下任何场景行');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('POST /admin/scenes：缺 worldId / 世界不存在 / 缺地形', async (t) => {
  const { a } = await app();
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const H = { 'x-admin-token': 'sesame' };
  try {
    assert.equal((await a.inject({ method: 'POST', url: '/admin/scenes', headers: H, payload: {} })).statusCode, 400);
    assert.equal((await a.inject({ method: 'POST', url: '/admin/scenes', headers: H, payload: { worldId: 'w1' } })).statusCode, 400);
    assert.equal((await a.inject({
      method: 'POST', url: '/admin/scenes', headers: H, payload: { worldId: 'nope', terrainBase64: terrainB64() },
    })).statusCode, 404);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('GET /worlds/:id：还没入库场景时 scenes 为空数组（客户端据此回退本地生成）', async (t) => {
  const { a } = await app();
  t.after(() => a.close());
  const world = await a.inject({ method: 'GET', url: '/worlds/w1' });
  assert.deepEqual((world.json() as { scenes: unknown[] }).scenes, []);
});

// ── POI 权威方向：服务端 scenes.pois 优先于客户端上报 ────────────────────

function withScene(pois: { name: string }[]): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  s.upsertScene({
    worldId: 'w1', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h', gridTiles: REQUIRED_GRID,
    pois: pois.map((p) => ({ tile: [1, 1] as [number, number], radius: 5, trigger: 't', name: p.name, aliases: [] })),
    portals: [],
  });
  return s;
}

test('getLocations：POI 入库后以服务端为准，忽略客户端上报', () => {
  const s = withScene([{ name: '池塘' }, { name: '大山' }]);
  s.setLocations('w1', ['客户端瞎报的地名']);
  assert.deepEqual(s.getLocations('w1'), ['池塘', '大山']);
});

test('getLocations：POI 未入库时回退到客户端上报（旧环境不退化）', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.setLocations('w1', ['池塘', '风车']);
  assert.deepEqual(s.getLocations('w1'), ['池塘', '风车']);
});

test('getLocations：跨场景摊平并去重', () => {
  const s = withScene([{ name: '池塘' }, { name: '池塘' }]);
  s.upsertScene({
    worldId: 'w1', sceneId: 'forest', name: '森林', terrainAsset: 'h2', gridTiles: REQUIRED_GRID,
    pois: [{ tile: [2, 2], radius: 5, trigger: 't2', name: '树屋', aliases: [] }], portals: [],
  });
  assert.deepEqual(s.getLocations('w1').sort(), ['树屋', '池塘']);
});

test('getLocations：空名字的 POI 不进地名表', () => {
  const s = withScene([{ name: '' }, { name: '池塘' }]);
  assert.deepEqual(s.getLocations('w1'), ['池塘']);
});
