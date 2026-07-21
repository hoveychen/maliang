// world-template-arch P3 地形 base+overlay 端到端(store 级,设计 §7):
// 孩子改一片 tile + 作者改 template 另一片 tile → 该世界读到「作者的新 tile + 孩子的旧 tile」都在;
// 版本随 base 改动而变(客户端据此重拉);孩子编辑版本 +1(terrain_patch 对齐);存量世界迁移无损。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { editSceneTerrain } from '../src/terrain_edit.ts';
import { emptyTerrain, encodeTerrain, decodeTerrain, REQUIRED_GRID, T_GRASS, T_WATER, T_PATH } from '../src/terrain.ts';
import { DEFAULT_SCENE } from '../src/types.ts';

const SC = DEFAULT_SCENE;
const idx = (x: number, y: number) => y * REQUIRED_GRID + x;

/** 建 template 世界 + 主场景 + 一张全草地形(terrain_version=1),再从它铺一个玩家世界,返回玩家 world_id。 */
function templateWithKid(): { s: WorldStore; kid: string } {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  s.upsertScene({ worldId: TEMPLATE_WORLD_ID, sceneId: SC, name: '村庄', terrainAsset: 'h', gridTiles: REQUIRED_GRID, terrainVersion: 1, pois: [], portals: [] });
  s.setSceneTerrain(TEMPLATE_WORLD_ID, SC, encodeTerrain(emptyTerrain(REQUIRED_GRID)), 1);
  const kid = s.getOrCreateMyWorld('kid'); // 克隆 → overlay 模式(空 overlay)
  return { s, kid };
}

// ── §7 核心:孩子 tile + 作者 base tile 合成 ─────────────────────────────────

test('P3 §7:孩子挖水 tile A + 作者把 base 另一 tile B 改成路 → 该世界两者都在', () => {
  const { s, kid } = templateWithKid();
  // 孩子在自己世界 A=(5,5) 挖水
  editSceneTerrain(s, undefined, kid, SC, [{ x: 5, y: 5, t: T_WATER }]);
  // 作者事后改 template 的 B=(10,10) 为路(与孩子无关的另一格)
  editSceneTerrain(s, undefined, TEMPLATE_WORLD_ID, SC, [{ x: 10, y: 10, t: T_PATH }]);

  const rec = s.getSceneTerrain(kid, SC)!;
  const t = decodeTerrain(rec.bytes);
  assert.equal(t.types[idx(5, 5)], T_WATER, 'A:孩子的水保留(per-tile-wins)');
  assert.equal(t.types[idx(10, 10)], T_PATH, 'B:作者对 base 的新改动流入(传播)');
  // template base 本身不被孩子的编辑污染
  const baseT = decodeTerrain(s.getSceneTerrain(TEMPLATE_WORLD_ID, SC)!.bytes);
  assert.equal(baseT.types[idx(5, 5)], T_GRASS, 'base 的 A 仍是草(孩子编辑没写回 base)');
});

test('P3 冲突:作者改了孩子也挖过水的同一 tile → 孩子胜', () => {
  const { s, kid } = templateWithKid();
  editSceneTerrain(s, undefined, kid, SC, [{ x: 7, y: 7, t: T_WATER }]);      // 孩子挖水
  editSceneTerrain(s, undefined, TEMPLATE_WORLD_ID, SC, [{ x: 7, y: 7, t: T_PATH }]); // 作者改路
  const t = decodeTerrain(s.getSceneTerrain(kid, SC)!.bytes);
  assert.equal(t.types[idx(7, 7)], T_WATER, '冲突 tile 孩子胜');
});

test('P3 隔离:两个世界各自的地形编辑互不影响', () => {
  const { s } = templateWithKid();
  const a = s.getOrCreateMyWorld('a');
  const b = s.getOrCreateMyWorld('b');
  editSceneTerrain(s, undefined, a, SC, [{ x: 3, y: 3, t: T_WATER }]);
  const ta = decodeTerrain(s.getSceneTerrain(a, SC)!.bytes);
  const tb = decodeTerrain(s.getSceneTerrain(b, SC)!.bytes);
  assert.equal(ta.types[idx(3, 3)], T_WATER, 'a 世界改了');
  assert.equal(tb.types[idx(3, 3)], T_GRASS, 'b 世界不受影响');
});

// ── 版本语义:客户端缓存键 = terrainVersion ─────────────────────────────────

test('P3 版本:孩子编辑 → 对外 terrainVersion 恰 +1(terrain_patch 严格对齐)', () => {
  const { s, kid } = templateWithKid();
  const v0 = s.getScene(kid, SC)!.terrainVersion!;
  const r = editSceneTerrain(s, undefined, kid, SC, [{ x: 1, y: 1, t: T_WATER }]);
  assert.equal(r.version, v0 + 1, 'editSceneTerrain 返回版本 = 旧版本 +1');
  assert.equal(s.getScene(kid, SC)!.terrainVersion, v0 + 1, 'getScene 也反映新版本');
});

test('P3 版本:作者改 base 地形 → 存量世界 terrainVersion 变(客户端据此重拉)', () => {
  const { s, kid } = templateWithKid();
  const before = s.getScene(kid, SC)!.terrainVersion!;
  editSceneTerrain(s, undefined, TEMPLATE_WORLD_ID, SC, [{ x: 9, y: 9, t: T_PATH }]); // 作者改 base
  const after = s.getScene(kid, SC)!.terrainVersion!;
  assert.ok(after > before, `base 改动后世界版本应变大: ${before} → ${after}`);
});

test('P3 版本:base 未改多次读 terrainVersion 稳定(不无谓 +1、不重拉抖动)', () => {
  const { s, kid } = templateWithKid();
  const v1 = s.getScene(kid, SC)!.terrainVersion;
  const v2 = s.getScene(kid, SC)!.terrainVersion;
  assert.equal(v1, v2, '无编辑无 base 改动 → 版本恒定');
});

// ── 存量世界迁移(dir-backed 重开):全量 blob → overlay,无损 + 传播生效 ──────────

test('P3 迁移:存量全量 blob 世界重开转 overlay → 保住孩子地形 + 之后能收作者 base 更新', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-p3-'));
  try {
    {
      const s = new WorldStore(dir);
      s.createWorld(TEMPLATE_WORLD_ID);
      s.upsertScene({ worldId: TEMPLATE_WORLD_ID, sceneId: SC, name: '村庄', terrainAsset: 'h', gridTiles: REQUIRED_GRID, terrainVersion: 1, pois: [], portals: [] });
      s.setSceneTerrain(TEMPLATE_WORLD_ID, SC, encodeTerrain(emptyTerrain(REQUIRED_GRID)), 1); // base 全草
      // 存量玩家世界:P3 前的形态——全量 blob(terrain_overlay=NULL),blob 里孩子把 (4,4) 挖成了水
      s.createWorld('w_kid');
      s.upsertScene({ worldId: 'w_kid', sceneId: SC, name: '村庄', terrainAsset: 'h', gridTiles: REQUIRED_GRID, terrainVersion: 3, pois: [], portals: [] });
      const childBlob = emptyTerrain(REQUIRED_GRID);
      childBlob.types[idx(4, 4)] = T_WATER; childBlob.depths[idx(4, 4)] = 1;
      s.setSceneTerrain('w_kid', SC, encodeTerrain(childBlob), 3);
    }
    // 重开 → #migrateScenesToOverlay 把 w_kid 转 overlay
    const s2 = new WorldStore(dir);
    const t = decodeTerrain(s2.getSceneTerrain('w_kid', SC)!.bytes);
    assert.equal(t.types[idx(4, 4)], T_WATER, '迁移无损:孩子挖的水仍在');
    // 迁移后能收作者 base 更新:作者改 base 的另一格 → w_kid 读到
    editSceneTerrain(s2, undefined, TEMPLATE_WORLD_ID, SC, [{ x: 20, y: 20, t: T_PATH }]);
    const t2 = decodeTerrain(s2.getSceneTerrain('w_kid', SC)!.bytes);
    assert.equal(t2.types[idx(20, 20)], T_PATH, '迁移后 base 传播生效');
    assert.equal(t2.types[idx(4, 4)], T_WATER, '孩子的水不被 base 传播冲掉');
    // 幂等:再开一次仍正确
    const s3 = new WorldStore(dir);
    assert.equal(decodeTerrain(s3.getSceneTerrain('w_kid', SC)!.bytes).types[idx(4, 4)], T_WATER);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── 边界:无 template base 的世界(独有场景)仍走老式全量 blob,不退化 ──────────────

test('P3 边界:template 无此场景时,世界地形走老式全量 blob(编辑照常、无 base 可合成)', () => {
  const s = new WorldStore();
  s.createWorld('w1'); // 没有 template
  s.upsertScene({ worldId: 'w1', sceneId: SC, name: '村庄', terrainAsset: 'h', gridTiles: REQUIRED_GRID, terrainVersion: 1, pois: [], portals: [] });
  s.setSceneTerrain('w1', SC, encodeTerrain(emptyTerrain(REQUIRED_GRID)), 1);
  const r = editSceneTerrain(s, undefined, 'w1', SC, [{ x: 2, y: 2, t: T_WATER }]);
  assert.equal(r.version, 2, '老式世界版本 +1');
  assert.equal(decodeTerrain(s.getSceneTerrain('w1', SC)!.bytes).types[idx(2, 2)], T_WATER);
});
