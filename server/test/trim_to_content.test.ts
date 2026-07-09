import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PNG } from 'pngjs';
import { trimToContent } from '../src/adapters/chroma_cutout.ts';

/**
 * 合成 100x100 透明画布，中间 (40..59, 30..69) 放一块不透明红色「角色」
 * （20 宽 × 40 高），四周全透明 —— 模拟生图大画布 + 角色居中留白。
 */
function makeCanvas(): Uint8Array {
  const w = 100;
  const h = 100;
  const png = new PNG({ width: w, height: h }); // 零初始化 = 全透明
  for (let y = 30; y < 70; y++) {
    for (let x = 40; x < 60; x++) {
      const i = (y * w + x) * 4;
      png.data[i] = 220;
      png.data[i + 1] = 40;
      png.data[i + 2] = 40;
      png.data[i + 3] = 255;
    }
  }
  return new Uint8Array(PNG.sync.write(png));
}

test('trimToContent：裁到角色包围盒 + pad，角色占满输出', () => {
  const pad = 8;
  const out = trimToContent({ bytes: makeCanvas(), mime: 'image/png' }, pad);
  const png = PNG.sync.read(Buffer.from(out.bytes));
  // 内容盒 20x40，四周各 +8 → 36x56
  assert.equal(png.width, 20 + pad * 2, '宽 = 内容宽 + 两侧 pad');
  assert.equal(png.height, 40 + pad * 2, '高 = 内容高 + 上下 pad');
  // 角色占输出高度比例应远高于原图（原图 40/100=40% → 裁后 40/56≈71%）
  assert.ok(40 / png.height > 0.6, '裁后角色应占满多数高度');
  // pad 区应透明，中心应不透明
  const alpha = (x: number, y: number): number => png.data[(y * png.width + x) * 4 + 3]!;
  assert.equal(alpha(0, 0), 0, 'pad 角落应透明');
  assert.equal(alpha(pad, pad), 255, '内容左上角应不透明');
  assert.equal(alpha(png.width - 1 - pad, png.height - 1 - pad), 255, '内容右下角应不透明');
});

test('trimToContent：pad 不越界（内容贴近边缘时 clamp）', () => {
  const w = 30;
  const h = 30;
  const png = new PNG({ width: w, height: h });
  // 内容铺满整张（0..29）→ 无可裁，原样返回
  for (let i = 0; i < w * h; i++) png.data[i * 4 + 3] = 255;
  const src = new Uint8Array(PNG.sync.write(png));
  const out = trimToContent({ bytes: src, mime: 'image/png' }, 8);
  const outPng = PNG.sync.read(Buffer.from(out.bytes));
  assert.equal(outPng.width, w, '已贴身：宽不变');
  assert.equal(outPng.height, h, '已贴身：高不变');
});

test('trimToContent：全透明输入原样返回，不崩', () => {
  const png = new PNG({ width: 16, height: 16 }); // 全透明
  const src = { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' as const };
  const out = trimToContent(src, 8);
  assert.equal(out.bytes, src.bytes, '全透明应原样返回同一引用');
});
