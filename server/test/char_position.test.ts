import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { GRID_TILES, WORLD_CENTER_TILE, isValidTile, type Character, type Player } from '../src/types.ts';

function char(worldId: string, id: string): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, abilities: [], relationships: {},
  };
}

function player(id: string): Player {
  return { id, name: '小明', nickname: '明明', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
}

function freshStore(tag: string): WorldStore {
  const dir = join(tmpdir(), `maliang-test-pos-${tag}`);
  rmSync(dir, { recursive: true, force: true });
  return new WorldStore(dir);
}

test('isValidTile：只接受 [0, GRID_TILES) 的整数，旧世界的 tile 500 被拒', () => {
  assert.equal(isValidTile({ tileX: 0, tileY: 0 }), true);
  assert.equal(isValidTile({ tileX: GRID_TILES - 1, tileY: GRID_TILES - 1 }), true);
  assert.equal(isValidTile(WORLD_CENTER_TILE), true);

  assert.equal(isValidTile({ tileX: 500, tileY: 500 }), false, '旧 1000×1000 世界的死值必须越界');
  assert.equal(isValidTile({ tileX: GRID_TILES, tileY: 0 }), false, '上界开区间');
  assert.equal(isValidTile({ tileX: -1, tileY: 0 }), false);
  assert.equal(isValidTile({ tileX: 1.5, tileY: 0 }), false, '非整数拒收');
  assert.equal(isValidTile({ tileX: NaN, tileY: 0 }), false);
});

test('WORLD_CENTER_TILE 落在世界中心且合法', () => {
  assert.deepEqual(WORLD_CENTER_TILE, { tileX: 37, tileY: 37 });
});

test('setCharacterTile：写入后 getCharacter 读回新 tile；跨实例重启仍在', () => {
  const dir = join(tmpdir(), 'maliang-test-pos-persist');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  s1.addCharacter(char('w1', 'c1'));
  assert.deepEqual(s1.getCharacter('w1', 'c1')?.position, WORLD_CENTER_TILE);

  assert.equal(s1.setCharacterTile('w1', 'c1', { tileX: 12, tileY: 40 }), true);
  assert.deepEqual(s1.getCharacter('w1', 'c1')?.position, { tileX: 12, tileY: 40 });

  // 重启（新实例读同一目录）后坐标仍在——落的是 characters.data 那一列
  const s2 = new WorldStore(dir);
  assert.deepEqual(s2.getCharacter('w1', 'c1')?.position, { tileX: 12, tileY: 40 });
});

test('setCharacterTile：角色不存在 → false 不动账', () => {
  const s = freshStore('nochar');
  s.createWorld('w1');
  assert.equal(s.setCharacterTile('w1', 'ghost', { tileX: 1, tileY: 1 }), false);
});

test('setPlayerTile：写入后读回；玩家不存在 → false', () => {
  const s = freshStore('player');
  assert.equal(s.setPlayerTile('nobody', { tileX: 3, tileY: 4 }), false);

  s.upsertPlayer(player('p1'));
  assert.equal(s.getPlayer('p1')?.position, undefined, '老档案无 position 字段');

  assert.equal(s.setPlayerTile('p1', { tileX: 3, tileY: 4 }), true);
  assert.deepEqual(s.getPlayer('p1')?.position, { tileX: 3, tileY: 4 });
});

test('upsertPlayer 重写档案不会抹掉已上报的 tile（world_info 重连路径）', () => {
  const s = freshStore('upsert');
  s.upsertPlayer(player('p1'));
  s.setPlayerTile('p1', { tileX: 8, tileY: 9 });

  // 模拟 server.ts world_info：从 profile 重建整个 Player，显式沿用旧 position
  const rebuilt: Player = { ...player('p1'), nickname: '改名了', position: s.getPlayer('p1')?.position };
  s.upsertPlayer(rebuilt);

  assert.equal(s.getPlayer('p1')?.nickname, '改名了');
  assert.deepEqual(s.getPlayer('p1')?.position, { tileX: 8, tileY: 9 }, 'profile 上报不该清空位置');
});
