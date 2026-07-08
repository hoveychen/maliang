// idle 动画视频 → 透明 sprite-sheet 图集。
// 流程：ffmpeg 按目标 fps 抽帧并缩放 → 逐帧抠绿（复用 ChromaKeyCutoutAdapter）→ 拼网格图集。
// 图集 + meta 交给客户端：paper shader 按 fps 推进 UV cell 播放（见 P4）。
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PNG } from 'pngjs';
import { ChromaKeyCutoutAdapter } from './adapters/chroma_cutout.ts';
import type { CutoutAdapter, ImageBlob, VideoBlob } from './adapters/types.ts';

const execFileP = promisify(execFile);

export interface SpriteSheetMeta {
  cols: number;
  rows: number;
  frameCount: number;
  fps: number;
  cellW: number;
  cellH: number;
  width: number;
  height: number;
}

export interface SpriteSheetOptions {
  /** 抽帧帧率，默认 8（idle 平缓，够顺又省帧）。 */
  fps?: number;
  /** 每帧缩放到的高度（px），默认 160（游戏里角色显示不大，160 足够清晰；
   *  相比 256 像素降到 ~39%，图集 ~2MB→~0.8MB，省传输/移动端显存）。 */
  cellH?: number;
  /** 抠绿适配器，默认 ChromaKeyCutoutAdapter（与立绘同一套绿判定）。 */
  cutout?: CutoutAdapter;
  /** 丢弃末帧（首尾闭合时末帧≈首帧，丢掉避免循环回跳定格一拍），默认 true。 */
  dropLastFrame?: boolean;
  /** 输出编码 WebP（默认 true，比 PNG 小 ~6.6x，带 alpha，Godot 原生可读）。false 出 PNG。 */
  webp?: boolean;
  /** WebP 有损质量 0-100，默认 90（q90 带 alpha 实测与 PNG 肉眼无差）。 */
  webpQuality?: number;
}

/** ffmpeg 按 fps 抽帧 + 缩放到 cellH（宽取 -2 保持比例且偶数）。 */
export async function extractFrames(
  mp4: VideoBlob,
  fps: number,
  cellH: number,
): Promise<ImageBlob[]> {
  const dir = await mkdtemp(join(tmpdir(), 'mlanim-'));
  try {
    const inPath = join(dir, 'in.mp4');
    await writeFile(inPath, Buffer.from(mp4.bytes));
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', inPath,
      '-vf', `fps=${fps},scale=-2:${cellH}`,
      join(dir, 'f_%04d.png'),
    ]);
    const files = (await readdir(dir)).filter((f) => f.startsWith('f_')).sort();
    const frames: ImageBlob[] = [];
    for (const f of files) {
      frames.push({ bytes: new Uint8Array(await readFile(join(dir, f))), mime: 'image/png' });
    }
    return frames;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/**
 * 跨帧统一裁剪：算所有帧「不透明内容」的并集包围盒，把每帧裁到同一个盒。
 * 视频是 16:9、角色居中两侧大片透明，直接打包会得到大量空白 cell（费显存）；
 * 用并集盒（而非逐帧盒）保证裁剪后各帧角色位置仍对齐，动画不抖。
 * pad：盒四周留边（px），默认 4，避免贴边。alphaThresh：视为不透明的最低 alpha。
 */
export function unionCropFrames(frames: ImageBlob[], pad = 4, alphaThresh = 8): ImageBlob[] {
  if (frames.length === 0) return frames;
  const decoded = frames.map((f) => PNG.sync.read(Buffer.from(f.bytes)));
  const W = decoded[0]!.width;
  const H = decoded[0]!.height;
  let minX = W;
  let minY = H;
  let maxX = -1;
  let maxY = -1;
  for (const p of decoded) {
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (p.data[(y * W + x) * 4 + 3]! >= alphaThresh) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
  }
  if (maxX < minX) return frames; // 全透明，不裁
  minX = Math.max(0, minX - pad);
  minY = Math.max(0, minY - pad);
  maxX = Math.min(W - 1, maxX + pad);
  maxY = Math.min(H - 1, maxY + pad);
  let cw = maxX - minX + 1;
  const ch = maxY - minY + 1;
  if (cw % 2 === 1) cw += minX + cw < W ? 1 : 0; // 宽尽量偶数（GPU 友好），越界则不强求

  return decoded.map((p) => {
    const out = new PNG({ width: cw, height: ch });
    PNG.bitblt(p, out, minX, minY, cw, ch, 0, 0);
    return { bytes: new Uint8Array(PNG.sync.write(out)), mime: 'image/png' } as ImageBlob;
  });
}

/** 把等尺寸帧拼成近正方形网格图集（透明底，bitblt 逐帧贴入）。纯函数，供单测。 */
export function packAtlas(
  frames: ImageBlob[],
  fps: number,
): { atlas: ImageBlob; meta: SpriteSheetMeta } {
  if (frames.length === 0) throw new Error('sprite sheet: no frames');
  const first = PNG.sync.read(Buffer.from(frames[0]!.bytes));
  const cellW = first.width;
  const cellH = first.height;
  const cols = Math.ceil(Math.sqrt(frames.length));
  const rows = Math.ceil(frames.length / cols);

  const atlas = new PNG({ width: cols * cellW, height: rows * cellH }); // 零初始化 = 全透明
  frames.forEach((fb, i) => {
    const p = PNG.sync.read(Buffer.from(fb.bytes));
    if (p.width !== cellW || p.height !== cellH) {
      throw new Error(`sprite sheet: frame ${i} size ${p.width}x${p.height} != ${cellW}x${cellH}`);
    }
    const cx = (i % cols) * cellW;
    const cy = Math.floor(i / cols) * cellH;
    PNG.bitblt(p, atlas, 0, 0, cellW, cellH, cx, cy);
  });

  return {
    atlas: { bytes: new Uint8Array(PNG.sync.write(atlas)), mime: 'image/png' },
    meta: { cols, rows, frameCount: frames.length, fps, cellW, cellH, width: cols * cellW, height: rows * cellH },
  };
}

/** 绿幕 idle mp4 → 透明 sprite-sheet 图集 + meta（抽帧→抠绿→打包）。 */
export async function videoToSpriteSheet(
  mp4: VideoBlob,
  opts: SpriteSheetOptions = {},
): Promise<{ atlas: ImageBlob; meta: SpriteSheetMeta }> {
  const fps = opts.fps ?? 8;
  const cellH = opts.cellH ?? 160;
  const cutout = opts.cutout ?? new ChromaKeyCutoutAdapter();

  let frames = await extractFrames(mp4, fps, cellH);
  if (opts.dropLastFrame !== false && frames.length > 2) frames = frames.slice(0, -1);
  const keyed = await Promise.all(frames.map((f) => cutout.removeBackground(f)));
  // 抠绿后两侧透明，裁到并集内容盒再打包 —— 图集去掉大片空白，省移动端显存。
  const cropped = unionCropFrames(keyed);
  const packed = packAtlas(cropped, fps);
  if (opts.webp === false) return packed;
  // PNG→WebP：q90 带 alpha 实测与 PNG 肉眼无差，体积 ~1/6.6。Godot Image.load_webp 原生可读。
  const atlas = await encodeWebp(packed.atlas, opts.webpQuality ?? 90);
  return { atlas, meta: packed.meta };
}

/** PNG 图集 → WebP（cwebp，保 alpha）。cwebp 由 Dockerfile 的 webp 包提供。 */
export async function encodeWebp(png: ImageBlob, quality = 90): Promise<ImageBlob> {
  const dir = await mkdtemp(join(tmpdir(), 'mlwebp-'));
  try {
    const inP = join(dir, 'a.png');
    const outP = join(dir, 'a.webp');
    await writeFile(inP, Buffer.from(png.bytes));
    await execFileP('cwebp', ['-quiet', '-q', String(quality), '-alpha_q', '100', inP, '-o', outP]);
    return { bytes: new Uint8Array(await readFile(outP)), mime: 'image/webp' };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
