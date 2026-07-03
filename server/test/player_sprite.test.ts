import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';

// 玩家形象生成：描述→生图→资产 hash（不建角色）；缺描述 400；审核不过 400。
test('player-sprite: generate from description, moderated', async () => {
  const dir = join(tmpdir(), 'maliang-test-player-sprite');
  rmSync(dir, { recursive: true, force: true });
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore(dir) });
  try {
    const ok = await app.inject({
      method: 'POST',
      url: '/player-sprite',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ visualDescription: '一个可爱的小女孩小精灵，穿蓝色裙子，抱着小猫玩偶' }),
    });
    assert.equal(ok.statusCode, 200);
    const r1 = ok.json() as { spriteAsset: string };
    assert.ok(r1.spriteAsset.length > 0);
    const asset = await app.inject({ method: 'GET', url: `/assets/${r1.spriteAsset}` });
    assert.equal(asset.statusCode, 200);

    const missing = await app.inject({
      method: 'POST',
      url: '/player-sprite',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({}),
    });
    assert.equal(missing.statusCode, 400);

    const bad = await app.inject({
      method: 'POST',
      url: '/player-sprite',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ visualDescription: '一个拿着武器的暴力角色' }),
    });
    assert.equal(bad.statusCode, 400);
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
