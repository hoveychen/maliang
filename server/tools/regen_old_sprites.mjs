// 重生成旧 prompt 时代（2026-07-05 "facing right" 上线前）朝向随机的存量立绘。
// 逐个调 POST /worlds/:id/characters/:cid/regen-sprite（走完整管线，含朝向兜底），
// 服务端需配 MALIANG_ADMIN_TOKEN，本工具从 ADMIN_TOKEN 环境变量读取同一值。
//
// 用法:
//   ADMIN_TOKEN=xxx SEED_BASE=https://maliang-api.muveeai.com node tools/regen_old_sprites.mjs
//   （不带参数用下方默认清单；也可传 world:characterId 对覆盖：node ... default:abc123 w2:def456）
//
// 默认清单 = 2026-07-08 逐张人眼核验为旧素材的 7 个角色（见排查记录）：
// default 世界 5 个常驻村民（6/18 seed_villagers 批量种的）+ 两个小朋友世界里 7/4 生成的角色。
const DEFAULT_TARGETS = [
  ['default', 'c2dbaf39-8a1d-41be-a723-82e5ac987d0b'], // 蓬蓬（正面）
  ['default', '33bf2600-2fe5-4e56-89d3-5deb7631ddf7'], // 睡睡猫（正面）
  ['default', '501eece1-2e63-41ac-8265-cf8e6c6c05e3'], // 背篓憨憨熊（正面）
  ['default', 'f5b82582-8add-4f6a-9634-7f02d31ef71f'], // 红围巾小狐（朝左，倒走元凶）
  ['default', '90b7e85d-6b09-4185-b55e-fcd0f8e0606f'], // 花环鹿鹿（碰巧朝右，统一重生成保风格一致）
  ['c511aedc-4d39-46af-bd29-5f84e71a608d', '815ffba6-1d8b-4ad9-88f4-b7fb0632ff3d'], // 歌歌（正面）
  ['b1832d2c-0282-4313-8b62-a49c8c39d5c1', '8c35f65b-c0be-4ebc-848e-fcd94defaa0d'], // 歌星喵小橘（正面）
];

const BASE = process.env.SEED_BASE || 'http://127.0.0.1:8080';
const TOKEN = process.env.ADMIN_TOKEN || '';
if (!TOKEN) {
  console.error('缺 ADMIN_TOKEN 环境变量（须与服务端 MALIANG_ADMIN_TOKEN 一致）');
  process.exit(1);
}

const targets = process.argv.slice(2).length
  ? process.argv.slice(2).map((s) => s.split(':'))
  : DEFAULT_TARGETS;

console.error(`重生成 ${targets.length} 个角色立绘 @ ${BASE}（顺序执行，每个约 1-2 分钟）`);
let ok = 0;
for (const [worldId, cid] of targets) {
  const t = Date.now();
  try {
    const res = await fetch(`${BASE}/worlds/${worldId}/characters/${cid}/regen-sprite`, {
      method: 'POST',
      headers: { 'x-admin-token': TOKEN },
      signal: AbortSignal.timeout(300000),
    });
    const body = await res.json();
    if (!res.ok) throw new Error(`${res.status} ${body.error ?? ''}`);
    ok++;
    console.error(`  ✓ ${body.name} ${body.prev} → ${body.spriteAsset} (${((Date.now() - t) / 1000).toFixed(1)}s)`);
  } catch (err) {
    console.error(`  ✗ ${worldId}:${cid} → ${err.message}`);
  }
}
console.error(`done: ${ok}/${targets.length}`);
process.exit(ok === targets.length ? 0 : 1);
