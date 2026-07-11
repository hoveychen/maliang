// 奖赏系统数据层：小红花钱包（盖章累加/满3升花/满9溢出/扣费不足/退还）、
// 委托状态、SQLite 持久化回读、旧贴纸档方案 A 迁移。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { ANON_PLAYER, INITIAL_FLOWERS, MAX_FLOWERS, type ActiveTask } from '../src/types.ts';

const TASK: ActiveTask = {
  id: 't1',
  type: 'deliver',
  npcId: 'blue',
  npcName: '小蓝',
  targetName: '小黄',
  message: '今天别忘了浇花',
  stampStyle: 'star',
};

test('新档冷启动：预置初始小红花、零盖章进度', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  assert.deepEqual(store.getWallet('w1', ANON_PLAYER), { flowers: INITIAL_FLOWERS, stampProgress: 0, stampsTotal: 0, hearts: 0 });
});

test('盖章：纯累加，每满 3 章换 1 花，stampsTotal 只增', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  let r = store.addStamp('w1', ANON_PLAYER);
  assert.equal(r.flowerGained, false);
  assert.deepEqual(r.wallet, { flowers: INITIAL_FLOWERS, stampProgress: 1, stampsTotal: 1, hearts: 0 });
  r = store.addStamp('w1', ANON_PLAYER);
  assert.equal(r.flowerGained, false);
  assert.equal(r.wallet.stampProgress, 2);
  r = store.addStamp('w1', ANON_PLAYER); // 第 3 章 → 升 1 花，进度归零
  assert.equal(r.flowerGained, true);
  assert.deepEqual(r.wallet, { flowers: INITIAL_FLOWERS + 1, stampProgress: 0, stampsTotal: 3, hearts: 0 });
});

test('满 9 溢出：停在待兑换组不清零、不再多攒；花掉低于 9 立即补升', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  // 先花掉初始 3 花，再狂盖章把花攒到 9（9 花 = 27 章）
  assert.equal(store.spendFlower('w1', ANON_PLAYER, INITIAL_FLOWERS), true);
  for (let i = 0; i < MAX_FLOWERS * 3; i++) store.addStamp('w1', ANON_PLAYER);
  let w = store.getWallet('w1', ANON_PLAYER);
  assert.equal(w.flowers, MAX_FLOWERS, '应攒到上限 9 花');
  assert.equal(w.stampProgress, 0);
  // 满 9 后再盖 3 章：不升花，进度停在满组（=3）待兑换，多的丢弃
  store.addStamp('w1', ANON_PLAYER);
  store.addStamp('w1', ANON_PLAYER);
  const r = store.addStamp('w1', ANON_PLAYER);
  assert.equal(r.flowerGained, false, '满 9 不升花');
  assert.equal(r.wallet.flowers, MAX_FLOWERS);
  assert.equal(r.wallet.stampProgress, 3, '一组已满停住待兑换');
  store.addStamp('w1', ANON_PLAYER); // 再盖也不再多攒
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampProgress, 3, '溢出不无限累积');
  // 花掉 1 朵 → 立即补升那组待兑换（回到 9 花、进度归零）
  assert.equal(store.spendFlower('w1', ANON_PLAYER), true);
  w = store.getWallet('w1', ANON_PLAYER);
  assert.equal(w.flowers, MAX_FLOWERS, '花掉后待兑换组立即补升回 9');
  assert.equal(w.stampProgress, 0);
});

test('扣费：够扣返回 true 并扣账，不够返回 false 且不动账', () => {
  const store = new WorldStore();
  store.createWorld('w1'); // 初始 3 花
  assert.equal(store.spendFlower('w1', ANON_PLAYER, 2), true);
  assert.equal(store.getWallet('w1', ANON_PLAYER).flowers, 1);
  assert.equal(store.spendFlower('w1', ANON_PLAYER, 2), false, '不够扣不动账');
  assert.equal(store.getWallet('w1', ANON_PLAYER).flowers, 1);
  assert.equal(store.spendFlower('w1', ANON_PLAYER), true);
  assert.equal(store.getWallet('w1', ANON_PLAYER).flowers, 0);
  assert.equal(store.spendFlower('w1', ANON_PLAYER), false, '0 花扣不动');
});

test('退还：补花受上限约束，多余丢弃', () => {
  const store = new WorldStore();
  store.createWorld('w1'); // 初始 3 花
  assert.equal(store.spendFlower('w1', ANON_PLAYER), true); // 2 花
  assert.equal(store.refundFlower('w1', ANON_PLAYER).flowers, 3, '退 1 朵回到 3');
  assert.equal(store.refundFlower('w1', ANON_PLAYER, 100).flowers, MAX_FLOWERS, '补到上限封顶 9');
});

test('委托状态：设置/读取/清除，stampStyle 随委托持久', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null);
  store.setActiveTask('w1', ANON_PLAYER, TASK);
  assert.equal(store.getActiveTask('w1', ANON_PLAYER)!.stampStyle, 'star');
  store.setActiveTask('w1', ANON_PLAYER, null);
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null);
});

test('持久化：钱包与委托落盘并回读', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-reward-'));
  const store = new WorldStore(dir);
  store.createWorld('w1');
  store.addStamp('w1', ANON_PLAYER);
  store.spendFlower('w1', ANON_PLAYER);
  store.setActiveTask('w1', ANON_PLAYER, TASK);
  const reloaded = new WorldStore(dir);
  assert.deepEqual(reloaded.getWallet('w1', ANON_PLAYER), { flowers: INITIAL_FLOWERS - 1, stampProgress: 1, stampsTotal: 1, hearts: 0 });
  assert.equal(reloaded.getActiveTask('w1', ANON_PLAYER)!.type, 'deliver');
});

test('方案 A 迁移：旧贴纸背包 worlds.json → 清空换初始小红花，写回固化', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-legacy-'));
  writeFileSync(
    join(dir, 'worlds.json'),
    JSON.stringify({ worlds: [{ id: 'old', characters: [], inventory: { flower: 2, star: 5 } }] }),
  );
  const store = new WorldStore(dir);
  // 旧贴纸清空，置初始花
  assert.deepEqual(store.getWallet('old', ANON_PLAYER), { flowers: INITIAL_FLOWERS, stampProgress: 0, stampsTotal: 0, hearts: 0 });
  // 迁移后动一动账，新实例读回可见（旧 worlds.json 已改名 .migrated）
  store.spendFlower('old', ANON_PLAYER, INITIAL_FLOWERS);
  assert.equal(new WorldStore(dir).getWallet('old', ANON_PLAYER).flowers, 0);
});

test('旧档无 inventory 字段：迁移路径也置初始花', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-empty-'));
  writeFileSync(join(dir, 'worlds.json'), JSON.stringify({ worlds: [{ id: 'e', characters: [] }] }));
  const store = new WorldStore(dir);
  assert.equal(store.getWallet('e', ANON_PLAYER).flowers, INITIAL_FLOWERS, '无 inventory 字段的旧档也置初始花');
});
