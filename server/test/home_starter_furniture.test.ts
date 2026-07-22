// 室内系统 MVP（home-interior P4）：新玩家世界首建即给背包发「预置家具起始包」，进自己家能摆。
// 复用已有 toyroom 家具（不新造 item）；发放点 = getOrCreateMyWorld 首建分支，一玩家一世界、
// 创建仅一次 → 天然幂等，重入不重发。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { STARTER_HOME_FURNITURE, BUILTIN_ITEMS } from '../src/items.ts';

test('起始家具全在 BUILTIN_ITEMS（scene_entered 恒下发定义，客户端可解析渲染）', () => {
  const ids = new Set(BUILTIN_ITEMS.map((d) => d.id));
  for (const f of STARTER_HOME_FURNITURE) {
    assert.ok(ids.has(f.id), `起始家具 ${f.id} 必须是内置 item`);
  }
});

test('起始包含客厅一组（沙发+茶几+电视）+ 书架，空房不再空旷', () => {
  const ids = new Set(STARTER_HOME_FURNITURE.map((f) => f.id));
  for (const id of ['toy_sofa', 'toy_coffee_table', 'toy_tv', 'toy_bookcase']) {
    assert.ok(ids.has(id), `起始家具应含 ${id}（充实地面）`);
  }
});

test('新玩家世界首建：背包发到全套预置家具（数量对得上）', () => {
  const store = new WorldStore();
  const worldId = store.getOrCreateMyWorld('pid-1');
  const bag = store.getBag(worldId, 'pid-1');
  for (const f of STARTER_HOME_FURNITURE) {
    assert.equal(bag[f.id], f.count, `${f.id} 应有 ${f.count} 件`);
  }
});

test('幂等：同一玩家再次 getOrCreateMyWorld 不重复发放（数量不翻倍）', () => {
  const store = new WorldStore();
  const worldId = store.getOrCreateMyWorld('pid-2');
  store.getOrCreateMyWorld('pid-2'); // 二次进入：走已存在早返回，不再发
  store.getOrCreateMyWorld('pid-2'); // 三次
  const bag = store.getBag(worldId, 'pid-2');
  for (const f of STARTER_HOME_FURNITURE) {
    assert.equal(bag[f.id], f.count, `${f.id} 仍应是 ${f.count} 件（未重复发放）`);
  }
});

test('各玩家各自一份：另一个新玩家也拿到起始家具', () => {
  const store = new WorldStore();
  store.getOrCreateMyWorld('pid-a');
  const worldB = store.getOrCreateMyWorld('pid-b');
  const bagB = store.getBag(worldB, 'pid-b');
  assert.equal(bagB['toy_bed_single'], 1, '玩家 B 也应有单人床');
});
