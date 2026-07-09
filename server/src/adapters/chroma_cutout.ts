import { PNG } from 'pngjs';
import jpeg from 'jpeg-js';
import type { CutoutAdapter, ImageBlob } from './types.ts';

// PNG IEND 块结尾标记；部分 PNG 生图结果在 IEND 之后带尾部字节，会让 pngjs 报
// "unrecognised content at end of stream"，解析前裁到此处。
const IEND = Buffer.from([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);

interface Raster {
  width: number;
  height: number;
  data: Uint8Array; // RGBA
}

function trimToPng(buf: Buffer): Buffer {
  const idx = buf.indexOf(IEND);
  return idx >= 0 ? buf.subarray(0, idx + IEND.length) : buf;
}

// 生图模型可能返回 PNG 或 JPEG，按 magic bytes 分派解码为 RGBA。
function decode(bytes: Uint8Array): Raster {
  const buf = Buffer.from(bytes);
  if (buf[0] === 0x89 && buf[1] === 0x50) {
    const png = PNG.sync.read(trimToPng(buf));
    return { width: png.width, height: png.height, data: png.data };
  }
  if (buf[0] === 0xff && buf[1] === 0xd8) {
    const j = jpeg.decode(buf, { useTArray: true, formatAsRGBA: true });
    return { width: j.width, height: j.height, data: j.data };
  }
  throw new Error('chroma: unsupported image format');
}

function encodePng(r: Raster): Uint8Array {
  const png = new PNG({ width: r.width, height: r.height });
  png.data = Buffer.from(r.data.buffer, r.data.byteOffset, r.data.byteLength);
  return new Uint8Array(PNG.sync.write(png));
}

/**
 * 给透明 PNG 主体加一圈白色 die-cut 贴纸边（纸片马里奥贴纸感），不靠生图模型画。
 * 做法：对 alpha 轮廓做 radius 次形态学膨胀，膨胀出来（原本透明、现被并入）的像素涂白不透明，
 * 主体像素原样保留（含它自己的黑描边）→ 主体外多一圈白边。radius 默认按短边 ~3.5% 取,
 * 保证缩到卡片尺寸后白边仍可见。
 */
export function addStickerBorder(input: ImageBlob, radius?: number): ImageBlob {
  const { width: w, height: h, data: d } = decode(input.bytes);
  const r = radius ?? Math.max(8, Math.round(Math.min(w, h) * 0.035));
  const n = w * h;
  const subject = new Uint8Array(n);
  for (let i = 0; i < n; i++) subject[i] = d[i * 4 + 3]! > 40 ? 1 : 0;
  let cur = subject.slice();
  let next = new Uint8Array(n);
  for (let step = 0; step < r; step++) {
    next.set(cur);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = y * w + x;
        if (cur[i]) continue;
        if (
          (x > 0 && cur[i - 1]) || (x < w - 1 && cur[i + 1]) ||
          (y > 0 && cur[i - w]) || (y < h - 1 && cur[i + w])
        ) next[i] = 1;
      }
    }
    const tmp = cur; cur = next; next = tmp;
  }
  for (let i = 0; i < n; i++) {
    if (cur[i] && !subject[i]) {
      d[i * 4] = 255; d[i * 4 + 1] = 255; d[i * 4 + 2] = 255; d[i * 4 + 3] = 255;
    }
  }
  return { bytes: encodePng({ width: w, height: h, data: d }), mime: 'image/png' };
}

/**
 * 裁到「不透明内容」的包围盒 + 四周留 pad 边（px）。
 * 生图模型吐的是大画布（实测 1408×768 横图），抠绿后角色只占其中一小块、四周大片透明；
 * 客户端按整张贴图高度归一化（paper_character.gd），留白会吃掉尺寸预算让角色显小。
 * 存库前裁到贴身盒，角色即占满显示框。只裁透明边、不改角色像素本身，故对存量原地覆盖也安全。
 * 全透明（找不到内容）时原样返回；已贴身（无可裁）时也原样返回免重新编码。
 * alphaThresh：视为不透明的最低 alpha。与 sprite_sheet.unionCropFrames 的 bbox 判定同源（单图版）。
 */
export function trimToContent(input: ImageBlob, pad = 8, alphaThresh = 8): ImageBlob {
  const { width: w, height: h, data: d } = decode(input.bytes);
  let minX = w;
  let minY = h;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (d[(y * w + x) * 4 + 3]! >= alphaThresh) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < minX) return input; // 全透明，无从裁
  minX = Math.max(0, minX - pad);
  minY = Math.max(0, minY - pad);
  maxX = Math.min(w - 1, maxX + pad);
  maxY = Math.min(h - 1, maxY + pad);
  const cw = maxX - minX + 1;
  const ch = maxY - minY + 1;
  if (cw === w && ch === h) return input; // 已贴身，免重新编码
  const out = new Uint8Array(cw * ch * 4);
  for (let y = 0; y < ch; y++) {
    const src = ((minY + y) * w + minX) * 4;
    out.set(d.subarray(src, src + cw * 4), y * cw * 4);
  }
  return { bytes: encodePng({ width: cw, height: ch, data: out }), mime: 'image/png' };
}

/** 水平镜像（朝左的立绘翻成朝右）。输出统一 PNG（保 alpha）。 */
export function flipHorizontal(input: ImageBlob): ImageBlob {
  const { width: w, height: h, data: d } = decode(input.bytes);
  for (let y = 0; y < h; y++) {
    const row = y * w;
    for (let x = 0; x < w >> 1; x++) {
      const a = (row + x) * 4;
      const b = (row + w - 1 - x) * 4;
      for (let c = 0; c < 4; c++) {
        const t = d[a + c]!;
        d[a + c] = d[b + c]!;
        d[b + c] = t;
      }
    }
  }
  return { bytes: encodePng({ width: w, height: h, data: d }), mime: 'image/png' };
}

/**
 * 绿幕抠图（纯 JS，支持 PNG/JPEG 输入，输出透明 PNG）。
 * 关键：只抠「与图像边界连通」的绿（背景是连续的），用 flood-fill 从四边扩散；
 * 角色身上的绿色装饰是内部孤岛、不与边界相连，因此被保留——避免把角色挖洞。
 * 最后对背景相邻的边缘像素做 despill，消绿边。
 */
export class ChromaKeyCutoutAdapter implements CutoutAdapter {
  async removeBackground(input: ImageBlob): Promise<ImageBlob> {
    const { width: w, height: h, data: d } = decode(input.bytes);
    const n = w * h;

    const isGreen = (i: number): boolean => {
      const r = d[i * 4]!;
      const g = d[i * 4 + 1]!;
      const b = d[i * 4 + 2]!;
      return g > 80 && g > r * 1.2 && g > b * 1.2;
    };

    // 从四边的绿色像素 flood-fill，标记连通的背景。
    const bg = new Uint8Array(n);
    const stack: number[] = [];
    const seed = (i: number): void => {
      if (!bg[i] && isGreen(i)) {
        bg[i] = 1;
        stack.push(i);
      }
    };
    for (let x = 0; x < w; x++) {
      seed(x);
      seed((h - 1) * w + x);
    }
    for (let y = 0; y < h; y++) {
      seed(y * w);
      seed(y * w + w - 1);
    }
    while (stack.length > 0) {
      const i = stack.pop()!;
      const x = i % w;
      const y = (i / w) | 0;
      if (x > 0) seed(i - 1);
      if (x < w - 1) seed(i + 1);
      if (y > 0) seed(i - w);
      if (y < h - 1) seed(i + w);
    }

    for (let i = 0; i < n; i++) {
      if (bg[i]) d[i * 4 + 3] = 0;
    }
    // 边缘 despill：保留像素若与背景相邻，压掉溢出的绿边
    for (let i = 0; i < n; i++) {
      if (bg[i] || d[i * 4 + 3] === 0) continue;
      const x = i % w;
      const y = (i / w) | 0;
      const adj =
        (x > 0 && bg[i - 1]) ||
        (x < w - 1 && bg[i + 1]) ||
        (y > 0 && bg[i - w]) ||
        (y < h - 1 && bg[i + w]);
      if (adj) {
        const r = d[i * 4]!;
        const b = d[i * 4 + 2]!;
        const maxRB = r > b ? r : b;
        if (d[i * 4 + 1]! > maxRB) d[i * 4 + 1] = maxRB;
      }
    }

    return { bytes: encodePng({ width: w, height: h, data: d }), mime: 'image/png' };
  }
}
