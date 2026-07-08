import { test } from 'node:test';
import assert from 'node:assert';
import { PNG } from 'pngjs';
import { packAtlas, unionCropFrames } from '../src/sprite_sheet.ts';
import { ChromaKeyCutoutAdapter } from '../src/adapters/chroma_cutout.ts';
import type { ImageBlob } from '../src/adapters/types.ts';

// 造一张纯色不透明帧（用于 packAtlas 几何验证）。
function solidFrame(w: number, h: number, rgb: [number, number, number]): ImageBlob {
  const png = new PNG({ width: w, height: h });
  for (let i = 0; i < w * h; i++) {
    png.data[i * 4] = rgb[0];
    png.data[i * 4 + 1] = rgb[1];
    png.data[i * 4 + 2] = rgb[2];
    png.data[i * 4 + 3] = 255;
  }
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

// 绿底 + 中心红块（验证抠绿：绿→透明，红保留）。
function greenFrameWithRed(w: number, h: number): ImageBlob {
  const png = new PNG({ width: w, height: h });
  for (let i = 0; i < w * h; i++) {
    png.data[i * 4] = 0;
    png.data[i * 4 + 1] = 177;
    png.data[i * 4 + 2] = 64;
    png.data[i * 4 + 3] = 255;
  }
  for (let y = h / 4; y < (h * 3) / 4; y++) {
    for (let x = w / 4; x < (w * 3) / 4; x++) {
      const i = ((y | 0) * w + (x | 0)) * 4;
      png.data[i] = 220;
      png.data[i + 1] = 30;
      png.data[i + 2] = 30;
    }
  }
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

test('packAtlas: 3 帧拼成近正方网格，meta 尺寸自洽', () => {
  const frames = [
    solidFrame(20, 30, [255, 0, 0]),
    solidFrame(20, 30, [0, 255, 0]),
    solidFrame(20, 30, [0, 0, 255]),
  ];
  const { atlas, meta } = packAtlas(frames, 8);
  assert.equal(meta.frameCount, 3);
  assert.equal(meta.cols, 2); // ceil(sqrt(3))
  assert.equal(meta.rows, 2); // ceil(3/2)
  assert.equal(meta.cellW, 20);
  assert.equal(meta.cellH, 30);
  assert.equal(meta.fps, 8);
  assert.equal(meta.width, 40);
  assert.equal(meta.height, 60);

  const png = PNG.sync.read(Buffer.from(atlas.bytes));
  assert.equal(png.width, 40);
  assert.equal(png.height, 60);
  // 帧0(红) 在 cell(0,0) 左上
  assert.deepEqual([png.data[0], png.data[1], png.data[2]], [255, 0, 0]);
  // 帧1(绿) 在 cell(1,0)：x=20
  const i1 = (0 * 40 + 20) * 4;
  assert.deepEqual([png.data[i1], png.data[i1 + 1], png.data[i1 + 2]], [0, 255, 0]);
  // 帧2(蓝) 在 cell(0,1)：y=30
  const i2 = (30 * 40 + 0) * 4;
  assert.deepEqual([png.data[i2], png.data[i2 + 1], png.data[i2 + 2]], [0, 0, 255]);
  // 第4格(空)透明
  const i3 = (30 * 40 + 20) * 4;
  assert.equal(png.data[i3 + 3], 0);
});

test('packAtlas: 帧尺寸不一致抛错', () => {
  assert.throws(() =>
    packAtlas([solidFrame(20, 30, [255, 0, 0]), solidFrame(21, 30, [0, 255, 0])], 8),
  );
});

// 透明底 + 单个不透明点（验证并集裁剪）。
function dotFrame(w: number, h: number, dx: number, dy: number): ImageBlob {
  const png = new PNG({ width: w, height: h }); // 零初始化=全透明
  const i = (dy * w + dx) * 4;
  png.data[i] = 200;
  png.data[i + 1] = 50;
  png.data[i + 2] = 50;
  png.data[i + 3] = 255;
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

test('unionCropFrames: 裁到跨帧内容并集，各帧同尺寸且变小', () => {
  const frames = [dotFrame(40, 40, 10, 10), dotFrame(40, 40, 20, 25)];
  const cropped = unionCropFrames(frames, 4);
  const a = PNG.sync.read(Buffer.from(cropped[0]!.bytes));
  const b = PNG.sync.read(Buffer.from(cropped[1]!.bytes));
  // 各帧尺寸一致（对齐）
  assert.equal(a.width, b.width);
  assert.equal(a.height, b.height);
  // 明显小于原 40x40（并集盒 ~x[6..24] y[6..29] + pad）
  assert.ok(a.width < 40 && a.height < 40, `裁剪后应变小，得 ${a.width}x${a.height}`);
  assert.ok(a.width >= 15 && a.height >= 20, '应覆盖两点的并集');
  // 帧0 的点(10,10) 落在裁剪坐标 (10-minX, 10-minY)，minX=minY=6 → (4,4)
  const p = (4 * a.width + 4) * 4;
  assert.equal(a.data[p + 3], 255, '帧0 的点应保留');
});

test('抠绿复用: 绿帧过 ChromaKeyCutout 后绿透明、红保留（图集帧的抠像基础）', async () => {
  const cut = new ChromaKeyCutoutAdapter();
  const out = await cut.removeBackground(greenFrameWithRed(40, 40));
  const png = PNG.sync.read(Buffer.from(out.bytes));
  // 角落原是绿背景 → 透明
  assert.equal(png.data[3], 0, '角落绿应变透明');
  // 中心红 → 不透明且仍偏红
  const c = (20 * 40 + 20) * 4;
  assert.equal(png.data[c + 3], 255, '中心红应保留不透明');
  assert.ok(png.data[c]! > 150 && png.data[c + 1]! < 120, '中心应仍是红');
});
