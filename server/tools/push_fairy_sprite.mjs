// 把验收过的小仙子立绘推到服务器（确定性替换，不重新生图）。
// 用法：node tools/push_fairy_sprite.mjs <server_base> [png_path=../assets/fairy.png] [world=default]
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const base = process.argv[2];
const pngPath = process.argv[3] ?? join(dirname(fileURLToPath(import.meta.url)), '../../assets/fairy.png');
const world = process.argv[4] ?? 'default';
if (!base) {
  console.error('usage: node tools/push_fairy_sprite.mjs <server_base> [png_path] [world]');
  process.exit(1);
}

const png = await readFile(pngPath);
const res = await fetch(`${base}/worlds/${world}/fairy-sprite`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ pngBase64: png.toString('base64') }),
});
const body = await res.json();
if (!res.ok) {
  console.error(`FAILED ${res.status}:`, body);
  process.exit(1);
}
console.log(`ok: world=${world} spriteAsset=${body.spriteAsset} regenerated=${body.regenerated}`);
