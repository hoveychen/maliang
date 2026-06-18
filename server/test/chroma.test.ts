import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PNG } from 'pngjs';
import { ChromaKeyCutoutAdapter } from '../src/adapters/chroma_cutout.ts';

// 合成 20x20：全绿背景；中间 6..13 的红色「角色」；角色内部 2x2 绿色「装饰岛」。
function makeImage(): Uint8Array {
  const w = 20;
  const h = 20;
  const png = new PNG({ width: w, height: h });
  const set = (x: number, y: number, r: number, g: number, b: number): void => {
    const i = (y * w + x) * 4;
    png.data[i] = r;
    png.data[i + 1] = g;
    png.data[i + 2] = b;
    png.data[i + 3] = 255;
  };
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) set(x, y, 0, 255, 0); // 绿背景
  for (let y = 6; y < 14; y++) for (let x = 6; x < 14; x++) set(x, y, 220, 40, 40); // 红角色
  set(9, 9, 0, 255, 0); // 角色内部绿装饰岛
  set(10, 9, 0, 255, 0);
  set(9, 10, 0, 255, 0);
  set(10, 10, 0, 255, 0);
  return new Uint8Array(PNG.sync.write(png));
}

test('chroma 抠图：去边界连通的绿背景，保留角色内部绿装饰', async () => {
  const out = await new ChromaKeyCutoutAdapter().removeBackground({
    bytes: makeImage(),
    mime: 'image/png',
  });
  const png = PNG.sync.read(Buffer.from(out.bytes));
  const alpha = (x: number, y: number): number => png.data[(y * 20 + x) * 4 + 3]!;
  assert.equal(alpha(0, 0), 0, '角落背景应透明');
  assert.equal(alpha(19, 19), 0, '另一角背景应透明');
  assert.equal(alpha(7, 7), 255, '角色身体应保留');
  assert.equal(alpha(9, 9), 255, '角色内部绿色装饰应保留（不被挖洞）');
});
