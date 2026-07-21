// s1-hood-activate P1：第一季册全部落在合并主场景 village_forest（B 全量合并，无 portal 切场景）。
// 锁定「进合并场景的册 sceneId 一致 + 角色落在 100 格界内 + 三只小猪迁进村庄核心近端带（z<40）」——
// 防「只改 sceneId 忘了迁坐标 → 小猪卡在退役 village 75 格坐标 / 漂进森林深处孩子找不到」的回归。
// 村庄核心带坐标语义见 scripts/terrain_map.gd _paint_village_forest（z 小=村庄近端，中央广场 x∈[16,24] z∈[12,20]）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { STORY_BOOKS, THREE_PIGS } from '../src/story_books.ts';

const VF = 'village_forest';
const GRID = 100; // village_forest 网格边长（PRESET 100）

// 进合并主场景的册（绿野仙踪另置场景，不在此）。
const MERGED_BOOK_IDS = ['three_pigs', 'hood'];

for (const bookId of MERGED_BOOK_IDS) {
  const book = STORY_BOOKS[bookId];
  test(`[${bookId}] 落在合并主场景 ${VF}，全 cast 位置在 100 格界内`, () => {
    assert.ok(book, `${bookId} 已注册`);
    assert.equal(book!.sceneId, VF, `${bookId} sceneId=${VF}（B 全量合并主场景）`);
    for (const c of book!.cast) {
      assert.ok(
        c.position.tileX >= 0 && c.position.tileX < GRID && c.position.tileY >= 0 && c.position.tileY < GRID,
        `${c.name} 位置 (${c.position.tileX},${c.position.tileY}) 越出 ${GRID} 格`,
      );
    }
  });
}

test('[three_pigs] 三兄弟迁进村庄核心近端带（z<40），狼在近端西侧一角', () => {
  const byId = Object.fromEntries(THREE_PIGS.cast.map((c) => [c.castId, c]));
  // 三只小猪聚在中央广场附近（近端 z<40，好找、离出生点近）
  for (const castId of ['pig_big', 'pig_mid', 'pig_small']) {
    const p = byId[castId]!.position;
    assert.ok(p.tileY < 40, `${castId} 应在村庄核心近端带 z<40，实际 z=${p.tileY}`);
    // 广场核心横向带 x∈[8,34]（广场 + 东/西巷），别飘到跑道/池塘去
    assert.ok(p.tileX >= 8 && p.tileX <= 34, `${castId} 应在村庄核心横带 x∈[8,34]，实际 x=${p.tileX}`);
  }
  // 狼在小猪群西侧（x 更小），仍在近端带
  assert.ok(byId['wolf']!.position.tileX < byId['pig_small']!.position.tileX, '狼在小猪群西侧');
  assert.ok(byId['wolf']!.position.tileY < 40, '狼也在村庄核心近端带');
});
