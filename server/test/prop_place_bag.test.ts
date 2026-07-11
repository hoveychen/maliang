// 万物皆物品的拾摆链路（scene-items P5b，docs/scene-item-refactor-design.md §3.5）：
// 摆放 = 背包扣一份 + tile 挂实体引用；拾起 = tile 清引用 + 背包加一份；
// 内置物品（树/石/建筑）拒拾；任何失败回 error 不动账。
// 另测存量 props 行的启动迁移：placed 进矩阵、冲突/bagged 收匿名背包、幂等。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { createPropAsync, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { emptyTerrain, encodeTerrain, decodeTerrain, REQUIRED_GRID } from '../src/terrain.ts';
import { ANON_PLAYER, DEFAULT_SCENE } from '../src/types.ts';

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

/** default 世界 + 有矩阵的 village 场景（(10,10) 站着一棵内置树，供拒拾/冲突用例）。 */
function seedScene(store: WorldStore): void {
  store.createWorld('default');
  store.upsertScene({
    worldId: 'default', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: G, terrainVersion: 1, pois: [], portals: [],
  });
  const t = emptyTerrain();
  t.palette = ['tree_puff_a'];
  t.itemRef[at(10, 10)] = 1;
  store.setSceneTerrain('default', DEFAULT_SCENE, encodeTerrain(t), 1);
}

/** 语音造一个物件（入 items 表 + 匿名背包），返回实体 id。 */
async function seededItem(store: WorldStore): Promise<string> {
  const sock = fakeSocket();
  await createPropAsync(sock, 'default', ANON_PLAYER, '造一个小风车', createMockAdapters(), store);
  const created = sock.sent.find((m) => m.type === 'item_created')!;
  return (created.item as { id: string }).id;
}

function terrainOf(store: WorldStore) {
  const rec = store.getSceneTerrain('default', DEFAULT_SCENE)!;
  return { t: decodeTerrain(rec.bytes), version: rec.version };
}

test('item_place: 背包扣一份 + tile 挂引用 + bag_update；不在背包 → error 不动账', async () => {
  const store = new WorldStore();
  seedScene(store);
  const itemId = await seededItem(store);
  assert.deepEqual(store.getBag('default', ANON_PLAYER), { [itemId]: 1 }, '造好即在背包');

  const sent = await ws(store, { type: 'item_place', worldId: 'default', itemId, tileX: 5, tileY: 6, yawDeg: 90 });
  assert.equal(sent[0]!.type, 'bag_update');
  assert.deepEqual(sent[0]!.bag, {}, '摆出后背包扣空');
  const { t, version } = terrainOf(store);
  assert.equal(version, 2, '摆放 = tile 编辑，version+1');
  assert.equal(t.palette[t.itemRef[at(5, 6)]! - 1], itemId, 'tile 挂上实体引用');

  // 背包已空：再摆 → error，矩阵不动
  const again = await ws(store, { type: 'item_place', worldId: 'default', itemId, tileX: 7, tileY: 7 });
  assert.equal(again[0]!.type, 'error');
  assert.equal(terrainOf(store).version, 2, '失败不动矩阵');
});

test('item_place: 占地冲突 → error 不动账（背包不扣、version 不动）', async () => {
  const store = new WorldStore();
  seedScene(store);
  const itemId = await seededItem(store);

  const sent = await ws(store, { type: 'item_place', worldId: 'default', itemId, tileX: 10, tileY: 10 });
  assert.equal(sent[0]!.type, 'error', '(10,10) 已被内置树占住');
  assert.deepEqual(store.getBag('default', ANON_PLAYER), { [itemId]: 1 }, '背包一份不少');
  assert.equal(terrainOf(store).version, 1, '矩阵没动');
});

test('item_pickup: 造物可拾（清引用+背包加一份）；内置拒拾；空 tile → error', async () => {
  const store = new WorldStore();
  seedScene(store);
  const itemId = await seededItem(store);
  await ws(store, { type: 'item_place', worldId: 'default', itemId, tileX: 5, tileY: 6 });

  const sent = await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 5, tileY: 6 });
  assert.equal(sent[0]!.type, 'bag_update');
  assert.deepEqual(sent[0]!.bag, { [itemId]: 1 }, '拾回背包');
  const { t, version } = terrainOf(store);
  assert.equal(version, 3, '拾起 = tile 编辑，version+1');
  assert.equal(t.itemRef[at(5, 6)], 0, 'tile 引用已清');

  // 内置树拒拾（一期只有语音造物可拾起）
  const builtin = await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 10, tileY: 10 });
  assert.equal(builtin[0]!.type, 'error');
  assert.equal(terrainOf(store).t.itemRef[at(10, 10)], 1, '树还在');

  // 空 tile → error
  const empty = await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 1, tileY: 1 });
  assert.equal(empty[0]!.type, 'error');
});

test('摆放→拾起→再摆 roundtrip：矩阵与背包守恒（克隆语义：同实体可反复引用）', async () => {
  const store = new WorldStore();
  seedScene(store);
  const itemId = await seededItem(store);

  await ws(store, { type: 'item_place', worldId: 'default', itemId, tileX: 5, tileY: 6 });
  await ws(store, { type: 'item_pickup', worldId: 'default', tileX: 5, tileY: 6 });
  const sent = await ws(store, { type: 'item_place', worldId: 'default', itemId, tileX: 20, tileY: 21 });
  assert.equal(sent[0]!.type, 'bag_update');
  const { t } = terrainOf(store);
  assert.equal(t.itemRef[at(5, 6)], 0);
  assert.equal(t.palette[t.itemRef[at(20, 21)]! - 1], itemId);
  assert.deepEqual(store.getBag('default', ANON_PLAYER), {});
});

// 磁盘 roundtrip：背包与矩阵重开 store 后不变
test('bag 持久化 roundtrip', async () => {
  const dir = join(tmpdir(), 'maliang-test-item-bag');
  rmSync(dir, { recursive: true, force: true });
  try {
    const store = new WorldStore(dir);
    seedScene(store);
    const itemId = await seededItem(store);

    const store2 = new WorldStore(dir);
    assert.deepEqual(store2.getBag('default', ANON_PLAYER), { [itemId]: 1 });
    assert.equal(store2.listWorldItems('default').length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// 启动迁移：存量 props 行（旧 WorldProp 实例）→ items 实体行 + 矩阵引用/匿名背包，幂等
test('props 迁移：placed 进矩阵、占地冲突/bagged 收匿名背包、迁移后删行', () => {
  const dir = join(tmpdir(), 'maliang-test-props-migrate');
  rmSync(dir, { recursive: true, force: true });
  const spec = { name: '小风车', palette: ['#fff'], blend: 0.2, outline: 0.04, parts: [], locomotion: { type: 'none' }, ropes: [] };
  try {
    // 先建好世界+矩阵，再直插旧 props 行模拟存量库（addProp 已退役，没有公开写入口）
    const s1 = new WorldStore(dir);
    seedScene(s1);
    const db = new DatabaseSync(join(dir, 'world.db'));
    const ins = db.prepare('INSERT INTO props (id, world_id, data) VALUES (?, ?, ?)');
    ins.run('p-placed', 'default', JSON.stringify({ id: 'p-placed', spec, tile: [20, 20], state: 'placed', sceneId: DEFAULT_SCENE }));
    ins.run('p-conflict', 'default', JSON.stringify({ id: 'p-conflict', spec, tile: [10, 10], state: 'placed', sceneId: DEFAULT_SCENE })); // 树占着
    ins.run('p-bagged', 'default', JSON.stringify({ id: 'p-bagged', spec, tile: null, state: 'bagged', sceneId: DEFAULT_SCENE }));
    db.close();

    const s2 = new WorldStore(dir); // 构造函数跑迁移
    assert.equal(s2.listWorldItems('default').length, 3, '三行全迁成 items 实体');
    const rec = s2.getSceneTerrain('default', DEFAULT_SCENE)!;
    const t = decodeTerrain(rec.bytes);
    assert.equal(t.palette[t.itemRef[at(20, 20)]! - 1], 'p-placed', 'placed 且落位合法 → 写进矩阵');
    assert.equal(rec.version, 2, '迁移写矩阵 version+1');
    assert.deepEqual(
      s2.getBag('default', ANON_PLAYER),
      { 'p-conflict': 1, 'p-bagged': 1 },
      '冲突与 bagged 收进匿名背包',
    );

    // 幂等：再开一次不翻倍（props 行已删）
    const s3 = new WorldStore(dir);
    assert.equal(s3.listWorldItems('default').length, 3);
    assert.deepEqual(s3.getBag('default', ANON_PLAYER), { 'p-conflict': 1, 'p-bagged': 1 });
    assert.equal(decodeTerrain(s3.getSceneTerrain('default', DEFAULT_SCENE)!.bytes).itemRef[at(20, 20)]! > 0, true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
