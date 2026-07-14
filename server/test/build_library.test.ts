// 积木式造物（B1，docs/kids-thinking-build-from-parts.md）预置库自洽性。
// 这套库是纯代码常量，最大的风险不是逻辑而是「手写数据对不上」——某个槽没零件能填、
// 某个零件挂不到任何槽。拼装台一旦点亮一个填不了的槽，孩子就卡死。所以在库层就守死双向一致。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PART_LIBRARY,
  partsForSlot,
  partAcceptCategories,
  findPart,
} from '../src/part_library.ts';
import {
  BUILD_BLUEPRINTS,
  blueprintAcceptCategories,
  requiredSlots,
  findBlueprint,
} from '../src/build_blueprints.ts';

const MIN_CHOICES = 2; // 每个槽至少给孩子这么多零件可挑

test('零件 id 全局唯一', () => {
  const ids = PART_LIBRARY.map((p) => p.id);
  assert.equal(new Set(ids).size, ids.length, '有重复的零件 id');
});

test('蓝图 id 全局唯一，且每副蓝图内槽 id 唯一', () => {
  const bids = BUILD_BLUEPRINTS.map((b) => b.id);
  assert.equal(new Set(bids).size, bids.length, '有重复的蓝图 id');
  for (const bp of BUILD_BLUEPRINTS) {
    const sids = bp.slots.map((s) => s.slotId);
    assert.equal(new Set(sids).size, sids.length, `蓝图 ${bp.id} 内有重复 slotId`);
  }
});

test('每个槽的 accept 都至少有 MIN_CHOICES 个零件能填（无填不满的槽）', () => {
  for (const bp of BUILD_BLUEPRINTS) {
    for (const sl of bp.slots) {
      const parts = partsForSlot(sl.accept);
      assert.ok(
        parts.length >= MIN_CHOICES,
        `蓝图 ${bp.id} 的槽 ${sl.slotId}(accept=${sl.accept}) 只有 ${parts.length} 个零件可填，需 ≥${MIN_CHOICES}`,
      );
    }
  }
});

test('每个零件的 fitSlots 都指向某个真实存在的槽 accept（无孤儿零件）', () => {
  const validAccepts = blueprintAcceptCategories();
  for (const p of PART_LIBRARY) {
    assert.ok(p.fitSlots.length > 0, `零件 ${p.id} 没声明 fitSlots`);
    for (const a of p.fitSlots) {
      assert.ok(
        validAccepts.has(a),
        `零件 ${p.id} 的 fitSlots 含 '${a}'，但没有任何蓝图槽 accept 这个类别`,
      );
    }
  }
});

test('双向闭合：蓝图端 accept 集合 == 零件端 fitSlots 集合', () => {
  const bp = [...blueprintAcceptCategories()].sort();
  const pt = [...partAcceptCategories()].sort();
  assert.deepEqual(pt, bp, '蓝图槽的 accept 与零件的 fitSlots 不是同一集合（有一端多/少了类别）');
});

test('每副蓝图都有必填槽（不存在一放上去就落成的空壳）', () => {
  for (const bp of BUILD_BLUEPRINTS) {
    assert.ok(requiredSlots(bp).length >= 1, `蓝图 ${bp.id} 没有必填槽`);
  }
});

test('每个槽的 pose 合理：x/y ∈ [0,1]，scale > 0', () => {
  for (const bp of BUILD_BLUEPRINTS) {
    for (const sl of bp.slots) {
      const { x, y, scale } = sl.pose;
      assert.ok(x >= 0 && x <= 1, `${bp.id}/${sl.slotId} pose.x 越界: ${x}`);
      assert.ok(y >= 0 && y <= 1, `${bp.id}/${sl.slotId} pose.y 越界: ${y}`);
      assert.ok(scale > 0, `${bp.id}/${sl.slotId} pose.scale 非正: ${scale}`);
    }
  }
});

test('functionHint 不泄漏零件名（点点只问功能，不给答案）', () => {
  // 抽查：功能线索里不该直接出现零件的中文名（否则就成了报菜单）。
  const partNames = PART_LIBRARY.map((p) => p.name);
  for (const bp of BUILD_BLUEPRINTS) {
    for (const sl of bp.slots) {
      for (const nm of partNames) {
        assert.ok(
          !sl.functionHint.includes(nm),
          `蓝图 ${bp.id}/${sl.slotId} 的 functionHint 里出现了零件名「${nm}」——功能线索不该剧透答案`,
        );
      }
    }
  }
});

test('查找器：findPart / findBlueprint 命中与未命中', () => {
  assert.ok(findPart('wheel_round'), 'wheel_round 应存在');
  assert.equal(findPart('nope_no_such'), undefined);
  assert.ok(findBlueprint('car'), 'car 蓝图应存在');
  assert.equal(findBlueprint('nope'), undefined);
});
