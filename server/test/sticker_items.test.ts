// 贴纸物品：tile 边缘挂载 + 小红花商店（sticker-items P1，docs/sticker-items-design.md）。
// 覆盖：edge 编辑通路（挂/清/side 非法/mount 错位双向拒绝/占用位图不受影响）、
// item_place/pickup 的 edgeSide 分流（含内置贴纸允许拾回的例外）、sticker_buy 扣花进包。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { applyTileEdits, TerrainEditError } from '../src/terrain_edit.ts';
import { buildStaticOccupancy, resolveBuiltin, validateTerrainItems } from '../src/items.ts';
import { emptyTerrain, encodeTerrain, decodeTerrain, REQUIRED_GRID } from '../src/terrain.ts';
import { ANON_PLAYER, DEFAULT_SCENE, INITIAL_FLOWERS } from '../src/types.ts';

const G = REQUIRED_GRID;
const at = (x: number, y: number) => y * G + x;

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function ws(store: WorldStore, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  await handleWsMessage(
    sock, JSON.stringify(msg),
    createMockAdapters(), store, new RateLimiter(100, 100), 'test', newVoiceSession(),
  );
  return sock.sent;
}

function seedScene(store: WorldStore): void {
  store.createWorld('default');
  store.upsertScene({
    worldId: 'default', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: G, terrainVersion: 1, pois: [], portals: [],
  });
  store.setSceneTerrain('default', DEFAULT_SCENE, encodeTerrain(emptyTerrain()), 1);
}

function terrainOf(store: WorldStore) {
  const rec = store.getSceneTerrain('default', DEFAULT_SCENE)!;
  return { t: decodeTerrain(rec.bytes), version: rec.version };
}

// ---- applyTileEdits：edge 编辑通路（纯函数层） ----

test('applyTileEdits: 挂贴纸到边缘 → 平面写 ref + applied.edge + paletteAppend；清除 → ref 0', () => {
  const t = emptyTerrain();
  const { applied, paletteAppend } = applyTileEdits(
    t, [{ x: 5, y: 6, edge: { side: 2, id: 'sticker_sun' } }], resolveBuiltin,
  );
  assert.deepEqual(paletteAppend, [{ index: 1, itemId: 'sticker_sun' }]);
  assert.deepEqual(applied[0], { x: 5, y: 6, edge: [2, 1] });
  assert.equal(t.edges[2]![at(5, 6)], 1, '南边缘平面写入 palette 索引');
  assert.equal(t.itemRef[at(5, 6)], 0, 'itemRef 不受牵连');

  const { applied: cleared } = applyTileEdits(t, [{ x: 5, y: 6, edge: { side: 2, id: null } }], resolveBuiltin);
  assert.deepEqual(cleared[0], { x: 5, y: 6, edge: [2, 0] });
  assert.equal(t.edges[2]![at(5, 6)], 0, '清除后回 0');
});

test('applyTileEdits: side 非法 / 实体不存在 / mount 错位（tile 物挂边）→ TerrainEditError', () => {
  assert.throws(
    () => applyTileEdits(emptyTerrain(), [{ x: 1, y: 1, edge: { side: 4, id: 'sticker_sun' } }], resolveBuiltin),
    TerrainEditError,
  );
  assert.throws(
    () => applyTileEdits(emptyTerrain(), [{ x: 1, y: 1, edge: { side: 0, id: 'no_such' } }], resolveBuiltin),
    TerrainEditError,
  );
  assert.throws(
    () => applyTileEdits(emptyTerrain(), [{ x: 1, y: 1, edge: { side: 0, id: 'tree_puff_a' } }], resolveBuiltin),
    /不能挂边缘/,
  );
});

test('applyTileEdits: 贴纸挂 tile 正上方（item 路径）→ 整图复检拒绝', () => {
  assert.throws(
    () => applyTileEdits(emptyTerrain(), [{ x: 1, y: 1, item: { id: 'sticker_sun' } }], resolveBuiltin),
    /挂在 itemRef/,
  );
});

test('edge 贴纸不进占用位图；validateTerrainItems 对合法边缘矩阵放行', () => {
  const t = emptyTerrain();
  applyTileEdits(t, [{ x: 3, y: 3, edge: { side: 0, id: 'sticker_star' } }], resolveBuiltin);
  validateTerrainItems(t, resolveBuiltin); // 不抛
  const occ = buildStaticOccupancy(t, resolveBuiltin);
  assert.equal(occ[at(3, 3)], 0, '贴纸所在 tile 不占用');
});

// ---- WS：item_place / item_pickup 的 edgeSide 分流 ----

test('item_place(edgeSide): 背包扣一份 + 边缘挂上 + version+1；同边已占 → error 不动账', async () => {
  const store = new WorldStore();
  seedScene(store);
  store.bagAdd('default', ANON_PLAYER, 'sticker_sun');
  store.bagAdd('default', ANON_PLAYER, 'sticker_sun');

  const sent = await ws(store, { type: 'item_place', worldId: 'default', itemId: 'sticker_sun', tileX: 5, tileY: 6, edgeSide: 1 });
  assert.equal(sent[0]!.type, 'bag_update');
  assert.deepEqual(sent[0]!.bag, { sticker_sun: 1 });
  const { t, version } = terrainOf(store);
  assert.equal(version, 2);
  assert.equal(t.palette[t.edges[1]![at(5, 6)]! - 1], 'sticker_sun', '东边缘挂上贴纸');

  const again = await ws(store, { type: 'item_place', worldId: 'default', itemId: 'sticker_sun', tileX: 5, tileY: 6, edgeSide: 1 });
  assert.equal(again[0]!.type, 'error');
  assert.equal(again[0]!.error, 'edge occupied');
  assert.equal(terrainOf(store).version, 2, '失败不动矩阵');
  assert.deepEqual(store.getBag('default', ANON_PLAYER), { sticker_sun: 1 }, '失败不扣包');
});

test('item_place(edgeSide): 同 tile 另一条边不冲突；tile 正上方摆放照旧不受贴纸影响', async () => {
  const store = new WorldStore();
  seedScene(store);
  store.bagAdd('default', ANON_PLAYER, 'sticker_sun');
  store.bagAdd('default', ANON_PLAYER, 'sticker_flower');

  const a = await ws(store, { type: 'item_place', worldId: 'default', itemId: 'sticker_sun', tileX: 5, tileY: 6, edgeSide: 0 });
  assert.equal(a[0]!.type, 'bag_update');
  const b = await ws(store, { type: 'item_place', worldId: 'default', itemId: 'sticker_flower', tileX: 5, tileY: 6, edgeSide: 2 });
  assert.equal(b[0]!.type, 'bag_update', '同 tile 南北两条边各挂各的');
  const { t } = terrainOf(store);
  assert.notEqual(t.edges[0]![at(5, 6)], 0);
  assert.notEqual(t.edges[2]![at(5, 6)], 0);
});

test('item_pickup(edgeSide): 内置贴纸允许拾回（mount edge 例外）；空边 → error', async () => {
  const store = new WorldStore();
  seedScene(store);
  store.bagAdd('default', ANON_PLAYER, 'sticker_sun');
  await ws(store, { type: 'item_place', worldId: 'default', itemId: 'sticker_sun', tileX: 5, tileY: 6, edgeSide: 3 });

  const sent = await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 5, tileY: 6, edgeSide: 3 });
  assert.equal(sent[0]!.type, 'bag_update');
  assert.deepEqual(sent[0]!.bag, { sticker_sun: 1 }, '拾回进背包');
  assert.equal(terrainOf(store).t.edges[3]![at(5, 6)], 0, '西边缘清空');

  const empty = await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 5, tileY: 6, edgeSide: 3 });
  assert.equal(empty[0]!.type, 'error');
  assert.equal(empty[0]!.error, 'no item on edge');
});

test('item_pickup: mount tile 的内置物照旧拒拾（规则缩小不放松）', async () => {
  const store = new WorldStore();
  store.createWorld('default');
  store.upsertScene({
    worldId: 'default', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: G, terrainVersion: 1, pois: [], portals: [],
  });
  const t = emptyTerrain();
  t.palette = ['tree_puff_a'];
  t.itemRef[at(10, 10)] = 1;
  store.setSceneTerrain('default', DEFAULT_SCENE, encodeTerrain(t), 1);

  const sent = await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 10, tileY: 10 });
  assert.equal(sent[0]!.type, 'error');
  assert.equal(sent[0]!.error, 'builtin item not pickable');
});

// ---- WS：sticker_buy 小红花商店 ----

test('sticker_buy: 扣 1 朵进背包，回 sticker_bought 带 bag+wallet；花光 → sticker_denied', async () => {
  const store = new WorldStore();
  seedScene(store);

  for (let i = 0; i < INITIAL_FLOWERS; i++) {
    const sent = await ws(store, { type: 'sticker_buy', worldId: 'default', itemId: 'sticker_heart' });
    assert.equal(sent[0]!.type, 'sticker_bought');
    assert.equal((sent[0]!.wallet as { flowers: number }).flowers, INITIAL_FLOWERS - 1 - i);
  }
  assert.deepEqual(store.getBag('default', ANON_PLAYER), { sticker_heart: INITIAL_FLOWERS });

  const broke = await ws(store, { type: 'sticker_buy', worldId: 'default', itemId: 'sticker_heart' });
  assert.equal(broke[0]!.type, 'sticker_denied');
  assert.equal(broke[0]!.reason, 'no_flowers');
  assert.deepEqual(store.getBag('default', ANON_PLAYER), { sticker_heart: INITIAL_FLOWERS }, '拒买不进包');
});

test('sticker_buy: 非贴纸（内置树/未知 id）→ error 不扣花', async () => {
  const store = new WorldStore();
  seedScene(store);
  for (const bad of ['tree_puff_a', 'no_such']) {
    const sent = await ws(store, { type: 'sticker_buy', worldId: 'default', itemId: bad });
    assert.equal(sent[0]!.type, 'error');
  }
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, INITIAL_FLOWERS, '一朵没扣');
});
