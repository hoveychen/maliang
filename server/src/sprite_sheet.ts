// 角色动画视频 → 透明 sprite-sheet 图集。
// 流程：ffmpeg 按目标 fps 原尺寸抽帧 → 逐帧软抠绿 → alpha 预乘后缩放 → 拼网格图集。
// 图集 + meta 交给客户端：paper shader 按 fps 推进 UV cell 播放。
//
// 多段（idle/moving/talking）：三段帧打进「同一张图集」，且共用「同一个并集裁剪盒」。
// 后者是硬要求——各段独立裁剪会得到不同的 cellW/cellH，客户端按 cellH 归一化世界高度
// （PaperCharacter.play_anim），切段时角色身高就会跳一下。共用盒还顺带让三段只下一次、
// 只占一张纹理，且切段不必重算几何。
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PNG } from 'pngjs';
import { ChromaKeyCutoutAdapter } from './adapters/chroma_cutout.ts';
import type { ClipName, CutoutAdapter, ImageBlob, VideoBlob } from './adapters/types.ts';

const execFileP = promisify(execFile);

export type { ClipName };
/**
 * 实际生成/打包的段，也是图集里的段序。
 *
 * **注意没有 moving** —— 走路观感是客户端程序化做的（world.gd 的踏步弹跳 + 左右摇摆 +
 * 下摆飘动），不是生成的图集段。实测（舞舞兔，2026-07-14）：Seedance 做不出这些角色的
 * 行走循环，腿常被裙子/身体挡住，模型做不出迈步就自己改成原地转身摇摆，还把道具换到
 * 另一只手（角色外观都变了），横向漂 0.87m（换算到游戏里）而上下只颠 0.21m——走路本该
 * 以上下为主，正好反了。收紧 prompt（禁转身/禁横移/正面行走循环）只把漂移从 49px 降到
 * 37px，没解决。详见 openrouter_video.ts 的 CLIP_PROMPTS 注释。
 *
 * ClipName 仍保留 'moving'：客户端每帧照常按状态请求 "moving" 段，图集里没有就回落播
 * idle（PaperCharacter._range_of）。哪天真做出可用的行走循环，把它加回这里即可自动生效。
 */
export const CLIP_NAMES: readonly ClipName[] = ['idle', 'talking'] as const;

/** 某段在图集里的帧区间（行主序连续下标，可跨行）。 */
export interface ClipRange {
  /** 段首帧在图集里的全局下标。 */
  start: number;
  /** 段内帧数。 */
  count: number;
}

export interface SpriteSheetMeta {
  cols: number;
  rows: number;
  frameCount: number;
  fps: number;
  cellW: number;
  cellH: number;
  width: number;
  height: number;
  /**
   * 段名 → 帧区间。缺省（老图集，v1）= 整张图集就是一段 idle，客户端按 idle-only 处理。
   * 新图集（v2）总是三段齐全。
   */
  clips?: Partial<Record<ClipName, ClipRange>>;
}

export interface SpriteSheetOptions {
  /** 抽帧帧率，默认 8（idle 平缓，够顺又省帧）。 */
  fps?: number;
  /**
   * 每帧缩放到的高度（px），默认 256。
   * 实测：源立绘/idle 视频里角色竖向占帧高约 86~93%（几乎贴满），所以抽帧高度 ≈ 角色高度——
   * 竖向没有可省的留白，唯一决定动画清晰度的就是这个高度。旧值 160 让角色只有 ~149px 高，
   * 游戏里明显糊于小仙子（其图集 cell 216×160）。提到 256 → 角色约 ~220px 高，追平/超过仙子。
   * 横向留白由 unionCropFrames 裁掉、不进最终图集，故提高度只按角色比例增存储（非整帧平方级）。
   */
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

/** ffmpeg 只按 fps 原尺寸抽帧。必须在缩放前抠绿，否则采样会把绿幕再次混进主体轮廓。 */
export async function extractFrames(
  mp4: VideoBlob,
  fps: number,
): Promise<ImageBlob[]> {
  const dir = await mkdtemp(join(tmpdir(), 'mlanim-'));
  try {
    const inPath = join(dir, 'in.mp4');
    await writeFile(inPath, Buffer.from(mp4.bytes));
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', inPath,
      '-vf', `fps=${fps}`,
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

function premultiply(frame: ImageBlob): ImageBlob {
  const png = PNG.sync.read(Buffer.from(frame.bytes));
  for (let i = 0; i < png.width * png.height; i++) {
    const p = i * 4;
    const a = png.data[p + 3]! / 255;
    png.data[p] = Math.round(png.data[p]! * a);
    png.data[p + 1] = Math.round(png.data[p + 1]! * a);
    png.data[p + 2] = Math.round(png.data[p + 2]! * a);
  }
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

function unpremultiply(frame: ImageBlob): ImageBlob {
  const png = PNG.sync.read(Buffer.from(frame.bytes));
  for (let i = 0; i < png.width * png.height; i++) {
    const p = i * 4;
    const a = png.data[p + 3]!;
    if (a <= 1) {
      png.data[p] = 0;
      png.data[p + 1] = 0;
      png.data[p + 2] = 0;
      continue;
    }
    png.data[p] = Math.min(255, Math.round((png.data[p]! * 255) / a));
    png.data[p + 1] = Math.min(255, Math.round((png.data[p + 1]! * 255) / a));
    png.data[p + 2] = Math.min(255, Math.round((png.data[p + 2]! * 255) / a));
  }
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

/**
 * 抠绿后的 RGBA 帧缩到目标高度。RGB 先乘 alpha，再交给 ffmpeg Lanczos 缩放，最后反预乘；
 * 否则透明区残留的绿 RGB 会在缩放时重新渗进半透明轮廓。
 */
export async function resizeKeyedFrames(frames: ImageBlob[], cellH: number): Promise<ImageBlob[]> {
  if (frames.length === 0) return frames;
  const dir = await mkdtemp(join(tmpdir(), 'mlscale-'));
  try {
    await Promise.all(frames.map(async (frame, i) => {
      const name = `in_${String(i + 1).padStart(4, '0')}.png`;
      await writeFile(join(dir, name), Buffer.from(premultiply(frame).bytes));
    }));
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', join(dir, 'in_%04d.png'),
      '-vf', `scale=-2:${cellH}:flags=lanczos`,
      '-frames:v', String(frames.length),
      '-pix_fmt', 'rgba',
      join(dir, 'out_%04d.png'),
    ]);
    const files = (await readdir(dir)).filter((f) => f.startsWith('out_')).sort();
    return Promise.all(files.map(async (f) => unpremultiply({
      bytes: new Uint8Array(await readFile(join(dir, f))),
      mime: 'image/png',
    })));
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

  // cell 宽高一律向上取到 4 的倍数 —— 这是给客户端 GPU 块压缩（ETC2/S3TC）留的地基，
  // 不是随手的"GPU 友好"。块压缩以 4×4 像素为一块：cellW 不是 4 的倍数时，第 k 格的
  // 起始列 k*cellW 就落在块的中间，同一个块会同时压到「上一格的右边缘」和「这一格的
  // 左边缘」—— 压完帧与帧之间串色。对齐到 4 之后每格都从块边界开始，串色不可能发生。
  // 顺带：cols*cellW 也必然是 4 的倍数，整张图集不会被 Godot 静默 resize（实测 166 宽
  // 会被悄悄改成 168，那会让所有 UV 算错格）。
  const cw = align4(maxX - minX + 1);
  const ch = align4(maxY - minY + 1);
  // 对齐多出来的那几列/行留透明：只在右/下补，角色在格内的位置不变（各帧仍对齐）。
  const copyW = Math.min(cw, W - minX);
  const copyH = Math.min(ch, H - minY);

  return decoded.map((p) => {
    const out = new PNG({ width: cw, height: ch }); // 零初始化 = 全透明
    PNG.bitblt(p, out, minX, minY, copyW, copyH, 0, 0);
    return { bytes: new Uint8Array(PNG.sync.write(out)), mime: 'image/png' } as ImageBlob;
  });
}

/** 向上取到 4 的倍数。 */
function align4(n: number): number {
  return (n + 3) & ~3;
}

/**
 * 把等尺寸帧拼成近正方形网格图集（透明底，bitblt 逐帧贴入）。纯函数，供单测。
 * clips：段名 → 帧区间（下标须落在 frames 内）。省略则不写 meta.clips（= 老的单段 idle 图集）。
 */
export function packAtlas(
  frames: ImageBlob[],
  fps: number,
  clips?: Partial<Record<ClipName, ClipRange>>,
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

  const meta: SpriteSheetMeta = {
    cols, rows, frameCount: frames.length, fps, cellW, cellH,
    width: cols * cellW, height: rows * cellH,
  };
  if (clips) {
    for (const [name, r] of Object.entries(clips)) {
      if (r.count <= 0 || r.start < 0 || r.start + r.count > frames.length) {
        throw new Error(`sprite sheet: clip ${name} 区间 [${r.start},${r.start + r.count}) 越界(共 ${frames.length} 帧)`);
      }
    }
    meta.clips = clips;
  }
  return {
    atlas: { bytes: new Uint8Array(PNG.sync.write(atlas)), mime: 'image/png' },
    meta,
  };
}

/** 一段绿幕视频 → 抠好绿的等尺寸帧（尚未跨段统一裁剪）。 */
async function keyedFramesOf(
  mp4: VideoBlob,
  fps: number,
  cellH: number,
  cutout: CutoutAdapter,
  dropLast: boolean,
): Promise<ImageBlob[]> {
  let frames = await extractFrames(mp4, fps);
  if (dropLast && frames.length > 2) frames = frames.slice(0, -1);
  const keyed = await Promise.all(frames.map((f) => cutout.removeBackground(f)));
  return resizeKeyedFrames(keyed, cellH);
}

/** 单段绿幕 mp4 → 透明 sprite-sheet 图集 + meta（抽帧→抠绿→打包）。老路径，meta 不带 clips。 */
export async function videoToSpriteSheet(
  mp4: VideoBlob,
  opts: SpriteSheetOptions = {},
): Promise<{ atlas: ImageBlob; meta: SpriteSheetMeta }> {
  const fps = opts.fps ?? 8;
  const cutout = opts.cutout ?? new ChromaKeyCutoutAdapter();
  const keyed = await keyedFramesOf(mp4, fps, opts.cellH ?? 256, cutout, opts.dropLastFrame !== false);
  // 抠绿后两侧透明，裁到并集内容盒再打包 —— 图集去掉大片空白，省移动端显存。
  const packed = packAtlas(unionCropFrames(keyed), fps);
  return finishAtlas(packed, opts);
}

/**
 * 多段绿幕 mp4（idle/moving/talking）→ 一张三段图集 + 带 clips 的 meta。
 *
 * 关键：三段的帧**先合到一起再 unionCropFrames**，所以共用同一个裁剪盒 → 同一个 cellW×cellH。
 * 分开裁会让每段 cell 尺寸各异，客户端 pixel_size = world_height/cellH 就会随段变化，
 * 切段瞬间角色身高抽一下。段序 = 传入顺序，帧在图集里连续排布（行主序，可跨行）。
 */
export async function videosToSpriteSheet(
  clips: { name: ClipName; mp4: VideoBlob }[],
  opts: SpriteSheetOptions = {},
): Promise<{ atlas: ImageBlob; meta: SpriteSheetMeta }> {
  if (clips.length === 0) throw new Error('sprite sheet: no clips');
  const fps = opts.fps ?? 8;
  const cellH = opts.cellH ?? 256;
  const cutout = opts.cutout ?? new ChromaKeyCutoutAdapter();
  const dropLast = opts.dropLastFrame !== false;

  const perClip = await Promise.all(
    clips.map((c) => keyedFramesOf(c.mp4, fps, cellH, cutout, dropLast)),
  );

  const ranges: Partial<Record<ClipName, ClipRange>> = {};
  let cursor = 0;
  clips.forEach((c, i) => {
    const n = perClip[i]!.length;
    if (n === 0) throw new Error(`sprite sheet: clip ${c.name} 抽不到帧`);
    ranges[c.name] = { start: cursor, count: n };
    cursor += n;
  });

  // 全段合流后统一裁剪 —— 共用盒（见函数注释）。
  const cropped = unionCropFrames(perClip.flat());
  const packed = packAtlas(cropped, fps, ranges);
  return finishAtlas(packed, opts);
}

/** PNG 图集按 opts 转 WebP（默认转）。 */
async function finishAtlas(
  packed: { atlas: ImageBlob; meta: SpriteSheetMeta },
  opts: SpriteSheetOptions,
): Promise<{ atlas: ImageBlob; meta: SpriteSheetMeta }> {
  if (opts.webp === false) return packed;
  // PNG→WebP：q90 带 alpha 实测与 PNG 肉眼无差，体积 ~1/6.6。Godot Image.load_webp 原生可读。
  return { atlas: await encodeWebp(packed.atlas, opts.webpQuality ?? 90), meta: packed.meta };
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
