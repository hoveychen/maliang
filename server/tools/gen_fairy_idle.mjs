// 点点 loading 页 idle 图集重打：本地立绘 → Seedance idle 单段视频 → 抠绿抽帧 →
// 单 idle 图集 WebP，落 assets/fairy_idle.webp。复用生产管线 videosToSpriteSheet。
// Seedance(bytedance) 港区大概率不 403（403 只坑 Google/OpenAI 生图）——先当 gating 验证。
//
// 用法：cd server && node --env-file=.env tools/gen_fairy_idle.mjs [spritePath=../assets/fairy.png]
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { OpenRouterVideoAdapter } from '../src/adapters/openrouter_video.ts';
import { videosToSpriteSheet } from '../src/sprite_sheet.ts';
import { loadConfig } from '../src/config.ts';

const here = dirname(fileURLToPath(import.meta.url));
const spritePath = process.argv[2] ?? join(here, '../../assets/fairy.png');
const outPath = join(here, '../../assets/fairy_idle.webp');

const cfg = loadConfig();
if (!cfg.openrouterApiKey) {
  console.error('缺 OPENROUTER_API_KEY（.env）');
  process.exit(1);
}

const sprite = { bytes: new Uint8Array(await readFile(spritePath)), mime: 'image/png' };
const video = new OpenRouterVideoAdapter(cfg.openrouterApiKey, { model: cfg.videoModel });

console.log(`视频模型: ${cfg.videoModel}`);
console.log(`立绘: ${spritePath}`);
console.log('生成 idle 段（Seedance，~$0.05，480p/4s，轮询最多 10min）…');
const t0 = Date.now();
const mp4 = await video.generateClip(sprite, 'idle');
console.log(`  idle mp4 到手 (${mp4.bytes.byteLength} bytes, ${((Date.now() - t0) / 1000).toFixed(0)}s)`);

// 单 idle 段图集（loading 页只要 idle）。fps=8 与旧 loading 图集一致。
const { atlas, meta } = await videosToSpriteSheet([{ name: 'idle', mp4 }], { fps: 8 });
await writeFile(outPath, Buffer.from(atlas.bytes));
console.log(`\n✓ 写入 ${outPath} (${atlas.bytes.byteLength} bytes)`);
console.log(`图集 meta（更新 loading.gd 常量用）:`);
console.log(JSON.stringify(meta, null, 2));
