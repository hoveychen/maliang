import { PNG } from 'pngjs';
import type { CutoutAdapter, ImageBlob } from './types.ts';

/**
 * 绿幕抠图（移植 worldlet ChromaKey 思路，纯 JS / pngjs）。
 * - 强绿像素 → 全透明。
 * - 边缘溢出绿（绿大于 max(红,蓝)）→ 去溢出（despill），消绿边。
 */
// PNG IEND 块结尾标记；部分生图结果在 IEND 之后带尾部字节，会让 pngjs 报
// "unrecognised content at end of stream"，解析前裁到此处。
const IEND = Buffer.from([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);

function trimToPng(bytes: Uint8Array): Buffer {
  const buf = Buffer.from(bytes);
  const idx = buf.indexOf(IEND);
  return idx >= 0 ? buf.subarray(0, idx + IEND.length) : buf;
}

export class ChromaKeyCutoutAdapter implements CutoutAdapter {
  async removeBackground(input: ImageBlob): Promise<ImageBlob> {
    const png = PNG.sync.read(trimToPng(input.bytes));
    const d = png.data; // RGBA
    for (let i = 0; i < d.length; i += 4) {
      const r = d[i]!;
      const g = d[i + 1]!;
      const b = d[i + 2]!;
      const maxRB = r > b ? r : b;
      if (g > 90 && g > r * 1.35 && g > b * 1.35) {
        d[i + 3] = 0; // 抠掉
      } else if (g > maxRB) {
        d[i + 1] = maxRB; // despill：压掉绿边
      }
    }
    const out = PNG.sync.write(png);
    return { bytes: new Uint8Array(out), mime: 'image/png' };
  }
}
