// 小仙子形象候选生成：真调 OpenRouter 生图 + 绿幕抠图，出 N 张候选 PNG 供挑选。
// 用法：node --env-file=.env tools/gen_fairy_candidates.mjs <输出目录> [数量=4]
import { writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { OpenRouterClient } from '../src/adapters/openrouter_client.ts';
import { OpenRouterImageAdapter } from '../src/adapters/openrouter_image.ts';
import { ChromaKeyCutoutAdapter } from '../src/adapters/chroma_cutout.ts';
import { FAIRY_VISUAL_DESC } from '../src/adapters/sprite_style.ts';
import { loadConfig } from '../src/config.ts';

const outDir = process.argv[2];
const count = Number(process.argv[3] ?? 4);
if (!outDir) {
  console.error('usage: node --env-file=.env tools/gen_fairy_candidates.mjs <outDir> [count]');
  process.exit(1);
}

const cfg = loadConfig();
if (!cfg.openrouterApiKey) {
  console.error('缺 OPENROUTER_API_KEY（.env）');
  process.exit(1);
}
const image = new OpenRouterImageAdapter(new OpenRouterClient(cfg.openrouterApiKey, 120000), cfg.imageModel);
const cutout = new ChromaKeyCutoutAdapter();
await mkdir(outDir, { recursive: true });

console.log(`形象描述: ${FAIRY_VISUAL_DESC}`);
for (let i = 0; i < count; i++) {
  const t0 = Date.now();
  try {
    const raw = await image.generateSprite(FAIRY_VISUAL_DESC);
    const cut = await cutout.removeBackground(raw);
    const file = join(outDir, `fairy_${i + 1}.png`);
    await writeFile(file, cut.bytes);
    console.log(`candidate ${i + 1}: ${file} (${cut.bytes.byteLength} bytes, ${Date.now() - t0}ms)`);
  } catch (e) {
    console.error(`candidate ${i + 1} FAILED: ${e.message}`);
  }
}
