import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { buildServer } from '../src/server.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { editSceneTerrain, applyTileEdits, TerrainEditError } from '../src/terrain_edit.ts';
import {
  encodeTerrain, decodeTerrain, emptyTerrain, argYawDeg,
  T_GRASS, T_PATH, T_WATER, REQUIRED_GRID,
} from '../src/terrain.ts';
import { resolveBuiltin } from '../src/items.ts';
import { DEFAULT_SCENE, type ItemDef } from '../src/types.ts';
import type { WorldHub } from '../src/world_hub.ts';

const G = REQUIRED_GRID;
const at = (x: number, y: number) => y * G + x;

/** 记录广播的假 hub。 */
function fakeHub(): { hub: WorldHub; sent: Record<string, unknown>[] } {
  const sent: Record<string, unknown>[] = [];
  return { hub: { broadcast: (_w: string, msg: Record<string, unknown>) => { sent.push(msg); return 1; } } as unknown as WorldHub, sent };
}

/** 建好 world + 有矩阵的场景。 */
function storeWithScene(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  s.upsertScene({
    worldId: 'w1', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: G, terrainVersion: 1, pois: [], portals: [],
  });
  const t = emptyTerrain();
  t.palette = ['tree_puff_a'];
  t.itemRef[at(10, 10)] = 1;
  s.setSceneTerrain('w1', DEFAULT_SCENE, encodeTerrain(t), 1);
  return s;
}

// ── applyTileEdits 纯函数 ────────────────────────────────────────────────

test('applyTileEdits：挖水默认浅水 1，填掉水自动清水深', () => {
  const t = emptyTerrain();
  const r = applyTileEdits(t, [{ x: 5, y: 5, t: T_WATER }], resolveBuiltin);
  assert.equal(t.types[at(5, 5)], T_WATER);
  assert.equal(t.depths[at(5, 5)], 1, '默认浅水');
  assert.deepEqual(r.applied[0], { x: 5, y: 5, t: T_WATER, d: 1 });

  applyTileEdits(t, [{ x: 5, y: 5, t: T_GRASS }], resolveBuiltin);
  assert.equal(t.depths[at(5, 5)], 0, '填草清水深');
});

test('applyTileEdits：放物品首用扩 palette，重复引用不扩', () => {
  const t = emptyTerrain();
  const r1 = applyTileEdits(t, [{ x: 3, y: 3, item: { id: 'tree_puff_a', yawDeg: 90 } }], resolveBuiltin);
  assert.deepEqual(r1.paletteAppend, [{ index: 1, itemId: 'tree_puff_a' }]);
  assert.equal(t.itemRef[at(3, 3)], 1);
  assert.equal(argYawDeg(t.itemArg[at(3, 3)]!), 90);

  const r2 = applyTileEdits(t, [{ x: 4, y: 4, item: { id: 'tree_puff_a' } }], resolveBuiltin);
  assert.deepEqual(r2.paletteAppend, [], '已在 palette，不再扩');
  assert.equal(t.itemRef[at(4, 4)], 1);
});

test('applyTileEdits：移除物品（item=null）', () => {
  const t = emptyTerrain();
  applyTileEdits(t, [{ x: 3, y: 3, item: { id: 'bush_puff' } }], resolveBuiltin);
  const r = applyTileEdits(t, [{ x: 3, y: 3, item: null }], resolveBuiltin);
  assert.equal(t.itemRef[at(3, 3)], 0);
  assert.deepEqual(r.applied[0], { x: 3, y: 3, item: null });
});

test('applyTileEdits：拒绝——越界/未知实体/非水给水深/物品占地冲突/edits 空', () => {
  const t = emptyTerrain();
  assert.throws(() => applyTileEdits(t, [{ x: -1, y: 0, h: 1 }], resolveBuiltin), /越界/);
  assert.throws(() => applyTileEdits(t, [{ x: 90, y: 0, h: 1 }], resolveBuiltin), /越界/);
  assert.throws(() => applyTileEdits(t, [{ x: 1, y: 1, item: { id: 'ghost' } }], resolveBuiltin), /不存在/);
  assert.throws(() => applyTileEdits(t, [{ x: 1, y: 1, d: 2 }], resolveBuiltin), /水深/);
  assert.throws(() => applyTileEdits(t, [], resolveBuiltin), /为空/);

  // 房子 footprint 压树 → 语义复检拒绝
  applyTileEdits(t, [{ x: 10, y: 10, item: { id: 'tree_puff_a' } }], resolveBuiltin);
  assert.throws(
    () => applyTileEdits(t, [{ x: 11, y: 10, item: { id: 'house_0' } }], resolveBuiltin),
    /冲突/,
  );
});

test('applyTileEdits：挖水淹到物品占地 → 拒绝（整图复检兜底）', () => {
  const t = emptyTerrain();
  applyTileEdits(t, [{ x: 20, y: 20, item: { id: 'house_0' } }], resolveBuiltin);
  assert.throws(
    () => applyTileEdits(t, [{ x: 19, y: 19, t: T_WATER }], resolveBuiltin), // footprint 角
    /水面/,
  );
});

// ── editSceneTerrain 编排（持久化 + version + 广播）─────────────────────

test('editSceneTerrain：version 递增、库里字节可读回、terrain_patch 广播', () => {
  const s = storeWithScene();
  const { hub, sent } = fakeHub();

  const r = editSceneTerrain(s, hub, 'w1', DEFAULT_SCENE, [
    { x: 30, y: 30, t: T_PATH },
    { x: 31, y: 30, item: { id: 'bush_puff', yawDeg: 180 } },
  ]);
  assert.equal(r.version, 2);

  const rec = s.getSceneTerrain('w1', DEFAULT_SCENE)!;
  assert.equal(rec.version, 2);
  const t = decodeTerrain(rec.bytes);
  assert.equal(t.types[at(30, 30)], T_PATH);
  assert.equal(t.palette[t.itemRef[at(31, 30)]! - 1], 'bush_puff');

  assert.equal(sent.length, 1);
  const patch = sent[0]!;
  assert.equal(patch.type, 'terrain_patch');
  assert.equal(patch.version, 2);
  assert.equal((patch.edits as unknown[]).length, 2);
  assert.deepEqual(patch.paletteAppend, [{ index: 2, itemId: 'bush_puff' }]);
  assert.equal((patch.items as ItemDef[])[0]!.id, 'bush_puff', '新引用实体定义随 patch 带上');
});

test('editSceneTerrain：校验失败库不落一字节、不广播、version 不动', () => {
  const s = storeWithScene();
  const { hub, sent } = fakeHub();
  const before = s.getSceneTerrain('w1', DEFAULT_SCENE)!;

  assert.throws(
    () => editSceneTerrain(s, hub, 'w1', DEFAULT_SCENE, [
      { x: 40, y: 40, item: { id: 'windmill' } },
      { x: 41, y: 40, item: { id: 'house_0' } }, // 与风车 footprint 冲突
    ]),
    TerrainEditError,
  );
  const after = s.getSceneTerrain('w1', DEFAULT_SCENE)!;
  assert.equal(after.version, before.version);
  assert.deepEqual(after.bytes, before.bytes);
  assert.equal(sent.length, 0);
});

test('editSceneTerrain：造物实体（items 表）可挂 tile', () => {
  const s = storeWithScene();
  s.upsertItem({
    id: 'flower_xm', worldId: 'w1', name: '小明的花', renderRef: 'sdf_inline',
    spec: { name: 'f' } as ItemDef['spec'], footprintW: 1, footprintH: 1,
    blocking: true, pathOk: false, wander: 0,
  });
  const { hub, sent } = fakeHub();
  const r = editSceneTerrain(s, hub, 'w1', DEFAULT_SCENE, [{ x: 8, y: 8, item: { id: 'flower_xm' } }]);
  assert.equal(r.items[0]!.name, '小明的花');
  assert.equal((sent[0]!.items as ItemDef[])[0]!.renderRef, 'sdf_inline');
});

test('editSceneTerrain：场景无矩阵 → 报错', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  assert.throws(() => editSceneTerrain(s, undefined, 'w1', 'nope', [{ x: 0, y: 0, h: 1 }]), /无地形矩阵/);
});

// ── HTTP 端点 ────────────────────────────────────────────────────────────

test('GET /worlds/:wid/scenes/:sid/terrain：blob 原样 + 版本头；POST tile-edits 走通', async (t) => {
  const store = storeWithScene();
  const a = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => a.close());

  const got = await a.inject({ method: 'GET', url: `/worlds/w1/scenes/${DEFAULT_SCENE}/terrain` });
  assert.equal(got.statusCode, 200);
  assert.equal(got.headers['x-terrain-version'], '1');
  assert.deepEqual(new Uint8Array(got.rawPayload), store.getSceneTerrain('w1', DEFAULT_SCENE)!.bytes);

  assert.equal((await a.inject({ method: 'GET', url: '/worlds/w1/scenes/ghost/terrain' })).statusCode, 404);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const noToken = await a.inject({ method: 'POST', url: `/admin/worlds/w1/scenes/${DEFAULT_SCENE}/tile-edits` });
    assert.equal(noToken.statusCode, 403);

    const ok = await a.inject({
      method: 'POST', url: `/admin/worlds/w1/scenes/${DEFAULT_SCENE}/tile-edits`,
      headers: { 'x-admin-token': 'sesame' },
      payload: { edits: [{ x: 50, y: 50, t: T_WATER }] },
    });
    assert.equal(ok.statusCode, 200);
    assert.equal((ok.json() as { version: number }).version, 2);

    const after = await a.inject({ method: 'GET', url: `/worlds/w1/scenes/${DEFAULT_SCENE}/terrain` });
    assert.equal(after.headers['x-terrain-version'], '2');

    const bad = await a.inject({
      method: 'POST', url: `/admin/worlds/w1/scenes/${DEFAULT_SCENE}/tile-edits`,
      headers: { 'x-admin-token': 'sesame' },
      payload: { edits: [{ x: 1, y: 1, item: { id: 'ghost' } }] },
    });
    assert.equal(bad.statusCode, 400);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('GET /worlds/:id：带 items（内置 + 世界造物）', async (t) => {
  const store = storeWithScene();
  store.upsertItem({
    id: 'flower_xm', worldId: 'w1', name: '小明的花', renderRef: 'sdf_inline',
    footprintW: 1, footprintH: 1, blocking: true, pathOk: false, wander: 0,
  });
  const a = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => a.close());

  const res = await a.inject({ method: 'GET', url: '/worlds/w1' });
  const items = (res.json() as { items: ItemDef[] }).items;
  assert.ok(items.length >= 23, '内置 22 + 造物 1');
  assert.ok(items.some((d) => d.id === 'tree_puff_a'));
  assert.ok(items.some((d) => d.id === 'flower_xm'));
});
