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
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
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
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', inPath,
      '-c:v', 'libtheora', '-q:v', '9', '-an',
      outPath,
    ]);
    return { bytes: new Uint8Array(await readFile(outPath)), mime: 'video/ogg' };
  } finally {
    await rm(dir, { recursive: true, force: true });
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
