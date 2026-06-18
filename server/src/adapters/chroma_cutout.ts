import { PNG } from 'pngjs';
import type { CutoutAdapter, ImageBlob } from './types.ts';

/**
 * 绿幕抠图（移植 worldlet ChromaKey 思路，纯 JS / pngjs）。
 * - 强绿像素 → 全透明。
 * - 边缘溢出绿（绿大于 max(红,蓝)）→ 去溢出（despill），消绿边。
 */
export class ChromaKeyCutoutAdapter implements CutoutAdapter {
  async removeBackground(input: ImageBlob): Promise<ImageBlob> {
    const png = PNG.sync.read(Buffer.from(input.bytes));
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
