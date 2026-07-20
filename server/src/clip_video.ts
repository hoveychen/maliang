// 焦点角色真视频（Video-Hero LOD）的服务端供给：把角色动画的原始绿幕 mp4（H.264，存于
// SpriteAnimRecord.clipVideos）转成 Godot 内置能读的 Ogg Theora（.ogv）。
//
// 为什么要转：Godot 4 的 VideoStreamPlayer 只吃 Ogg Theora，不认 H.264/mp4。原片是花钱生成的
// Seedance 绿幕视频（480p/24fps），转 Theora 后仍是绿幕，客户端用抠绿 shader 剔背景（见
// docs/video-hero-lod-design.md）。Theora 无 alpha，透明必须靠抠绿。
//
// 只有「正在对话的焦点角色」才拉视频（≤1 路解码，真机实测稳，见
// memory video-as-animation-tablet-decode-limit），人群仍走便宜的静态图集。
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PNG } from 'pngjs';
import type { ClipName, VideoBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';

/**
 * 低于此字节数的「视频」视为占位/损坏（测试的 mock mp4 才 9 字节，真 Seedance mp4 ~1.9MB），
 * 预生成时直接跳过——省得对着假字节 spawn ffmpeg 报错刷屏。真视频远超此阈值。
 */
const MIN_TRANSCODABLE_BYTES = 512;

const execFileP = promisify(execFile);

/**
 * mp4→ogv 转换缝（缺省真实 ffmpeg；测试注入假实现以免依赖 ffmpeg/libtheora——Homebrew 的
 * ffmpeg 不含 libtheora 编码器，见 docs/video-hero-lod-design.md「本机转 ogv 的坑」）。
 */
export type ToClipOgv = (mp4: VideoBlob) => Promise<VideoBlob>;

/**
 * H.264 mp4 → Ogg Theora ogv（`-c:v libtheora -q:v 9 -an`）。
 *
 * - `-q:v 9`：libtheora 质量 0~10，越高越清晰。原片才 480p，取 9 保清晰、体积仍小。
 * - `-an`：绿幕原片本就无音轨；显式去掉，省得容器带空音轨。
 * - 纯转码，不抽帧/不缩放/不抠绿——抠绿在客户端 GPU 做（绿幕保留），保住 24fps 观感。
 *
 * 需要 ffmpeg 带 libtheora 编码器。prod 的 Debian ffmpeg（node:26-slim + apt ffmpeg）含之
 * （2026-07-20 对 prod 镜像 sha256:e9bfd768… 实测确认）。
 */
export async function mp4ToTheoraOgv(mp4: VideoBlob): Promise<VideoBlob> {
  const dir = await mkdtemp(join(tmpdir(), 'mlogv-'));
  try {
    const inPath = join(dir, 'in.mp4');
    const outPath = join(dir, 'out.ogv');
    await writeFile(inPath, Buffer.from(mp4.bytes));
    // 焦点视频 LOD 优化:绿幕原片是 16:9、角色窄窄居中、约六成宽是绿边(实测舞舞兔占宽 39%)。
    // 白白软解被抠掉的绿最费 CPU（解码∝像素）。转码前按角色横向包围盒只裁宽（保全高），
    // 解码像素砍掉一半多。只裁宽 → 客户端几何(VIDEO_FILL 是高度占比)不变、运行时按真宽自适应，
    // 无需改客户端、新旧 ogv 混用都正确渲染。
    const cropX = await detectHorizontalContentCrop(inPath, dir);
    const vf: string[] = cropX ? ['-vf', `crop=${cropX.w}:ih:${cropX.x}:0`] : [];
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', inPath,
      ...vf,
      '-c:v', 'libtheora', '-q:v', '9', '-an',
      outPath,
    ]);
    return { bytes: new Uint8Array(await readFile(outPath)), mime: 'video/ogg' };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/** 绿主导判定（与客户端 chroma_video.gdshader 同口径）：g 明显大于 r、b。 */
function isGreenPixel(r: number, g: number, b: number): boolean {
  return g > r + 25 && g > b + 25;
}

/** 一帧 RGBA 像素（供裁剪检测的纯函数用，与 pngjs 的 {width,height,data} 兼容）。 */
export interface RgbaFrame {
  width: number;
  height: number;
  data: Uint8Array | Buffer;
}

/**
 * 纯函数：从若干 RGBA 帧算角色**横向**内容裁剪 {x,w}（列扫描非绿主导像素的 minX~maxX 并集，
 * 加边距、偶数对齐、按帧宽钳制）。省不到 ~12% 宽 / 全绿 / 无帧 → null（不值得裁）。可单测。
 */
export function computeHorizontalCrop(frames: RgbaFrame[]): { x: number; w: number } | null {
  let minX = Infinity;
  let maxX = -1;
  let frameW = 0;
  for (const f of frames) {
    frameW = f.width;
    for (let y = 0; y < f.height; y++) {
      const row = y * f.width * 4;
      for (let x = 0; x < f.width; x++) {
        const p = row + x * 4;
        if (!isGreenPixel(f.data[p]!, f.data[p + 1]!, f.data[p + 2]!)) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
    }
  }
  if (maxX < 0 || frameW === 0) return null; // 全绿/空 → 不裁
  const pad = Math.round(frameW * 0.02); // 2% 边距，防贴边削到轮廓
  let x0 = Math.max(0, Math.floor(minX) - pad);
  const x1 = Math.min(frameW - 1, Math.ceil(maxX) + pad);
  let w = x1 - x0 + 1;
  if (w >= frameW * 0.88) return null; // 省不到 ~12% 宽 → 不值得裁
  // 偶数对齐（libtheora 编码要求宽/x 为偶数）
  if (x0 % 2 === 1) x0 -= 1;
  if ((x0 + w) % 2 === 1) w += (x0 + w < frameW) ? 1 : -1;
  if (x0 + w > frameW) w = frameW - x0;
  if (w % 2 === 1) w -= 1;
  return w > 0 ? { x: x0, w } : null;
}

/**
 * 检测绿幕视频里角色横向内容裁剪：ffmpeg 采样若干帧 → pngjs 解码 → computeHorizontalCrop。
 * 只裁宽不裁高（高度占比不变，客户端几何无需改）。检测失败 → null（不裁，整帧转码，不阻断）。
 */
async function detectHorizontalContentCrop(inPath: string, dir: string): Promise<{ x: number; w: number } | null> {
  try {
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', inPath,
      '-vf', 'fps=3', // 采样 ~每 1/3 秒一帧
      '-frames:v', '12',
      join(dir, 'crop_%03d.png'),
    ], { maxBuffer: 1 << 24 }).catch(() => {});
    const files = (await readdir(dir)).filter((f) => f.startsWith('crop_') && f.endsWith('.png')).sort();
    if (files.length === 0) return null;
    const frames: RgbaFrame[] = [];
    for (const f of files) frames.push(PNG.sync.read(Buffer.from(await readFile(join(dir, f)))));
    return computeHorizontalCrop(frames);
  } catch {
    return null; // 检测失败 → 不裁，整帧转码（不阻断）
  }
}

/**
 * 预生成 clipVideos 各段的 ogv（焦点视频 LOD）：anim 生成/repack 时顺手转好、入库，返回
 * 段名→ogv 资产 hash 的 clipOgv 映射。这样孩子第一次跟某角色对话时端点直接命中缓存，
 * 不必现场惰转（省掉首次对话 ~1-2s 的转码延迟）。
 *
 * 尽力而为：某段转码失败只 warn 并跳过（端点日后仍会对缺的段惰转兜底），绝不拖垮整条 anim 生成。
 * 占位/损坏的小 blob（测试 mock mp4）直接跳过，不 spawn ffmpeg。
 */
export async function pregenerateClipOgv(
  store: WorldStore,
  clips: { name: ClipName; mp4: VideoBlob }[],
  toClipOgv: ToClipOgv = mp4ToTheoraOgv,
): Promise<Partial<Record<ClipName, string>>> {
  const out: Partial<Record<ClipName, string>> = {};
  for (const { name, mp4 } of clips) {
    if (mp4.bytes.length < MIN_TRANSCODABLE_BYTES) continue; // 占位/损坏 → 跳过
    try {
      out[name] = store.putAsset(await toClipOgv(mp4));
    } catch (err) {
      console.warn(`clip ogv 预生成失败 ${name}:`, err instanceof Error ? err.message : err);
    }
  }
  return out;
}
