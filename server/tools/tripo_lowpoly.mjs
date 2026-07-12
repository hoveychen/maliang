#!/usr/bin/env node
// tripo_lowpoly.mjs —— 一句命令出一个低多边形 3D 物品（可选绑骨+动画）。
//
// 链路：生图(low-poly 概念图) → 上传 Tripo → image-to-3D(低模) → [绑骨 → 套动画] → 下载 glb。
// 概念图先用 OpenRouter 出一张干净的 flat low-poly 图把风格锁死，再喂 Tripo image-to-3D——
// 实测比 text-to-3D 直出风格统一得多（宝箱/蘑菇不再糊，见 PoC）。
//
// 港区坑：港区 IP 直连 Google/OpenAI 图像模型一律 403（memory: image-model-eval-and-ip-policy）。
// 默认把生图转发到出口机（首尔 own-api-ko）跑，复用同目录的 fetch_openrouter_images.py。
// 设 --exit-host "" 可强制本地生图（仅在非受限区可用）。
//
// 用法：
//   TRIPO_API_KEY=tsk_... OPENROUTER_API_KEY=sk-... \
//     node server/tools/tripo_lowpoly.mjs "a cartoon tree" --out ./out --name tree
//
// 选项：
//   --out <dir>          输出目录（默认 ./tripo-out）
//   --name <slug>        输出文件名前缀（默认从描述推）
//   --face-limit <n>     低模目标面数（默认 2500）
//   --image <path>       跳过生图，直接用现成概念图
//   --exit-host <host>   港区代理生图的 ssh 出口机（默认 $IMAGE_EXIT_HOST 或 own-api-ko；"" 走本地）
//   --image-model <id>   生图模型（默认 google/gemini-3.1-flash-lite-image）
//   --rig                绑骨（角色/生物才需要）
//   --animate <preset>   套动画预设（walk/run/idle/jump/...），隐含 --rig
//   --keep-concept       保留概念图到输出目录
//
// 环境变量：TRIPO_API_KEY（必填）、OPENROUTER_API_KEY（生图必填，--image 时可省）。

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const TRIPO_BASE = 'https://api.tripo3d.ai/v2/openapi';
const OR_ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';
const LOWPOLY_SUFFIX =
  'stylized LOW-POLY 3D game asset, clearly faceted flat-shaded polygons, low polygon count, ' +
  'crisp visible geometric facets, solid flat pastel colors with NO photographic texture and no fine detail, ' +
  'soft even studio lighting, three-quarter view, single object centered, ' +
  'isolated on a pure solid white background, no shadow, no ground, no text, no watermark';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const a = { faceLimit: 2500, out: './tripo-out', exitHost: process.env.IMAGE_EXIT_HOST ?? 'own-api-ko',
    imageModel: 'google/gemini-3.1-flash-lite-image', rig: false, animate: null, keepConcept: false, image: null, name: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--out') a.out = argv[++i];
    else if (t === '--name') a.name = argv[++i];
    else if (t === '--face-limit') a.faceLimit = parseInt(argv[++i], 10);
    else if (t === '--image') a.image = argv[++i];
    else if (t === '--exit-host') a.exitHost = argv[++i];
    else if (t === '--image-model') a.imageModel = argv[++i];
    else if (t === '--rig') a.rig = true;
    else if (t === '--animate') { a.animate = argv[++i]; a.rig = true; }
    else if (t === '--keep-concept') a.keepConcept = true;
    else rest.push(t);
  }
  a.subject = rest.join(' ').trim();
  if (!a.name) a.name = (a.subject || basename(a.image || 'model')).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 32) || 'model';
  return a;
}

// ---- 生图：港区走出口机，否则本地 ----
function slog(m) { process.stderr.write(m + '\n'); }

async function genConceptLocal(subject, model, orKey, outPath) {
  const prompt = `A single ${subject}. ${LOWPOLY_SUFFIX}`;
  const res = await fetch(OR_ENDPOINT, {
    method: 'POST',
    headers: { Authorization: `Bearer ${orKey}`, 'Content-Type': 'application/json', 'HTTP-Referer': 'https://maliang.game', 'X-Title': 'maliang-tripo-lowpoly' },
    body: JSON.stringify({ model, messages: [{ role: 'user', content: prompt }], modalities: ['image', 'text'] }),
    signal: AbortSignal.timeout(180000),
  });
  const j = await res.json();
  if (!res.ok || j.error) throw new Error(`OpenRouter ${res.status}: ${JSON.stringify(j.error)} (港区可能需 --exit-host)`);
  const imgs = j.choices?.[0]?.message?.images;
  const url = imgs?.[0]?.image_url?.url ?? imgs?.[0]?.url;
  if (!url?.startsWith('data:')) throw new Error('生图无返回: ' + JSON.stringify(j).slice(0, 200));
  writeFileSync(outPath, Buffer.from(url.slice(url.indexOf(',') + 1), 'base64'));
}

function genConceptViaExitHost(subject, model, orKey, host, outPath) {
  const prompt = `A single ${subject}. ${LOWPOLY_SUFFIX}`;
  const remote = `/tmp/tripo_lp_${process.pid}`;
  const localJobs = join(tmpdir(), `tripo_lp_jobs_${process.pid}.json`);
  writeFileSync(localJobs, JSON.stringify({ model, jobs: [{ file: 'concept', prompt }] }));
  const fetchScript = join(HERE, 'fetch_openrouter_images.py');
  try {
    execFileSync('ssh', [host, `mkdir -p ${remote}/out`], { stdio: 'pipe' });
    execFileSync('scp', ['-q', fetchScript, localJobs, `${host}:${remote}/`], { stdio: 'pipe' });
    // key 经环境变量传入远程 shell，不落文件
    execFileSync('ssh', [host, `OPENROUTER_API_KEY='${orKey}' python3 ${remote}/${basename(fetchScript)} ${remote}/${basename(localJobs)} ${remote}/out 1`], { stdio: 'pipe' });
    // 拉回 concept.*（扩展名由 mime 决定）
    const localTmp = join(tmpdir(), `tripo_lp_out_${process.pid}`);
    mkdirSync(localTmp, { recursive: true });
    execFileSync('scp', ['-q', '-r', `${host}:${remote}/out/.`, localTmp], { stdio: 'pipe' });
    const files = execFileSync('ls', [localTmp]).toString().trim().split('\n').filter(Boolean);
    const concept = files.find((f) => f.startsWith('concept.'));
    if (!concept) throw new Error('出口机未产出概念图（检查 OPENROUTER_API_KEY / 模型可用性）');
    const buf = readFileSync(join(localTmp, concept));
    writeFileSync(outPath, buf);
  } finally {
    try { execFileSync('ssh', [host, `rm -rf ${remote} ${remote}/${basename(localJobs)}`], { stdio: 'pipe' }); } catch { /* best effort */ }
  }
}

// ---- Tripo ----
async function tripo(path, opts, key) {
  const r = await fetch(`${TRIPO_BASE}${path}`, { ...opts, headers: { Authorization: `Bearer ${key}`, ...(opts.headers || {}) } });
  return r.json();
}
async function uploadImage(file, key) {
  const buf = readFileSync(file);
  const ext = file.endsWith('.png') ? 'png' : 'jpeg';
  const fd = new FormData();
  fd.append('file', new Blob([buf], { type: `image/${ext}` }), basename(file));
  const j = await tripo('/upload', { method: 'POST', body: fd }, key);
  if (j.code !== 0) throw new Error('上传失败 ' + JSON.stringify(j));
  return { token: j.data.image_token, ext };
}
async function createTask(body, key) {
  const j = await tripo('/task', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }, key);
  if (j.code !== 0) throw new Error('建任务失败 ' + JSON.stringify(j));
  return j.data.task_id;
}
async function pollTask(id, key, label) {
  let consumed = 0;
  for (let i = 0; i < 180; i++) {
    let d;
    try { d = (await tripo(`/task/${id}`, { method: 'GET' }, key)).data; } catch { /* transient */ }
    if (d) {
      consumed = d.consumed_credit ?? consumed;
      process.stderr.write(`\r  ${label} ${d.status} ${d.progress ?? 0}%   `);
      if (['success', 'failed', 'cancelled', 'banned'].includes(d.status)) {
        slog('');
        if (d.status !== 'success') throw new Error(`${label} 任务 ${d.status}`);
        const res = d.result || {};
        const glb = (res.pbr_model || res.model || {}).url;
        const render = (res.rendered_image || {}).url;
        return { glb, render, consumed: d.consumed_credit ?? 0 };
      }
    }
    await sleep(5000);
  }
  throw new Error(`${label} 轮询超时`);
}
async function download(url, out) {
  const r = await fetch(url);
  writeFileSync(out, Buffer.from(await r.arrayBuffer()));
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const tripoKey = process.env.TRIPO_API_KEY;
  if (!tripoKey) throw new Error('缺 TRIPO_API_KEY 环境变量');
  if (!a.subject && !a.image) throw new Error('需要一个物品描述，或用 --image 指定现成概念图');
  mkdirSync(a.out, { recursive: true });

  // 1. 概念图
  let conceptPath = a.image;
  if (!conceptPath) {
    const orKey = process.env.OPENROUTER_API_KEY;
    if (!orKey) throw new Error('缺 OPENROUTER_API_KEY（或用 --image 跳过生图）');
    conceptPath = join(a.out, `${a.name}.concept.jpg`);
    if (a.exitHost) {
      slog(`[1/${a.rig ? (a.animate ? 4 : 3) : 2}] 生概念图 (出口机 ${a.exitHost})…`);
      genConceptViaExitHost(a.subject, a.imageModel, orKey, a.exitHost, conceptPath);
    } else {
      slog(`[1/…] 生概念图 (本地)…`);
      await genConceptLocal(a.subject, a.imageModel, orKey, conceptPath);
    }
  }

  // 2. image-to-3D
  slog(`[2] 上传 + image-to-3D (face_limit=${a.faceLimit})…`);
  const { token, ext } = await uploadImage(conceptPath, tripoKey);
  const imgTask = await createTask({ type: 'image_to_model', file: { type: ext, file_token: token }, face_limit: a.faceLimit }, tripoKey);
  let last = await pollTask(imgTask, tripoKey, 'image-to-3D');
  let totalCr = last.consumed;
  let finalTask = imgTask;

  // 3. 绑骨
  if (a.rig) {
    slog('[3] 绑骨…');
    const rigTask = await createTask({ type: 'animate_rig', original_model_task_id: imgTask, out_format: 'glb' }, tripoKey);
    const r = await pollTask(rigTask, tripoKey, 'rig');
    totalCr += r.consumed; last = r; finalTask = rigTask;
  }
  // 4. 动画
  if (a.animate) {
    slog(`[4] 套动画 ${a.animate}…`);
    const animTask = await createTask({ type: 'animate_retarget', original_model_task_id: finalTask, animation: `preset:${a.animate}`, out_format: 'glb' }, tripoKey);
    const r = await pollTask(animTask, tripoKey, 'animate');
    totalCr += r.consumed; last = r;
  }

  // 下载产物
  const glbOut = join(a.out, `${a.name}.glb`);
  await download(last.glb, glbOut);
  if (last.render) await download(last.render, join(a.out, `${a.name}.render.webp`));
  if (a.image && a.keepConcept) { /* 用户自带图，不复制 */ }

  slog('');
  slog(`✅ 完成：${glbOut}`);
  slog(`   消耗 ${totalCr} credits ≈ $${(totalCr / 100).toFixed(2)}`);
  console.log(glbOut);
}

main().catch((e) => { slog('\n❌ ' + e.message); process.exit(1); });
