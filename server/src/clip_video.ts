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
import type { VideoBlob } from './adapters/types.ts';

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
