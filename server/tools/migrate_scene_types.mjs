// 场景地表安全迁移（pokopia-themes P4）：把新种子 .mltr 的「类型/台阶层差异」
// 以 tile-edits patch 应用到线上场景——不走 /admin/scenes 全量重导（那会整体替换
// 矩阵、清掉玩家摆放物,见 docs/pokopia-themes-p4-proposal.md 的读码取证）。
//
// 策略：逐 tile 比对线上矩阵与新种子的 types/heights,只对有差异的 tile 发
// {x,y,t,h};该 tile 上有物品引用(itemRef≠0,含边缘挂载)则跳过并计数——孩子摆的
// 东西比拼布 patch 优先。水位差异跟随类型(t 改水时服务端自动给浅水,d 显式带上)。
// 走 editSceneTerrain 唯一写入口:整图复检 + version+1 + terrain_patch 广播,
// 在线玩家即时看到,无需重进。
//
// 用法:
//   SERVER_URL=https://... ADMIN_TOKEN=xxx \
//     node tools/migrate_scene_types.mjs <worldId> <sceneId> <new_seed.mltr> [--dry-run]
// 依赖 Node ≥22(直接 import ../src/terrain.ts,与服务端同一编解码,无第二份格式实现)。

import { readFileSync } from 'node:fs';
import { decodeTerrain } from '../src/terrain.ts';

const BASE = process.env.SERVER_URL || 'http://127.0.0.1:8080';
const TOKEN = process.env.ADMIN_TOKEN || '';
const [worldId, sceneId, seedPath] = process.argv.slice(2);
const dryRun = process.argv.includes('--dry-run');
if (!worldId || !sceneId || !seedPath) {
  console.error('用法: node tools/migrate_scene_types.mjs <worldId> <sceneId> <seed.mltr> [--dry-run]');
  process.exit(1);
}

const res = await fetch(`${BASE}/worlds/${worldId}/scenes/${sceneId}/terrain`);
if (!res.ok) {
  console.error(`拉线上地形失败 ${res.status}: ${await res.text()}`);
  process.exit(1);
}
const cur = decodeTerrain(new Uint8Array(await res.arrayBuffer()));
const seed = decodeTerrain(new Uint8Array(readFileSync(seedPath)));
if (cur.gridW !== seed.gridW || cur.gridH !== seed.gridH) {
  console.error(`尺寸不一致: 线上 ${cur.gridW}×${cur.gridH} vs 种子 ${seed.gridW}×${seed.gridH}`);
  process.exit(1);
}

const edits = [];
let skippedItem = 0;
for (let y = 0; y < cur.gridH; y++) {
  for (let x = 0; x < cur.gridW; x++) {
    const i = y * cur.gridW + x;
    const tDiff = cur.types[i] !== seed.types[i];
    const hDiff = cur.heights[i] !== seed.heights[i];
    const dDiff = cur.depths[i] !== seed.depths[i];
    if (!tDiff && !hDiff && !dDiff) continue;
    const hasItem = cur.itemRef[i] !== 0 || cur.edges.some((e) => e[i] !== 0);
    if (hasItem) {
      skippedItem++;
      continue; // 孩子摆的东西优先于拼布 patch
    }
    const e = { x, y };
    if (tDiff) e.t = seed.types[i];
    if (hDiff) e.h = seed.heights[i];
    // d 只在水 tile 合法:种子有水深就显式带上(同一 edit 里 t 已是水);
    // 水→旱由服务端随 t 自动清水深,不需要显式 d=0
    if (seed.depths[i] > 0) e.d = seed.depths[i];
    if (e.t === undefined && e.h === undefined && e.d === undefined) continue; // 纯「深度归零」类差异随 t 联动,无净变更
    edits.push(e);
  }
}
console.log(`差异 tile: ${edits.length}(另 ${skippedItem} 格有玩家物品,已跳过)`);
if (edits.length === 0 || dryRun) {
  if (dryRun && edits.length > 0) {
    const byType = {};
    for (const e of edits) if (e.t !== undefined) byType[e.t] = (byType[e.t] ?? 0) + 1;
    console.log('dry-run,按目标类型分布:', byType);
  }
  process.exit(0);
}

// 分批提交(单请求过大防 body 上限;editSceneTerrain 每批 version+1,各自广播)
const BATCH = 500;
for (let off = 0; off < edits.length; off += BATCH) {
  const slice = edits.slice(off, off + BATCH);
  const r = await fetch(`${BASE}/admin/worlds/${worldId}/scenes/${sceneId}/tile-edits`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-admin-token': TOKEN },
    body: JSON.stringify({ edits: slice }),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error(`批次 ${off / BATCH} 失败 ${r.status}:`, body);
    process.exit(1);
  }
  console.log(`批次 ${off / BATCH}: applied=${body.applied} version=${body.version}`);
}
console.log('迁移完成 ✔');
