import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';

// fairy-sprite 路由：幂等（已有 sprite 跳过）+ force 强制重生成（换形象用）。
test('fairy-sprite: idempotent by default, force regenerates', async () => {
  const dir = join(tmpdir(), 'maliang-test-fairy-sprite');
  rmSync(dir, { recursive: true, force: true });
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore(dir) });
  try {
    // default 世界由 GET 自动创建并种入小神仙
    const world = await app.inject({ method: 'GET', url: '/worlds/default' });
    assert.equal(world.statusCode, 200);

    const first = await app.inject({ method: 'POST', url: '/worlds/default/fairy-sprite' });
    assert.equal(first.statusCode, 200);
    const r1 = first.json() as { spriteAsset: string; regenerated: boolean };
    assert.equal(r1.regenerated, true);
    assert.ok(r1.spriteAsset.length > 0);

    // 再来一次：已有 sprite → 跳过
    const second = await app.inject({ method: 'POST', url: '/worlds/default/fairy-sprite' });
    const r2 = second.json() as { spriteAsset: string; regenerated: boolean };
    assert.equal(r2.regenerated, false);
    assert.equal(r2.spriteAsset, r1.spriteAsset);

    // force=true：强制重生成（mock 生图内容相同 → hash 相同，只断言重生成发生）
    const forced = await app.inject({ method: 'POST', url: '/worlds/default/fairy-sprite?force=true' });
    const r3 = forced.json() as { spriteAsset: string; regenerated: boolean };
    assert.equal(r3.regenerated, true);

    // pngBase64 直传：部署验收过的候选图（确定性替换，不走生图；隐含 force）
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);
    const uploaded = await app.inject({
      method: 'POST',
      url: '/worlds/default/fairy-sprite',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ pngBase64: png.toString('base64') }),
    });
    const r4 = uploaded.json() as { spriteAsset: string; regenerated: boolean };
    assert.equal(r4.regenerated, true);
    const asset = await app.inject({ method: 'GET', url: `/assets/${r4.spriteAsset}` });
    assert.equal(asset.statusCode, 200);
    assert.deepEqual(asset.rawPayload, png);
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
