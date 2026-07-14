// 积木式造物 B1 零件真图（P3）生成管线第一步：从 part_library.ts 导出零件生图 manifest，
// 喂给 gen_ui_assets.mjs（sticker 模式，绿幕抠图）。统一画风前缀锁在 PART_STYLE，保证「拼起来是一套」。
//
// 全链路（港区 IP 对生图模型一律 403，见 memory image-model-eval-and-ip-policy，故走首尔出口机）：
//   1) node tools/gen_part_manifest.mjs parts.manifest.json
//   2) node --env-file=.env tools/gen_ui_assets.mjs parts.manifest.json out --emit-jobs jobs.json
//   3) 出口机(own-api-ko): OPENROUTER_API_KEY=... python3 tools/fetch_openrouter_images.py jobs.json raw 8
//   4) node --env-file=.env tools/gen_ui_assets.mjs parts.manifest.json out --raw-dir raw   # 绿幕抠图+裁切+降采
//   5) 每件挑一张 <id>_c1.png → assets/build_parts/<id>.png（pack: assets/packs/build_parts/pack.json）
//
// 用法: node tools/gen_part_manifest.mjs <out.manifest.json> [--candidates N]
import { writeFile } from 'node:fs/promises';
import { PART_LIBRARY, partIconPrompt } from '../src/part_library.ts';

const out = process.argv[2];
if (!out) {
  console.error('用法: node tools/gen_part_manifest.mjs <out.manifest.json> [--candidates N]');
  process.exit(1);
}
const ci = process.argv.indexOf('--candidates');
const candidates = ci >= 0 ? Number(process.argv[ci + 1]) : 3;

const assets = PART_LIBRARY.map((p) => ({
  id: p.id,
  // PART_STYLE 写的是 die-cut 透明底，但模型只出实底 → 补一句绿幕供 chroma 抠图（gen_ui_assets sticker 模式）。
  prompt: partIconPrompt(p.id) + ', on a solid chroma-key green screen background',
  kind: 'sticker',
  targetSize: 256,
  candidates,
}));
await writeFile(out, JSON.stringify({ assets }, null, 2));
console.log(`manifest: ${assets.length} parts (candidates=${candidates}) -> ${out}`);
