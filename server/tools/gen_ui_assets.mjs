// UI/HUD 素材批量生成：manifest 驱动真调 OpenRouter 生图，出候选 PNG 供人眼挑选。
// 两种模式：
//   sticker      — 绿幕生成 → 抠图 → alpha 包围盒裁边(带留白) → 降采样到 targetSize（HUD/按钮图标）
//   illustration — 全幅画面 → 居中裁到 targetW×targetH 宽高比 → 降采样（绘本插画/背景/书页纹理）
// 用法：node --env-file=.env tools/gen_ui_assets.mjs <manifest.json> <outDir> [--only id1,id2] [--candidates N] [--concurrency N]
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { PNG } from 'pngjs';
import jpeg from 'jpeg-js';
import { OpenRouterClient } from '../src/adapters/openrouter_client.ts';
import { ChromaKeyCutoutAdapter } from '../src/adapters/chroma_cutout.ts';
import { loadConfig } from '../src/config.ts';

// 图标贴纸统一画风：与角色立绘 SPRITE_STYLE_SUFFIX 同宗（粗黑描边+白色贴纸边+扁平 cel+粉彩），
// 但主体是物件/表情图标而非全身角色，构图居中特写。
const ICON_STYLE_SUFFIX =
  'kawaii die-cut sticker icon, bold black outline around the subject and a thick white ' +
  'die-cut sticker border outside the outline, flat cel shading, bright pastel colors, ' +
  'toy-like, single subject centered and large in frame, ' +
  'on a pure solid chroma-green #00FF00 background, no shadows, no text, no watermark';

// 绘本插画统一画风：手绘水彩童话书，柔和梦幻，无文字。
const ILLUSTRATION_STYLE_SUFFIX =
  "children's picture book watercolor illustration, soft hand-painted gouache texture, " +
  'warm bright pastel colors, gentle dreamy storybook atmosphere for toddlers, ' +
  'no text, no letters, no watermark, no border';

const args = process.argv.slice(2);
const manifestPath = args[0];
const outDir = args[1];
if (!manifestPath || !outDir) {
  console.error('usage: node --env-file=.env tools/gen_ui_assets.mjs <manifest.json> <outDir> [--only id1,id2] [--candidates N] [--concurrency N]');
  process.exit(1);
}
const flag = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};
const only = flag('--only', '').split(',').filter(Boolean);
const defaultCandidates = Number(flag('--candidates', '2'));
const concurrency = Number(flag('--concurrency', '4'));

const cfg = loadConfig();
if (!cfg.openrouterApiKey) {
  console.error('缺 OPENROUTER_API_KEY（.env）');
  process.exit(1);
}
const client = new OpenRouterClient(cfg.openrouterApiKey, 120000);
const cutout = new ChromaKeyCutoutAdapter();

// ---------- 位图工具（RGBA Raster，复用 pngjs/jpeg-js） ----------

function decode(bytes) {
  const buf = Buffer.from(bytes);
  if (buf[0] === 0x89 && buf[1] === 0x50) {
    // 生图结果 IEND 后可能带尾巴，裁掉（与 chroma_cutout 同因）
    const IEND = Buffer.from([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);
    const idx = buf.indexOf(IEND);
    const png = PNG.sync.read(idx >= 0 ? buf.subarray(0, idx + IEND.length) : buf);
    return { width: png.width, height: png.height, data: png.data };
  }
  if (buf[0] === 0xff && buf[1] === 0xd8) {
    const j = jpeg.decode(buf, { useTArray: true, formatAsRGBA: true });
    return { width: j.width, height: j.height, data: j.data };
  }
  throw new Error('unsupported image format');
}

function encodePng(r) {
  const png = new PNG({ width: r.width, height: r.height });
  png.data = Buffer.from(r.data.buffer, r.data.byteOffset, r.data.byteLength);
  return new Uint8Array(PNG.sync.write(png));
}

function crop(r, x0, y0, w, h) {
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const src = ((y0 + y) * r.width + x0) * 4;
    out.set(r.data.subarray(src, src + w * 4), y * w * 4);
  }
  return { width: w, height: h, data: out };
}

// alpha>8 的包围盒 + 比例留白，抠图后把主体裁出来
function trimAlpha(r, padRatio = 0.04) {
  let minX = r.width, minY = r.height, maxX = -1, maxY = -1;
  for (let y = 0; y < r.height; y++) {
    for (let x = 0; x < r.width; x++) {
      if (r.data[(y * r.width + x) * 4 + 3] > 8) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return r; // 全透明，别裁
  const pad = Math.round(Math.max(maxX - minX, maxY - minY) * padRatio);
  const x0 = Math.max(0, minX - pad);
  const y0 = Math.max(0, minY - pad);
  const x1 = Math.min(r.width - 1, maxX + pad);
  const y1 = Math.min(r.height - 1, maxY + pad);
  return crop(r, x0, y0, x1 - x0 + 1, y1 - y0 + 1);
}

// 盒式降采样（只缩不放大；alpha 加权避免透明像素污染颜色）
function resizeDown(r, tw, th) {
  if (tw >= r.width && th >= r.height) return r;
  const out = new Uint8Array(tw * th * 4);
  for (let y = 0; y < th; y++) {
    const sy0 = Math.floor((y * r.height) / th);
    const sy1 = Math.max(sy0 + 1, Math.floor(((y + 1) * r.height) / th));
    for (let x = 0; x < tw; x++) {
      const sx0 = Math.floor((x * r.width) / tw);
      const sx1 = Math.max(sx0 + 1, Math.floor(((x + 1) * r.width) / tw));
      let rs = 0, gs = 0, bs = 0, as = 0, n = 0;
      for (let sy = sy0; sy < sy1; sy++) {
        for (let sx = sx0; sx < sx1; sx++) {
          const i = (sy * r.width + sx) * 4;
          const a = r.data[i + 3];
          rs += r.data[i] * a;
          gs += r.data[i + 1] * a;
          bs += r.data[i + 2] * a;
          as += a;
          n++;
        }
      }
      const o = (y * tw + x) * 4;
      out[o + 3] = Math.round(as / n);
      out[o] = as > 0 ? Math.round(rs / as) : 0;
      out[o + 1] = as > 0 ? Math.round(gs / as) : 0;
      out[o + 2] = as > 0 ? Math.round(bs / as) : 0;
    }
  }
  return { width: tw, height: th, data: out };
}

function centerCropToAspect(r, tw, th) {
  const targetRatio = tw / th;
  const srcRatio = r.width / r.height;
  if (Math.abs(srcRatio - targetRatio) < 1e-3) return r;
  if (srcRatio > targetRatio) {
    const w = Math.round(r.height * targetRatio);
    return crop(r, Math.floor((r.width - w) / 2), 0, w, r.height);
  }
  const h = Math.round(r.width / targetRatio);
  return crop(r, 0, Math.floor((r.height - h) / 2), r.width, h);
}

// ---------- 生成 ----------

async function generateOne(asset, idx) {
  const isSticker = asset.kind === 'sticker';
  const prompt = isSticker
    ? `${asset.prompt.trim().replace(/[.。，,]+$/, '')}. ${ICON_STYLE_SUFFIX}`
    : `${asset.prompt.trim().replace(/[.。，,]+$/, '')}. ${ILLUSTRATION_STYLE_SUFFIX}${asset.landscape === false ? '' : ', wide landscape composition'}`;
  const raw = await client.chatImage(cfg.imageModel, prompt);
  let raster;
  if (isSticker) {
    const cut = await cutout.removeBackground(raw);
    raster = trimAlpha(decode(cut.bytes));
    const size = asset.targetSize ?? 256;
    const scale = Math.min(1, size / Math.max(raster.width, raster.height));
    raster = resizeDown(raster, Math.max(1, Math.round(raster.width * scale)), Math.max(1, Math.round(raster.height * scale)));
  } else {
    const tw = asset.targetW ?? 1280;
    const th = asset.targetH ?? 800;
    raster = centerCropToAspect(decode(raw.bytes), tw, th);
    raster = resizeDown(raster, Math.min(tw, raster.width), Math.min(th, raster.height));
  }
  const file = join(outDir, `${asset.id}_c${idx}.png`);
  await writeFile(file, encodePng(raster));
  return file;
}

const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const assets = manifest.assets.filter((a) => only.length === 0 || only.includes(a.id));
await mkdir(outDir, { recursive: true });

const jobs = [];
for (const asset of assets) {
  const count = asset.candidates ?? defaultCandidates;
  for (let i = 1; i <= count; i++) jobs.push({ asset, idx: i });
}
console.log(`assets=${assets.length} jobs=${jobs.length} model=${cfg.imageModel} concurrency=${concurrency}`);

let done = 0, failed = 0;
let cursor = 0;
async function worker() {
  while (cursor < jobs.length) {
    const job = jobs[cursor++];
    const t0 = Date.now();
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const file = await generateOne(job.asset, job.idx);
        console.log(`ok  ${job.asset.id}_c${job.idx} (${((Date.now() - t0) / 1000).toFixed(1)}s) -> ${file}`);
        break;
      } catch (e) {
        if (attempt === 2) {
          failed++;
          console.error(`FAIL ${job.asset.id}_c${job.idx}: ${e.message}`);
        } else {
          console.error(`retry ${job.asset.id}_c${job.idx}: ${e.message}`);
        }
      }
    }
    done++;
    if (done % 5 === 0) console.log(`progress ${done}/${jobs.length}`);
  }
}
await Promise.all(Array.from({ length: Math.min(concurrency, jobs.length) }, worker));
console.log(`done: ${done - failed}/${jobs.length} ok, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
