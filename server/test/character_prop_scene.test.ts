import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character, type WorldProp } from '../src/types.ts';

/** 造一个角色；sceneId 省略 = 模拟单场景时代的存量 blob（JSON.stringify 会丢掉 undefined 键）。 */
function char(worldId: string, id: string, sceneId?: string): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId, abilities: [], relationships: {},
  };
}

function prop(id: string, sceneId?: string): WorldProp {
  return {
    id,
    spec: { name: id, palette: ['#fff'], blend: 0.2, outline: 0.04, parts: [], locomotion: { type: 'none' }, ropes: [] },
    tile: [3, 4], state: 'placed', sceneId,
  };
}

test('listCharacters 按场景过滤：不传=全世界，传=只该场景', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'v1', 'village'));
  s.addCharacter(char('w1', 'v2', 'village'));
  s.addCharacter(char('w1', 'f1', 'forest'));

  assert.equal(s.listCharacters('w1').length, 3, '不传 sceneId 返回全部');
  assert.deepEqual(s.listCharacters('w1', 'village').map((c) => c.id).sort(), ['v1', 'v2']);
  assert.deepEqual(s.listCharacters('w1', 'forest').map((c) => c.id), ['f1']);
  assert.equal(s.listCharacters('w1', 'desert').length, 0, '没有角色的场景返回空');
});

test('listProps 按场景过滤：不传=全世界，传=只该场景', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addProp('w1', prop('pv', 'village'));
  s.addProp('w1', prop('pf', 'forest'));

  assert.equal(s.listProps('w1').length, 2);
  assert.deepEqual(s.listProps('w1', 'village').map((p) => p.id), ['pv']);
  assert.deepEqual(s.listProps('w1', 'forest').map((p) => p.id), ['pf']);
});

test('缺 sceneId 的存量角色/物件按 DEFAULT_SCENE 归入', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'legacy')); // 无 sceneId
  s.addProp('w1', prop('legacyprop')); // 无 sceneId

  assert.deepEqual(s.listCharacters('w1', DEFAULT_SCENE).map((c) => c.id), ['legacy']);
  assert.deepEqual(s.listProps('w1', DEFAULT_SCENE).map((p) => p.id), ['legacyprop']);
});

test('setCharacterTile 带 sceneId：角色场景跟着位置走，跨场景不串', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'c1', 'village'));

  // 客户端在 forest 场景上报 c1 的新位置 → c1 应迁入 forest
  assert.equal(s.setCharacterTile('w1', 'c1', { tileX: 10, tileY: 20 }, 'forest'), true);

  assert.equal(s.listCharacters('w1', 'village').length, 0, 'village 里不该再有 c1');
  assert.deepEqual(s.listCharacters('w1', 'forest').map((c) => c.id), ['c1']);
  assert.deepEqual(s.getCharacter('w1', 'c1')?.position, { tileX: 10, tileY: 20 });
  assert.equal(s.getCharacter('w1', 'c1')?.sceneId, 'forest');
});

test('setCharacterTile 不传 sceneId：只更新位置，不动场景', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'c1', 'forest'));

  assert.equal(s.setCharacterTile('w1', 'c1', { tileX: 5, tileY: 6 }), true);
  assert.equal(s.getCharacter('w1', 'c1')?.sceneId, 'forest', '场景保持不变');
  assert.deepEqual(s.getCharacter('w1', 'c1')?.position, { tileX: 5, tileY: 6 });
});

test('同一 tile 在不同场景的两个角色互不覆盖', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'a', 'village'));
  s.addCharacter(char('w1', 'b', 'forest'));

  s.setCharacterTile('w1', 'a', { tileX: 12, tileY: 30 }, 'village');
  s.setCharacterTile('w1', 'b', { tileX: 12, tileY: 30 }, 'forest');

  assert.deepEqual(s.listCharacters('w1', 'village').map((c) => c.id), ['a']);
  assert.deepEqual(s.listCharacters('w1', 'forest').map((c) => c.id), ['b']);
});

test('存量迁移：缺 sceneId 的角色/物件 blob 补写 village，且幂等', () => {
  const dir = join(tmpdir(), 'maliang-test-entity-scene-migrate');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  s1.addCharacter(char('w1', 'legacy')); // 无 sceneId（存量）
  s1.addCharacter(char('w1', 'keeper', 'forest')); // 已有场景，迁移不该动
  s1.addProp('w1', prop('legacyprop')); // 无 sceneId

  // 先证实存量 blob 里确实没有 sceneId 字段（不是 undefined 被序列化）
  assert.equal(s1.getCharacter('w1', 'legacy')?.sceneId, undefined);

  // 新实例开库 → 构造函数跑迁移
  const s2 = new WorldStore(dir);
  assert.equal(s2.getCharacter('w1', 'legacy')?.sceneId, DEFAULT_SCENE, '存量角色补成 village');
  assert.equal(s2.getCharacter('w1', 'keeper')?.sceneId, 'forest', '已有场景的角色不被覆盖');
  assert.equal(s2.listProps('w1', DEFAULT_SCENE).map((p) => p.id).includes('legacyprop'), true, '存量物件补成 village');

  // 幂等：再开一次不炸、不改值
  const s3 = new WorldStore(dir);
  assert.equal(s3.getCharacter('w1', 'legacy')?.sceneId, DEFAULT_SCENE);
  assert.equal(s3.getCharacter('w1', 'keeper')?.sceneId, 'forest');
});
