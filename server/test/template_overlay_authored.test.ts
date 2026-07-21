// world-template base+overlay P2（docs/template-overlay-arch-design.md §3/§4/§7）：
// 场景作者字段 pois/portals/homes 读时一律取自 template base——世界行不再各存副本。
// 核心收益：作者改 template，存量玩家世界下次读【自动反映】，无需逐个 POST，也不被重 seed 冲掉。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { REQUIRED_GRID } from '../src/terrain.ts';
import { DEFAULT_SCENE, type ScenePoi, type ScenePortal, type SceneHome } from '../src/types.ts';

const POI = (name: string): ScenePoi => ({ tile: [24, 24], radius: 20, trigger: 'poi_pond', name, aliases: [] });
const PORTAL = (toScene: string): ScenePortal => ({ tile: [1, 1], radius: 5, toScene, toTile: [2, 2] });
const HOME = (characterId: string): SceneHome => ({ tile: [10, 12], characterId });

/** 往某世界登记主场景（作者字段可指定）。 */
function authorScene(
  s: WorldStore,
  worldId: string,
  fields: { pois?: ScenePoi[]; portals?: ScenePortal[]; homes?: SceneHome[] } = {},
): void {
  s.upsertScene({
    worldId, sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: `h_${worldId}`, gridTiles: REQUIRED_GRID, terrainVersion: 1,
    pois: fields.pois ?? [], portals: fields.portals ?? [], homes: fields.homes ?? [],
  });
}

// ── 核心契约：三个作者字段读时都取自 template base ─────────────────────────────

test('P2 §7：作者改 template 的 homes → 存量世界 getScene 即刻反映（不重克隆/POST）', () => {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  authorScene(s, TEMPLATE_WORLD_ID, { homes: [HOME('bear')] });
  // 一个存量玩家世界（从 template 铺开）
  const kid = s.getOrCreateMyWorld('kid');
  assert.deepEqual(s.getScene(kid, DEFAULT_SCENE)!.homes, [HOME('bear')], '克隆时读到 base 的 homes');

  // 作者只改 template，一次都不碰 kid
  authorScene(s, TEMPLATE_WORLD_ID, { homes: [HOME('bear'), HOME('wolf')] });
  assert.deepEqual(
    s.getScene(kid, DEFAULT_SCENE)!.homes,
    [HOME('bear'), HOME('wolf')],
    '存量世界读时自动重算 = template 当前 homes',
  );
});

test('P2：pois / portals 同样读自 template base（作者一改全世界生效）', () => {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  authorScene(s, TEMPLATE_WORLD_ID, { pois: [POI('池塘')], portals: [PORTAL('forest')] });
  const kid = s.getOrCreateMyWorld('kid');
  assert.equal(s.getScene(kid, DEFAULT_SCENE)!.pois[0]!.name, '池塘');
  assert.equal(s.getScene(kid, DEFAULT_SCENE)!.portals[0]!.toScene, 'forest');

  authorScene(s, TEMPLATE_WORLD_ID, { pois: [POI('大湖')], portals: [PORTAL('castle')] });
  assert.equal(s.getScene(kid, DEFAULT_SCENE)!.pois[0]!.name, '大湖', 'pois 走 base');
  assert.equal(s.getScene(kid, DEFAULT_SCENE)!.portals[0]!.toScene, 'castle', 'portals 走 base');
  // listScenes 与 getScene 同口径
  assert.equal(s.listScenes(kid)[0]!.pois[0]!.name, '大湖', 'listScenes 也走 base');
  assert.equal((s.listScenes(kid)[0]!.homes ?? []).length, 0);
});

test('P2：多个存量世界共享同一 template base——改一次全反映', () => {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  authorScene(s, TEMPLATE_WORLD_ID, { homes: [HOME('bear')] });
  const a = s.getOrCreateMyWorld('a');
  const b = s.getOrCreateMyWorld('b');
  authorScene(s, TEMPLATE_WORLD_ID, { homes: [HOME('bear'), HOME('fox')] });
  assert.deepEqual(s.getScene(a, DEFAULT_SCENE)!.homes, [HOME('bear'), HOME('fox')]);
  assert.deepEqual(s.getScene(b, DEFAULT_SCENE)!.homes, [HOME('bear'), HOME('fox')]);
});

// ── template 世界本身即 base：读自己的行 ─────────────────────────────────────────

test('P2：template 世界 getScene 读自己的作者字段（它就是 base，不自我回退成空）', () => {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  authorScene(s, TEMPLATE_WORLD_ID, { homes: [HOME('bear')], pois: [POI('池塘')] });
  assert.deepEqual(s.getScene(TEMPLATE_WORLD_ID, DEFAULT_SCENE)!.homes, [HOME('bear')]);
  assert.equal(s.getScene(TEMPLATE_WORLD_ID, DEFAULT_SCENE)!.pois[0]!.name, '池塘');
});

// ── 边界回退：template 无此场景时，世界读自己行（兼容旧环境/独有场景）──────────────

test('P2 回退：template 无此场景（世界独有）时，getScene 用世界自己的作者字段', () => {
  const s = new WorldStore();
  s.createWorld('w1'); // 没有 template 世界
  authorScene(s, 'w1', { homes: [HOME('cat')], pois: [POI('小院')] });
  assert.deepEqual(s.getScene('w1', DEFAULT_SCENE)!.homes, [HOME('cat')], '模板缺场景 → 回退世界自己行');
  assert.equal(s.getScene('w1', DEFAULT_SCENE)!.pois[0]!.name, '小院');
});

// ── 迁移（dir-backed 重开触发）：清冗余拷贝【无损】——独有场景保留 ───────────────────

test('P2 迁移：重开清存量世界与 base 重复的作者字段拷贝，且【不】动 template 独缺的场景（无损）', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-overlay-'));
  try {
    {
      const s = new WorldStore(dir);
      s.createWorld(TEMPLATE_WORLD_ID);
      authorScene(s, TEMPLATE_WORLD_ID, { homes: [HOME('bear')] }); // base
      // 存量玩家世界：模拟 P2 前的快照拷贝——village 存了过时的 homes，另有一张 template 没有的独有场景
      s.createWorld('w_kid');
      authorScene(s, 'w_kid', { homes: [HOME('stale_cat')] }); // 与 base 同 sceneId：冗余拷贝，迁移应清
      s.upsertScene({
        worldId: 'w_kid', sceneId: 'secret_den', name: '密室', terrainAsset: 'h_den', gridTiles: REQUIRED_GRID,
        terrainVersion: 1, pois: [], portals: [], homes: [HOME('owl')], // template 无此场景：迁移应保留
      });
    }
    // 重开 → #migrateScenesDropAuthoredFields 跑
    const s2 = new WorldStore(dir);
    // 共享场景：读到 base 的当前值（过时拷贝被清，且本就读 base）
    assert.deepEqual(s2.getScene('w_kid', DEFAULT_SCENE)!.homes, [HOME('bear')], '共享场景读 template base');
    // 独有场景：template 缺 → 回退世界自己行；迁移未清它 → 数据仍在（无损）
    assert.deepEqual(s2.getScene('w_kid', 'secret_den')!.homes, [HOME('owl')], '模板独缺的场景作者字段被保留');
    // 幂等：再开一次不损坏
    const s3 = new WorldStore(dir);
    assert.deepEqual(s3.getScene('w_kid', 'secret_den')!.homes, [HOME('owl')]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
