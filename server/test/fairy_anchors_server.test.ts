// 仙子锚点落库（fairy-anchors-server，docs/character-anchors-design.md §5）：
// 世界里的仙子用服务端 generateSprite 生的立绘，此前 /worlds/:id/fairy-sprite 故意丢掉
// generateSprite 返回的 anchors（"锚点不落"），让客户端走 alpha 兜底。改为像 NPC 一样落
// appearance.anchors，每个仙子用自己立绘的真 vision 锚点（消除唯一的非 vision 例外）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PNG } from 'pngjs';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { buildServer, seedFairy } from '../src/server.ts';

function bodyPngBase64(): string {
  // 身体矩形覆盖 mock 锚点(0.5,0.05)/(0.2,0.55)/(0.8,0.55) 的 3% 校验半径，让 source 记 vision。
  const png = new PNG({ width: 100, height: 100 });
  for (let y = 3; y <= 97; y++) {
    for (let x = 15; x <= 85; x++) {
      const i = (y * 100 + x) * 4;
      png.data[i] = 200; png.data[i + 1] = 100; png.data[i + 2] = 50; png.data[i + 3] = 255;
    }
  }
  return PNG.sync.write(png).toString('base64');
}

test('fairy-sprite：生成仙子立绘时落 anchors（不再"锚点不落"）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.addCharacter(seedFairy('w1'));
  const app = await buildServer({ adapters: createMockAdapters(), store });
  const res = await app.inject({ method: 'POST', url: '/worlds/w1/fairy-sprite' });
  assert.equal(res.statusCode, 200);
  const fairy = store.listCharacters('w1').find((c) => c.isFairy);
  assert.ok(fairy?.appearance.spriteAsset, '应生成立绘');
  assert.ok(fairy?.appearance.anchors, '仙子立绘应落 anchors（与 NPC 同款 vision 检测）');
  assert.ok(['vision', 'fallback'].includes(fairy!.appearance.anchors!.source));
});

test('fairy-sprite：外部提供 PNG 也落 anchors', async () => {
  const store = new WorldStore();
  store.createWorld('w2');
  store.addCharacter(seedFairy('w2'));
  const app = await buildServer({ adapters: createMockAdapters(), store });
  const res = await app.inject({ method: 'POST', url: '/worlds/w2/fairy-sprite', payload: { pngBase64: bodyPngBase64() } });
  assert.equal(res.statusCode, 200);
  const fairy = store.listCharacters('w2').find((c) => c.isFairy);
  assert.ok(fairy?.appearance.anchors, '提供 PNG 的仙子也应落 anchors');
});
