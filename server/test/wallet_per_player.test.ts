import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { ANON_PLAYER, INITIAL_FLOWERS, MAX_FLOWERS, type ActiveTask } from '../src/types.ts';

function store(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  return s;
}

function task(npcName: string): ActiveTask {
  return { id: 't1', type: 'visit', npcId: 'n1', npcName, locationName: '池塘', stampStyle: 'star' };
}

test('每个玩家首次读到钱包即发初始小红花，互不相干', () => {
  const s = store();
  assert.equal(s.getWallet('w1', 'A').flowers, INITIAL_FLOWERS);
  assert.equal(s.getWallet('w1', 'B').flowers, INITIAL_FLOWERS);

  // A 花掉一朵，B 一分不少
  assert.equal(s.spendFlower('w1', 'A'), true);
  assert.equal(s.getWallet('w1', 'A').flowers, INITIAL_FLOWERS - 1);
  assert.equal(s.getWallet('w1', 'B').flowers, INITIAL_FLOWERS, 'B 的花不该被 A 花掉');
});

test('盖章升花只记在自己头上', () => {
  const s = store();
  for (let i = 0; i < 3; i++) s.addStamp('w1', 'A'); // 3 章 = 1 花
  assert.equal(s.getWallet('w1', 'A').flowers, INITIAL_FLOWERS + 1);
  assert.equal(s.getWallet('w1', 'A').stampsTotal, 3);
  assert.equal(s.getWallet('w1', 'B').stampsTotal, 0, 'B 没盖过章');
});

test('退款/管理设花都按玩家隔离', () => {
  const s = store();
  s.spendFlower('w1', 'A', 3);
  assert.equal(s.getWallet('w1', 'A').flowers, 0);

  s.refundFlower('w1', 'A');
  assert.equal(s.getWallet('w1', 'A').flowers, 1);

  s.setFlowers('w1', 'B', MAX_FLOWERS);
  assert.equal(s.getWallet('w1', 'B').flowers, MAX_FLOWERS);
  assert.equal(s.getWallet('w1', 'A').flowers, 1, 'A 不受影响');
});

test('进行中委托按玩家分：A 有委托不挡 B', () => {
  const s = store();
  assert.equal(s.getActiveTask('w1', 'A'), null);

  s.setActiveTask('w1', 'A', task('小蓝'));
  assert.equal(s.getActiveTask('w1', 'A')?.npcName, '小蓝');
  assert.equal(s.getActiveTask('w1', 'B'), null, 'B 仍是空的——这正是改动的目的');

  s.setActiveTask('w1', 'B', task('小绿'));
  assert.equal(s.getActiveTask('w1', 'A')?.npcName, '小蓝');
  assert.equal(s.getActiveTask('w1', 'B')?.npcName, '小绿');
});

test('setActiveTask(null) 删行，不留空壳', () => {
  const s = store();
  s.setActiveTask('w1', 'A', task('小蓝'));
  s.setActiveTask('w1', 'A', null);
  assert.equal(s.getActiveTask('w1', 'A'), null);
  assert.deepEqual(s.listActiveTasks('w1'), []);
});

test('匿名兜底：空 playerId 落到 ANON_PLAYER，所有匿名连接共用一份', () => {
  const s = store();
  s.spendFlower('w1', '');
  assert.equal(s.getWallet('w1', ANON_PLAYER).flowers, INITIAL_FLOWERS - 1);
  assert.equal(s.getWallet('w1', '').flowers, INITIAL_FLOWERS - 1, '空串与 ANON_PLAYER 是同一个钱包');
  assert.equal(s.getWallet('w1', 'A').flowers, INITIAL_FLOWERS, '具名玩家不受匿名影响');
});

test('世界不存在：读钱包返回空钱包且不写库；扣花返回 false', () => {
  const s = store();
  assert.deepEqual(s.getWallet('nope', 'A'), { flowers: 0, stampProgress: 0, stampsTotal: 0, hearts: 0 });
  assert.equal(s.spendFlower('nope', 'A'), false);
  assert.deepEqual(s.listWallets('nope'), [], '没有为不存在的世界建钱包行');
});

test('listWallets / listActiveTasks 列出该世界所有玩家', () => {
  const s = store();
  s.getWallet('w1', 'A');
  s.getWallet('w1', 'B');
  s.setActiveTask('w1', 'B', task('小绿'));

  assert.deepEqual(s.listWallets('w1').map((x) => x.playerId), ['A', 'B']);
  assert.deepEqual(s.listActiveTasks('w1').map((x) => x.playerId), ['B']);
});

test('钱包跨重启保留，且仍按玩家分', () => {
  const dir = join(tmpdir(), 'maliang-test-wallet-pp');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  s1.spendFlower('w1', 'A', 2);
  s1.setActiveTask('w1', 'A', task('小蓝'));

  const s2 = new WorldStore(dir);
  assert.equal(s2.getWallet('w1', 'A').flowers, INITIAL_FLOWERS - 2);
  assert.equal(s2.getWallet('w1', 'B').flowers, INITIAL_FLOWERS);
  assert.equal(s2.getActiveTask('w1', 'A')?.npcName, '小蓝');
});
