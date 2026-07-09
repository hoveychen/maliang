import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PNG } from 'pngjs';
import { addStickerBorder } from '../src/adapters/chroma_cutout.ts';

/** 造一张 w×h 全透明、中间一块不透明红方块的 PNG。 */
function squareOnTransparent(w: number, h: number, sx: number, sy: number, sw: number, sh: number) {
  const png = new PNG({ width: w, height: h });
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      const inside = x >= sx && x < sx + sw && y >= sy && y < sy + sh;
      png.data[i] = 220; png.data[i + 1] = 40; png.data[i + 2] = 40;
      png.data[i + 3] = inside ? 255 : 0;
    }
  }
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

function decode(bytes: Uint8Array) {
  return PNG.sync.read(Buffer.from(bytes));
}

test('addStickerBorder：主体外围多一圈白色不透明边,主体像素不变', () => {
  const w = 80, h = 80;
  const img = squareOnTransparent(w, h, 30, 30, 20, 20); // 中间 20×20 红块
  const out = decode(addStickerBorder(img, 6).bytes);
  const at = (x: number, y: number) => {
    const i = (y * w + x) * 4;
    return { r: out.data[i], g: out.data[i + 1], b: out.data[i + 2], a: out.data[i + 3] };
  };
  // 主体中心：仍是红、不透明
  const c = at(40, 40);
  assert.equal(c.a, 255);
  assert.ok(c.r! > 180 && c.g! < 80, '主体中心仍红');
  // 紧贴主体外一格（原透明）：现在应是白色不透明（白边）
  const border = at(28, 40); // 主体左边 x=30,往左 2px 在膨胀 6 内
  assert.equal(border.a, 255, '白边处不透明');
  assert.ok(border.r === 255 && border.g === 255 && border.b === 255, '白边处是白色');
  // 远离主体（超出膨胀半径）：仍透明
  const far = at(2, 2);
  assert.equal(far.a, 0, '远处仍透明');
});

test('addStickerBorder：全透明输入 → 不崩,仍全透明', () => {
  const w = 16, h = 16;
  const img = squareOnTransparent(w, h, 0, 0, 0, 0); // 无主体
  const out = decode(addStickerBorder(img, 4).bytes);
  let anyOpaque = false;
  for (let i = 3; i < out.data.length; i += 4) if (out.data[i]! > 0) anyOpaque = true;
  assert.equal(anyOpaque, false, '无主体则无白边,仍全透明');
});
