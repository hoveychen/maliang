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
