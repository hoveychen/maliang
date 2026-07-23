import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

/**
 * 全量预下载门（world-full-predownload-gate P1）：GET /worlds/:wid/packs 一次拉齐该世界要用的所有
 * 内容包——① 所有场景 manifest 并集 ② 核心包 bgm/voice_items/build_parts/stickers ③ 在场故事册
 * voice_story_*，去重、只列已登记。用真实 .mltr 矩阵 + 真实 pack.json 键跑通并集。
 */

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TERRAIN = join(REPO, 'assets', 'terrain');
const PACKS = join(REPO, 'assets', 'packs');

function packKeys(name: string): string[] {
  const doc = JSON.parse(readFileSync(join(PACKS, name, 'pack.json'), 'utf8')) as {
    entries: Record<string, unknown>;
  };
  return Object.keys(doc.entries);
}
function mltrB64(scene: string): string {
  return readFileSync(join(TERRAIN, `${scene}.mltr`)).toString('base64');
}
function reg(store: WorldStore, name: string, byte = 1, keys: string[] = []): string {
  return store.registerPack(name, { bytes: new Uint8Array([byte]), mime: 'application/octet-stream' }, keys).hash;
}
async function app(store: WorldStore) {
  return buildServer({ adapters: createMockAdapters(), store });
}
// 直接往 store 塞一个带 storyRole 的角色（免走 seedStoryCharacters 的立绘生成）。
function storyChar(worldId: string, id: string, bookId: string): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: 'd', spriteAsset: 'h', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 20, tileY: 15 }, sceneId: 'village_forest', abilities: [], relationships: {},
    storyRole: { bookId, castId: 'gate', resident: false },
  };
}
async function seedScene(store: WorldStore, worldId: string, sid: string, mltr: string): Promise<void> {
  const a = await app(store);
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    const r = await a.inject({
      method: 'POST', url: '/admin/scenes', headers: { 'x-admin-token': 'sesame' },
      payload: { worldId, sceneId: sid, name: sid, terrainBase64: mltr },
    });
    assert.equal(r.statusCode, 200, `seed ${sid} 应 200`);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await a.close();
  }
}

// ── store 级 worldPacks 并集 ───────────────────────────────────────────────────

test('worldPacks：场景并集 + 核心包 + 在场故事册语音，去重排序', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  // village → base；snow_interior → toyroom（见 content_packs.test.ts 的映射）
  await seedScene(store, 'w1', 'village', mltrB64('village'));
  await seedScene(store, 'w1', 'snow_interior', mltrB64('snow_interior'));
  store.addCharacter(storyChar('w1', 'hood:gate', 'hood'));
  // 注册：两个场景包 + 四个核心包 + 在场册 hood 的语音包
  reg(store, 'base', 1, packKeys('base'));
  reg(store, 'toyroom', 2, packKeys('toyroom'));
  reg(store, 'bgm', 3);
  reg(store, 'voice_items', 4);
  reg(store, 'build_parts', 5, packKeys('build_parts'));
  reg(store, 'stickers', 6, packKeys('stickers'));
  reg(store, 'voice_story_hood', 7);

  const packs = store.worldPacks('w1');
  const names = packs.map((p) => p.name);
  assert.deepEqual(
    names,
    ['base', 'bgm', 'build_parts', 'stickers', 'toyroom', 'voice_items', 'voice_story_hood'],
    '并集 = 场景(base+toyroom) ∪ 核心 ∪ 在场册 hood，按名排序',
  );
  // 去重：无重复名
  assert.equal(new Set(names).size, names.length, '无重复包');
  // 携带 hash + bytes
  const bgm = packs.find((p) => p.name === 'bgm')!;
  assert.equal(bgm.bytes, 1);
  assert.ok(bgm.hash.length > 0);
});

test('worldPacks：无故事角色的世界不含 voice_story_*', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  await seedScene(store, 'w1', 'village', mltrB64('village'));
  reg(store, 'base', 1, packKeys('base'));
  reg(store, 'bgm', 2);
  // 即使 voice_story_hood 已登记，没有 hood 角色在场 → 不列
  reg(store, 'voice_story_hood', 3);
  const names = store.worldPacks('w1').map((p) => p.name);
  assert.ok(!names.includes('voice_story_hood'), '无 hood 角色 → 不下 hood 语音');
  assert.ok(names.includes('base') && names.includes('bgm'));
});

test('worldPacks：只下【在场】故事册的语音（在场 hood 下、缺场 oz 不下）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  await seedScene(store, 'w1', 'village', mltrB64('village'));
  store.addCharacter(storyChar('w1', 'hood:gate', 'hood'));
  reg(store, 'base', 1, packKeys('base'));
  reg(store, 'voice_story_hood', 2);
  reg(store, 'voice_story_oz', 3); // 已登记但 oz 角色不在场
  const names = store.worldPacks('w1').map((p) => p.name);
  assert.ok(names.includes('voice_story_hood'), '在场 hood → 下');
  assert.ok(!names.includes('voice_story_oz'), '缺场 oz → 不下');
});

test('worldPacks：未登记的核心包静默跳过（过渡期优雅缺失）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  await seedScene(store, 'w1', 'village', mltrB64('village'));
  reg(store, 'base', 1, packKeys('base'));
  // 不注册 bgm/voice_items/build_parts/stickers
  const names = store.worldPacks('w1').map((p) => p.name);
  assert.deepEqual(names, ['base'], '核心包未登记则不列，只剩已登记的 base');
});

// ── 路由 ───────────────────────────────────────────────────────────────────────

test('GET /worlds/:wid/packs：返回 worldPacks', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  await seedScene(store, 'w1', 'village', mltrB64('village'));
  reg(store, 'base', 1, packKeys('base'));
  reg(store, 'bgm', 2);
  const a = await app(store);
  t.after(() => a.close());
  const res = await a.inject({ method: 'GET', url: '/worlds/w1/packs' });
  assert.equal(res.statusCode, 200);
  const body = res.json() as { packs: { name: string; hash: string; bytes: number }[] };
  assert.deepEqual(body.packs.map((p) => p.name), ['base', 'bgm']);
  assert.ok(body.packs.every((p) => p.hash.length > 0 && p.bytes > 0));
});

test('GET /worlds/:wid/packs：未知世界 → 404', async (t) => {
  const store = new WorldStore();
  const a = await app(store);
  t.after(() => a.close());
  const res = await a.inject({ method: 'GET', url: '/worlds/nope/packs' });
  assert.equal(res.statusCode, 404);
});
