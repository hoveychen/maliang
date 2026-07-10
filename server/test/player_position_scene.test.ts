import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { DEFAULT_SCENE, type Player } from '../src/types.ts';

function seed(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  const p: Player = { id: 'A', name: '小明', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
  s.upsertPlayer(p);
  return s;
}

test('玩家位置按场景分：村庄的 (12,30) 不该覆盖森林的 (12,30)', () => {
  const s = seed();

  s.setPlayerTile('w1', 'village', 'A', { tileX: 12, tileY: 30 });
  s.setPlayerTile('w1', 'forest', 'A', { tileX: 5, tileY: 7 });

  assert.deepEqual(s.getPlayerTile('w1', 'village', 'A'), { tileX: 12, tileY: 30 });
  assert.deepEqual(s.getPlayerTile('w1', 'forest', 'A'), { tileX: 5, tileY: 7 }, '森林的位置被村庄盖掉了');
});

test('玩家位置按世界分：另一个世界的同名场景互不干扰', () => {
  const s = seed();
  s.createWorld('w2');

  s.setPlayerTile('w1', DEFAULT_SCENE, 'A', { tileX: 1, tileY: 1 });
  s.setPlayerTile('w2', DEFAULT_SCENE, 'A', { tileX: 2, tileY: 2 });

  assert.deepEqual(s.getPlayerTile('w1', DEFAULT_SCENE, 'A'), { tileX: 1, tileY: 1 });
  assert.deepEqual(s.getPlayerTile('w2', DEFAULT_SCENE, 'A'), { tileX: 2, tileY: 2 });
});

test('没去过的场景 → undefined（客户端按小神仙旁降生）', () => {
  const s = seed();
  s.setPlayerTile('w1', 'village', 'A', { tileX: 3, tileY: 3 });
  assert.equal(s.getPlayerTile('w1', 'forest', 'A'), undefined);
});

test('玩家档案不存在 → setPlayerTile 返回 false 不动账', () => {
  const s = seed();
  assert.equal(s.setPlayerTile('w1', 'village', 'nobody', { tileX: 1, tileY: 1 }), false);
  assert.equal(s.getPlayerTile('w1', 'village', 'nobody'), undefined);
});

test('两个玩家在同一场景互不覆盖', () => {
  const s = seed();
  const b: Player = { id: 'B', name: '小红', nickname: '', gender: 'girl', color: '红', spriteAsset: '', createdAt: '2026-01-01' };
  s.upsertPlayer(b);

  s.setPlayerTile('w1', 'village', 'A', { tileX: 1, tileY: 1 });
  s.setPlayerTile('w1', 'village', 'B', { tileX: 9, tileY: 9 });

  assert.deepEqual(s.getPlayerTile('w1', 'village', 'A'), { tileX: 1, tileY: 1 });
  assert.deepEqual(s.getPlayerTile('w1', 'village', 'B'), { tileX: 9, tileY: 9 });
});

test('upsertPlayer 重写档案不影响位置（位置已不在 players.data 里）', () => {
  const s = seed();
  s.setPlayerTile('w1', 'village', 'A', { tileX: 8, tileY: 9 });

  s.upsertPlayer({ ...s.getPlayer('A')!, nickname: '改名了' });

  assert.equal(s.getPlayer('A')!.nickname, '改名了');
  assert.deepEqual(s.getPlayerTile('w1', 'village', 'A'), { tileX: 8, tileY: 9 });
});

test('跨重启保留，且仍按场景分', () => {
  const dir = join(tmpdir(), 'maliang-test-playerpos-scene');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  s1.upsertPlayer({ id: 'A', name: 'n', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: 'x' });
  s1.setPlayerTile('w1', 'village', 'A', { tileX: 4, tileY: 5 });
  s1.setPlayerTile('w1', 'forest', 'A', { tileX: 6, tileY: 7 });

  const s2 = new WorldStore(dir);
  assert.deepEqual(s2.getPlayerTile('w1', 'village', 'A'), { tileX: 4, tileY: 5 });
  assert.deepEqual(s2.getPlayerTile('w1', 'forest', 'A'), { tileX: 6, tileY: 7 });
});

test('存量迁移：老档案 players.data.position → player_positions(default, village)，且清掉旧字段', () => {
  const dir = join(tmpdir(), 'maliang-test-playerpos-migrate');
  rmSync(dir, { recursive: true, force: true });

  // 造一个「老版本写下的」档案：位置塞在 players.data 里，无世界无场景
  const s1 = new WorldStore(dir);
  s1.createWorld('default');
  s1.upsertPlayer({ id: 'A', name: 'n', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: 'x' });
  // 绕过类型直接写旧结构（模拟旧版本落盘）
  const raw = JSON.parse(JSON.stringify(s1.getPlayer('A')));
  raw.position = { tileX: 12, tileY: 30 };
  s1.upsertPlayer(raw as never);

  // 新实例开库 → 构造函数里跑迁移
  const s2 = new WorldStore(dir);
  assert.deepEqual(s2.getPlayerTile('default', 'village', 'A'), { tileX: 12, tileY: 30 }, '老坐标搬到了 village');
  assert.equal((s2.getPlayer('A') as unknown as { position?: unknown }).position, undefined, '旧字段已清掉');

  // 幂等：再开一次不炸、不改值
  const s3 = new WorldStore(dir);
  assert.deepEqual(s3.getPlayerTile('default', 'village', 'A'), { tileX: 12, tileY: 30 });
});

test('存量迁移：没有 position 的老档案原样不动', () => {
  const dir = join(tmpdir(), 'maliang-test-playerpos-migrate2');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.upsertPlayer({ id: 'A', name: 'n', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: 'x' });

  const s2 = new WorldStore(dir);
  assert.equal(s2.getPlayer('A')!.name, 'n');
  assert.equal(s2.getPlayerTile('default', 'village', 'A'), undefined);
});
