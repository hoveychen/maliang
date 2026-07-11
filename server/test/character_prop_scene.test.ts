import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character } from '../src/types.ts';

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

test('listCharacters 带 sceneId 时仙女恒在：跨场景跟随玩家', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'v1', 'village'));
  s.addCharacter({ ...char('w1', 'fairy', 'village'), isFairy: true });
  s.addCharacter(char('w1', 'f1', 'forest'));

  // 仙女 sceneId=village，但任意场景查询都应带上她
  assert.deepEqual(s.listCharacters('w1', 'forest').map((c) => c.id).sort(), ['f1', 'fairy'], '森林也要有仙女');
  assert.deepEqual(s.listCharacters('w1', 'village').map((c) => c.id).sort(), ['fairy', 'v1'], '本场景不重复');
  assert.deepEqual(s.listCharacters('w1', 'desert').map((c) => c.id), ['fairy'], '空场景只有仙女');
  assert.equal(s.listCharacters('w1').length, 3, '不传 sceneId 行为不变');
});

test('缺 sceneId 的存量角色按 DEFAULT_SCENE 归入', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'legacy')); // 无 sceneId

  assert.deepEqual(s.listCharacters('w1', DEFAULT_SCENE).map((c) => c.id), ['legacy']);
});

test('setCharacterTile 跨场景上报被整条拒绝：不搬场景、不动位置（scene-drag-guard）', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'c1', 'forest'));
  const before = s.getCharacter('w1', 'c1')!.position;

  // 初载漏洞实锤过：村庄客户端把森林角色全降生在村里再上报 sceneId=village，
  // 整个森林被拖空。NPC 现在不会走 portal，跨场景上报一律视为客户端脏数据拒收。
  assert.equal(s.setCharacterTile('w1', 'c1', { tileX: 10, tileY: 20 }, 'village'), false);

  assert.equal(s.getCharacter('w1', 'c1')?.sceneId, 'forest', '场景不被拖走');
  assert.deepEqual(s.getCharacter('w1', 'c1')?.position, before, '别场景的坐标无意义，不落位');
  assert.deepEqual(s.listCharacters('w1', 'forest').map((c) => c.id), ['c1']);

  // 同场景上报照常落位
  assert.equal(s.setCharacterTile('w1', 'c1', { tileX: 10, tileY: 20 }, 'forest'), true);
  assert.deepEqual(s.getCharacter('w1', 'c1')?.position, { tileX: 10, tileY: 20 });
});

test('setCharacterTile 跨场景拒绝对缺 sceneId 的存量角色按 village 判定', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'legacy')); // 无 sceneId（存量 blob）

  // 存量角色视同 village：village 上报收，forest 上报拒
  assert.equal(s.setCharacterTile('w1', 'legacy', { tileX: 3, tileY: 4 }, 'village'), true);
  assert.equal(s.setCharacterTile('w1', 'legacy', { tileX: 9, tileY: 9 }, 'forest'), false);
  assert.deepEqual(s.getCharacter('w1', 'legacy')?.position, { tileX: 3, tileY: 4 });
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

test('存量迁移：缺 sceneId 的角色 blob 补写 village，且幂等', () => {
  const dir = join(tmpdir(), 'maliang-test-entity-scene-migrate');
  rmSync(dir, { recursive: true, force: true });

  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  s1.addCharacter(char('w1', 'legacy')); // 无 sceneId（存量）
  s1.addCharacter(char('w1', 'keeper', 'forest')); // 已有场景，迁移不该动

  // 先证实存量 blob 里确实没有 sceneId 字段（不是 undefined 被序列化）
  assert.equal(s1.getCharacter('w1', 'legacy')?.sceneId, undefined);

  // 新实例开库 → 构造函数跑迁移
  const s2 = new WorldStore(dir);
  assert.equal(s2.getCharacter('w1', 'legacy')?.sceneId, DEFAULT_SCENE, '存量角色补成 village');
  assert.equal(s2.getCharacter('w1', 'keeper')?.sceneId, 'forest', '已有场景的角色不被覆盖');

  // 幂等：再开一次不炸、不改值
  const s3 = new WorldStore(dir);
  assert.equal(s3.getCharacter('w1', 'legacy')?.sceneId, DEFAULT_SCENE);
  assert.equal(s3.getCharacter('w1', 'keeper')?.sceneId, 'forest');
});
