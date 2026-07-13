import { test } from 'node:test';
import assert from 'node:assert';
import { PNG } from 'pngjs';
import { compositeOnGreen } from '../src/adapters/openrouter_video.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { ImageBlob } from '../src/adapters/types.ts';

// 造一张透明底 PNG，中心一块不透明红。
function transparentSprite(w: number, h: number): ImageBlob {
  const png = new PNG({ width: w, height: h });
  for (let i = 0; i < w * h; i++) {
    png.data[i * 4] = 255;
    png.data[i * 4 + 1] = 0;
    png.data[i * 4 + 2] = 0;
    png.data[i * 4 + 3] = 0; // 全透明
  }
  // 中心不透明红块
  const cx = w >> 1;
  const cy = h >> 1;
  const idx = (cy * w + cx) * 4;
  png.data[idx + 3] = 255;
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

test('compositeOnGreen: 竖立绘铺成 16:9 纯绿画布，角色像素保留', () => {
  const sprite = transparentSprite(90, 160); // 9:16 竖图
  const out = compositeOnGreen(sprite);
  const png = PNG.sync.read(Buffer.from(out.bytes));

  // 16:9（含即可，允许 1px 取整误差）
  const ratio = png.width / png.height;
  assert.ok(Math.abs(ratio - 16 / 9) < 0.02, `期望 ~16:9，得 ${png.width}x${png.height}`);
  assert.equal(png.height, 160, '高度保持立绘高');

  // 角落 = 纯 chroma 绿、不透明
  const c = 0;
  assert.deepEqual(
    [png.data[c], png.data[c + 1], png.data[c + 2], png.data[c + 3]],
    [0, 177, 64, 255],
    '角落应为纯绿不透明',
  );

  // 输出全不透明（视频不带 alpha）
  let anyTransparent = false;
  for (let i = 0; i < png.width * png.height; i++) {
    if (png.data[i * 4 + 3] !== 255) anyTransparent = true;
  }
  assert.equal(anyTransparent, false, '合成后不应有透明像素');

  // 中心那块不透明红被合成保留（红通道高、绿通道低）
  const ox = ((png.width - 90) / 2) | 0;
  const centerX = ox + 45;
  const centerY = 80;
  const di = (centerY * png.width + centerX) * 4;
  assert.ok(png.data[di]! > 200 && png.data[di + 1]! < 80, '中心应保留红色角色像素');
});

test('compositeOnGreen: 横立绘也铺成 16:9（按宽算高）', () => {
  const sprite = transparentSprite(320, 100); // 很宽
  const out = compositeOnGreen(sprite);
  const png = PNG.sync.read(Buffer.from(out.bytes));
  assert.equal(png.width, 320, '宽图宽度保持');
  assert.ok(Math.abs(png.width / png.height - 16 / 9) < 0.02);
});

test('mock video adapter: 每段各返回一段 mp4，且三段字节互不相同', async () => {
  const adapters = createMockAdapters();
  const sprite = transparentSprite(64, 64);
  const clips = await Promise.all(
    (['idle', 'moving', 'talking'] as const).map((c) => adapters.video.generateClip(sprite, c)),
  );
  for (const v of clips) {
    assert.equal(v.mime, 'video/mp4');
    assert.ok(v.bytes.length > 0);
  }
  // 资产库内容寻址：三段若字节相同会塌成同一个 hash，clipVideos 就分不出段来。
  const distinct = new Set(clips.map((v) => Buffer.from(v.bytes).toString('hex')));
  assert.equal(distinct.size, 3, '三段 stub 应互不相同');
});
