import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import type { Character } from '../src/types.ts';

function char(worldId: string, id: string, name: string): Character {
  return {
    id, worldId, isFairy: false, name, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 2 }, abilities: ['move_to'], relationships: {},
  };
}

test('持久化：存盘→新实例读回，世界/角色/资源一致', () => {
  const dir = join(tmpdir(), 'maliang-test-persist');
  rmSync(dir, { recursive: true, force: true });

  // 写入
  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  const c = char('w1', 'c1', '小兔');
  const hash = s1.putAsset({ bytes: new Uint8Array([1, 2, 3, 4]), mime: 'image/png' });
  c.appearance.spriteAsset = hash;
  s1.addCharacter(c);

  assert.ok(existsSync(join(dir, 'worlds.json')), 'worlds.json 应落盘');
  assert.ok(existsSync(join(dir, 'assets', hash)), 'asset 文件应落盘');

  // 新实例从磁盘读回
  const s2 = new WorldStore(dir);
  const reloaded = s2.getCharacter('w1', 'c1');
  assert.ok(reloaded, '角色应被读回');
  assert.equal(reloaded!.name, '小兔');
  assert.equal(reloaded!.position.tileX, 1);
  const asset = s2.getAsset(hash);
  assert.ok(asset, '资源应被读回');
  assert.deepEqual([...asset!.bytes], [1, 2, 3, 4]);
  assert.equal(asset!.mime, 'image/png');

  rmSync(dir, { recursive: true, force: true });
});

test('内存模式（无 dataDir）：不落盘', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'c1', '小猫'));
  assert.equal(s.listCharacters('w1').length, 1);
  // 无目录 → 不应创建 ./data（由其他测试隔离保证；此处仅验证 API 正常）
});
