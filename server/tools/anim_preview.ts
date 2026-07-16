// 角色三段动画的「看片」工具：真调 Seedance 生成 idle/moving/talking 三段，本地打成图集，
// 把三段原片 + 图集 + 逐段横条预览图全落到磁盘 —— 不写数据库、不碰 prod。
//
// 目的：prompt 是否靠谱只有看片才知道（moving 会不会真往前走出画面？talking 口型像不像？），
// 花 ~$0.14 先验一个角色，再决定要不要全量回填。
//
// 用法：
//   cd server
//   OPENROUTER_API_KEY=... node --experimental-strip-types tools/anim_preview.ts <spriteHash> [outDir] [clip...]
// spriteHash 从 prod 的 /worlds/default 拿（characters[].appearance.spriteAsset）。
// 末尾可只列要重生成的段（如 `moving`）——调 prompt 时只重跑那一段，省钱；其余段沿用
// outDir 里已有的 mp4（所以图集仍是完整三段）。
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { PNG } from 'pngjs';
import { OpenRouterVideoAdapter } from '../src/adapters/openrouter_video.ts';
import { CLIP_NAMES, videosToSpriteSheet } from '../src/sprite_sheet.ts';
import type { ClipName, ImageBlob, VideoBlob } from '../src/adapters/types.ts';

const execFileP = promisify(execFile);
const API_BASE = process.env.MALIANG_API_BASE ?? 'https://maliang-api.muveeai.com';

async function main(): Promise<void> {
  const spriteHash = process.argv[2];
  const outDir = process.argv[3] ?? join(process.cwd(), 'anim_preview_out');
  if (!spriteHash) throw new Error('用法: node --experimental-strip-types tools/anim_preview.ts <spriteHash> [outDir]');
  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error('缺 OPENROUTER_API_KEY');

  await mkdir(outDir, { recursive: true });

  // 1. 从线上把源立绘拉下来
  const res = await fetch(`${API_BASE}/assets/${spriteHash}`);
  if (!res.ok) throw new Error(`拉立绘失败 ${res.status}`);
  const sprite: ImageBlob = { bytes: new Uint8Array(await res.arrayBuffer()), mime: 'image/png' };
  await writeFile(join(outDir, 'source_sprite.png'), Buffer.from(sprite.bytes));
  console.log(`源立绘 ${spriteHash}：${sprite.bytes.length} 字节`);

  // 2. 真生成（每段一次计费）。只列了部分段名就只重跑那几段，其余复用磁盘上的 mp4。
  const only = process.argv.slice(4).filter((a): a is ClipName => (CLIP_NAMES as readonly string[]).includes(a));
  const regen = only.length > 0 ? only : CLIP_NAMES;
  const video = new OpenRouterVideoAdapter(apiKey, {
    model: process.env.OPENROUTER_VIDEO_MODEL ?? 'bytedance/seedance-1-5-pro',
  });
  console.log(`生成中（${regen.join('/')}，并发，约 1~2 分钟）…`);
  const t0 = Date.now();
  const clips: { name: ClipName; mp4: VideoBlob }[] = await Promise.all(
    CLIP_NAMES.map(async (name) => {
      const path = join(outDir, `${name}.mp4`);
      if (!regen.includes(name)) {
        const mp4: VideoBlob = { bytes: new Uint8Array(await readFile(path)), mime: 'video/mp4' };
        console.log(`  ${name}.mp4  复用磁盘上的（未重生成）`);
        return { name, mp4 };
      }
      const mp4 = await video.generateClip(sprite, name);
      await writeFile(path, Buffer.from(mp4.bytes));
      console.log(`  ${name}.mp4  ${(mp4.bytes.length / 1024).toFixed(0)} KB  ← 新生成`);
      return { name, mp4 };
    }),
  );
  console.log(`生成完毕，用时 ${((Date.now() - t0) / 1000).toFixed(0)}s`);

  // 3. 走真实打包管线（抽帧→抠绿→合流统一裁剪→拼图集）
  const { atlas, meta } = await videosToSpriteSheet(clips, { webp: false }); // PNG 便于直接看
  await writeFile(join(outDir, 'atlas.png'), Buffer.from(atlas.bytes));
  console.log(`\n图集 ${meta.cols}×${meta.rows} 格，cell ${meta.cellW}×${meta.cellH}，共 ${meta.frameCount} 帧`);
  console.log(`  段区间: ${JSON.stringify(meta.clips)}`);
  console.log(`  cellW%4=${meta.cellW % 4} cellH%4=${meta.cellH % 4}（都应为 0，否则块压缩会串色）`);

  // 4. 每段拼一条横向长图（一眼看出角色有没有走出画/口型动没动）
  for (const name of CLIP_NAMES) {
    const r = meta.clips?.[name];
    if (!r) continue;
    await stripOf(atlas, meta.cols, meta.cellW, meta.cellH, r.start, r.count, join(outDir, `strip_${name}.png`));
    console.log(`  strip_${name}.png  ${r.count} 帧`);
  }

  // 5. 每段再转一个可播放的 gif（看动起来的样子）
  for (const name of CLIP_NAMES) {
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error', '-i', join(outDir, `${name}.mp4`),
      '-vf', 'fps=12,scale=-2:240', join(outDir, `${name}.gif`),
    ]);
  }
  console.log(`\n产物全在 ${outDir}`);
}

/** 把图集里 [start, start+count) 的帧横向铺成一条长图。 */
async function stripOf(
  atlas: ImageBlob, cols: number, cellW: number, cellH: number,
  start: number, count: number, outPath: string,
): Promise<void> {
  const src = PNG.sync.read(Buffer.from(atlas.bytes));
  const out = new PNG({ width: cellW * count, height: cellH });
  for (let i = 0; i < count; i++) {
    const f = start + i;
    PNG.bitblt(src, out, (f % cols) * cellW, Math.floor(f / cols) * cellH, cellW, cellH, i * cellW, 0);
  }
  await writeFile(outPath, PNG.sync.write(out));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
