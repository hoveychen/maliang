import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { packKeyFromRenderRef } from '../src/items.ts';

/**
 * 内容包分发（content-pck-distribution P2）：服务端 .pck 入库 + manifest 端点。
 * 见 docs/content-pack-distribution-design.md。核心验收：village 场景 manifest 只需 base 包，
 * village_forest 需 base + toyroom（因摆了 furniture:table / furniture:bedSingle）——用【真实】
 * 打包 .mltr 矩阵 + 真实 pack.json 键跑通「场景摆放物品 → 反查所属内容包」的端到端映射。
 */

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TERRAIN = join(REPO, 'assets', 'terrain');
const PACKS = join(REPO, 'assets', 'packs');

/** 从某 pack.json 读出它声明的渲染键（= entries 键），供入库时随 .pck 一起登记。 */
function packKeys(name: string): string[] {
  const doc = JSON.parse(readFileSync(join(PACKS, name, 'pack.json'), 'utf8')) as {
    entries: Record<string, unknown>;
  };
  return Object.keys(doc.entries);
}

function mltrB64(scene: string): string {
  return readFileSync(join(TERRAIN, `${scene}.mltr`)).toString('base64');
}

async function app(store: WorldStore) {
  return buildServer({ adapters: createMockAdapters(), store });
}

// ── packKeyFromRenderRef 纯函数 ────────────────────────────────────────────────

test('packKeyFromRenderRef：冒号后段即包键；无包的 renderRef → null', () => {
  assert.equal(packKeyFromRenderRef('kaykit:well'), 'well');
  assert.equal(packKeyFromRenderRef('city:building-a'), 'building-a');
  assert.equal(packKeyFromRenderRef('furniture:table'), 'table'); // 前缀 furniture ≠ 包名 toyroom
  assert.equal(packKeyFromRenderRef('baked:tree_puff_a'), 'tree_puff_a');
  // 无包的形态：SDF props / 造物 / 内容寻址造物贴纸
  assert.equal(packKeyFromRenderRef('sdf_res:walking_hut'), 'walking_hut'); // 有键但 base 不含 → 上层 packForKey 落空
  assert.equal(packKeyFromRenderRef('sdf_inline'), null);
  assert.equal(packKeyFromRenderRef('composed:'), null);
  assert.equal(packKeyFromRenderRef('sticker:@abcdef123456'), null);
});

// ── store 级注册表 ────────────────────────────────────────────────────────────

test('registerPack：入库 .pck + 记录 hash/bytes/keys；packForKey 反查；持久化跨重启', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-packs-'));
  try {
    const store = new WorldStore(dir);
    const pck = new Uint8Array([1, 2, 3, 4, 5]);
    const rec = store.registerPack('base', { bytes: pck, mime: 'application/octet-stream' }, packKeys('base'));
    assert.equal(rec.bytes, 5);
    assert.ok(rec.hash.length > 0);
    // .pck 本体进了内容寻址资产库
    assert.deepEqual(store.getAsset(rec.hash)?.bytes, pck);
    // 反查：base 声明的键落到 base；未登记键落空
    assert.equal(store.packForKey('well'), 'base');
    assert.equal(store.packForKey('tree_puff_a'), 'base');
    assert.equal(store.packForKey('walking_hut'), undefined);

    // 跨重启：新 store 指同一 dir，packs.json + assets 都读回
    const store2 = new WorldStore(dir);
    assert.deepEqual(store2.getPack('base'), rec);
    assert.equal(store2.packForKey('windmill'), 'base');
    assert.deepEqual(store2.getAsset(rec.hash)?.bytes, pck);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('#loadPacks 孤儿过滤：packs.json 有登记但对应 .pck 资产缺失 → 不载入', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-packs-orphan-'));
  try {
    const store = new WorldStore(dir);
    const rec = store.registerPack('base', { bytes: new Uint8Array([9]), mime: 'application/octet-stream' }, ['well']);
    // 手动删掉资产字节文件，模拟孤儿登记
    rmSync(join(dir, 'assets', rec.hash), { force: true });
    const store2 = new WorldStore(dir);
    assert.equal(store2.getPack('base'), undefined, '孤儿登记不载入');
    assert.equal(store2.packForKey('well'), undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── manifest 端点（真实打包矩阵）─────────────────────────────────────────────────

test('GET manifest：village 只需 base 包（其余为 sdf_res:，不属任何内容包）', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.registerPack('base', { bytes: new Uint8Array([1]), mime: 'application/octet-stream' }, packKeys('base'));
  store.registerPack('toyroom', { bytes: new Uint8Array([2, 2]), mime: 'application/octet-stream' }, packKeys('toyroom'));
  const a = await app(store);
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const seed = await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', sceneId: 'village', name: '村庄', terrainBase64: mltrB64('village') },
    });
    assert.equal(seed.statusCode, 200);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
  const res = await a.inject({ method: 'GET', url: '/worlds/w1/scenes/village/manifest' });
  assert.equal(res.statusCode, 200);
  const body = res.json() as { packs: { name: string; hash: string; bytes: number }[] };
  assert.deepEqual(body.packs.map((p) => p.name), ['base'], 'village 只需 base（toyroom 虽登记但未被引用，不下发）');
  assert.equal(body.packs[0]!.bytes, 1);
  assert.ok(body.packs[0]!.hash.length > 0);
});

test('GET manifest：village_forest 需 base + toyroom（摆了 furniture:table / bedSingle）', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.registerPack('base', { bytes: new Uint8Array([1]), mime: 'application/octet-stream' }, packKeys('base'));
  store.registerPack('toyroom', { bytes: new Uint8Array([2, 2]), mime: 'application/octet-stream' }, packKeys('toyroom'));
  const a = await app(store);
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', sceneId: 'village_forest', name: '森林村', terrainBase64: mltrB64('village_forest') },
    });
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
  const res = await a.inject({ method: 'GET', url: '/worlds/w1/scenes/village_forest/manifest' });
  assert.equal(res.statusCode, 200);
  const body = res.json() as { packs: { name: string }[] };
  assert.deepEqual(body.packs.map((p) => p.name), ['base', 'toyroom'], '排序稳定 base<toyroom');
});

test('GET manifest：未登记包的场景 → 空清单（过渡期优雅缺失，客户端不崩）', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  // 不注册任何包
  const a = await app(store);
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', sceneId: 'village', name: '村庄', terrainBase64: mltrB64('village') },
    });
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
  const res = await a.inject({ method: 'GET', url: '/worlds/w1/scenes/village/manifest' });
  assert.equal(res.statusCode, 200);
  assert.deepEqual((res.json() as { packs: unknown[] }).packs, []);
});

test('GET manifest：未知场景 → 404', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  const a = await app(store);
  t.after(() => a.close());
  const res = await a.inject({ method: 'GET', url: '/worlds/w1/scenes/nope/manifest' });
  assert.equal(res.statusCode, 404);
});

// ── admin 入库端点 ─────────────────────────────────────────────────────────────

test('POST /admin/packs/:name：token 门禁', async (t) => {
  const store = new WorldStore();
  const a = await app(store);
  t.after(() => a.close());
  delete process.env.MALIANG_ADMIN_TOKEN;
  assert.equal((await a.inject({ method: 'POST', url: '/admin/packs/base', payload: {} })).statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const bad = await a.inject({ method: 'POST', url: '/admin/packs/base', headers: { 'x-admin-token': 'nope' }, payload: {} });
    assert.equal(bad.statusCode, 403);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('POST /admin/packs/:name：入库后 .pck 可从 /assets/:hash 取回，manifest 认它', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  const a = await app(store);
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const pckBytes = Buffer.from([7, 7, 7, 7]);
    const ing = await a.inject({
      method: 'POST', url: '/admin/packs/base', headers: { 'x-admin-token': 'sesame' },
      payload: { pckBase64: pckBytes.toString('base64'), keys: packKeys('base') },
    });
    assert.equal(ing.statusCode, 200);
    const rec = ing.json() as { name: string; hash: string; bytes: number; keys: string[] };
    assert.equal(rec.name, 'base');
    assert.equal(rec.bytes, 4);
    assert.ok(rec.keys.includes('well'));

    // .pck 本体走通用资产端点取回，字节一致
    const asset = await a.inject({ method: 'GET', url: `/assets/${rec.hash}` });
    assert.equal(asset.statusCode, 200);
    assert.deepEqual(new Uint8Array(asset.rawPayload), new Uint8Array(pckBytes));

    // 入库后 manifest 认它
    await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId: 'w1', sceneId: 'village', name: '村庄', terrainBase64: mltrB64('village') },
    });
    const man = await a.inject({ method: 'GET', url: '/worlds/w1/scenes/village/manifest' });
    const body = man.json() as { packs: { name: string; hash: string }[] };
    assert.deepEqual(body.packs.map((p) => p.name), ['base']);
    assert.equal(body.packs[0]!.hash, rec.hash);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('POST /admin/packs/:name：空 keys 允许（非场景内容包）/ 空 body 拒绝', async (t) => {
  const store = new WorldStore();
  const a = await app(store);
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // P5：voice/bgm 等非场景包无渲染键——空 keys 现被接受（靠 GET /packs 按名解析，不进 sceneManifest）。
    const noKeys = await a.inject({
      method: 'POST', url: '/admin/packs/bgm', headers: { 'x-admin-token': 'sesame' },
      payload: { pckBase64: Buffer.from([1]).toString('base64'), keys: [] },
    });
    assert.equal(noKeys.statusCode, 200);
    assert.deepEqual((noKeys.json() as { keys: string[] }).keys, []);
    // 空 body（无 pckBase64）仍拒绝。
    const noBody = await a.inject({
      method: 'POST', url: '/admin/packs/base', headers: { 'x-admin-token': 'sesame' },
      payload: { keys: ['well'] },
    });
    assert.equal(noBody.statusCode, 400);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

test('GET /packs：列出全部已登记包（含无键的非场景内容包）供客户端按名解析', async (t) => {
  const store = new WorldStore();
  const a = await app(store);
  t.after(() => a.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // 一个有键的主题包 + 一个无键的 voice 包
    const city = await a.inject({
      method: 'POST', url: '/admin/packs/city', headers: { 'x-admin-token': 'sesame' },
      payload: { pckBase64: Buffer.from([1, 2, 3]).toString('base64'), keys: ['building-a'] },
    });
    const vi = await a.inject({
      method: 'POST', url: '/admin/packs/voice_items', headers: { 'x-admin-token': 'sesame' },
      payload: { pckBase64: Buffer.from([4, 5]).toString('base64'), keys: [] },
    });
    assert.equal(city.statusCode, 200);
    assert.equal(vi.statusCode, 200);
    const res = await a.inject({ method: 'GET', url: '/packs' });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { packs: { name: string; hash: string; bytes: number }[] };
    const byName = new Map(body.packs.map((p) => [p.name, p]));
    assert.ok(byName.has('city'));
    assert.ok(byName.has('voice_items')); // 无键包也在 /packs 里，客户端按名取 hash
    assert.equal(byName.get('voice_items')!.bytes, 2);
    assert.equal(byName.get('city')!.hash, (city.json() as { hash: string }).hash);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
