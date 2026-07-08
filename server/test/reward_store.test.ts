// 奖赏系统数据层：贴纸背包加扣、委托状态、SQLite 持久化回读与旧档迁移兼容。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { STICKERS, stickerGlyph, type ActiveTask } from '../src/types.ts';

const TASK: ActiveTask = {
  id: 't1',
  type: 'deliver',
  npcId: 'blue',
  npcName: '小蓝',
  targetName: '小黄',
  message: '今天别忘了浇花',
  rewardId: 'flower',
};

test('贴纸目录：id 唯一、glyph 兜底', () => {
  assert.equal(new Set(STICKERS.map((s) => s.id)).size, STICKERS.length, '贴纸 id 不应重复');
  assert.equal(stickerGlyph('flower'), '🌸');
  assert.equal(stickerGlyph('不存在'), '⭐', '未知 id 用 ⭐ 兜底');
});

test('背包：发贴纸累积、扣贴纸不够不动账、扣到零清 key', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.addSticker('w1', 'flower');
  store.addSticker('w1', 'flower');
  store.addSticker('w1', 'star');
  assert.deepEqual(store.getInventory('w1'), { flower: 2, star: 1 });
  assert.equal(store.removeSticker('w1', 'gem'), false, '没有的贴纸扣不动');
  assert.equal(store.removeSticker('w1', 'flower', 3), false, '不够扣不动账');
  assert.deepEqual(store.getInventory('w1'), { flower: 2, star: 1 });
  assert.equal(store.removeSticker('w1', 'star'), true);
  assert.deepEqual(store.getInventory('w1'), { flower: 2 }, '扣到零应清 key');
});

test('委托状态：设置/读取/清除', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  assert.equal(store.getActiveTask('w1'), null);
  store.setActiveTask('w1', TASK);
  assert.equal(store.getActiveTask('w1')!.rewardId, 'flower');
  store.setActiveTask('w1', null);
  assert.equal(store.getActiveTask('w1'), null);
});

test('持久化：背包与委托随 worlds.json 落盘并回读', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-reward-'));
  const store = new WorldStore(dir);
  store.createWorld('w1');
  store.addSticker('w1', 'candy', 3);
  store.setActiveTask('w1', TASK);
  const reloaded = new WorldStore(dir);
  assert.deepEqual(reloaded.getInventory('w1'), { candy: 3 });
  assert.equal(reloaded.getActiveTask('w1')!.type, 'deliver');
});

test('旧档兼容：worlds.json 没有背包/委托字段 → 默认空背包无委托', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-legacy-'));
  writeFileSync(join(dir, 'worlds.json'), JSON.stringify({ worlds: [{ id: 'old', characters: [] }] }));
  const store = new WorldStore(dir);
  assert.deepEqual(store.getInventory('old'), {});
  assert.equal(store.getActiveTask('old'), null);
  // 落盘一次后新字段应持久化：新实例读回可见（旧 worlds.json 迁移后已改名 .migrated）
  store.addSticker('old', 'shell');
  assert.deepEqual(new WorldStore(dir).getInventory('old'), { shell: 1 });
});
