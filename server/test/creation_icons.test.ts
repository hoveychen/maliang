import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer, generateCreationIcons, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { CREATION_OPTIONS } from '../src/creation_options.ts';
import { PROP_CREATION_OPTIONS } from '../src/prop_creation_options.ts';
import { STICKER_CREATION_OPTIONS } from '../src/sticker_creation_options.ts';
import { AVATAR_ICON_CATEGORIES, AVATAR_OPTIONS } from '../src/avatar_options.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

// 图标全库 = 造角色全部 + 造物专属(prop_ 前缀) + 造贴纸专属(stk_ 前缀的 kind 图案)
// + onboarding 形象图标类别(av_ 前缀；color 类客户端渲染色块，不生图)；
// 造物/贴纸的 color/size 复用造角色同 id，不另生成。
const PROP_OWN = PROP_CREATION_OPTIONS.filter((o) => o.id.startsWith('prop_'));
const STICKER_OWN = STICKER_CREATION_OPTIONS.filter((o) => o.id.startsWith('stk_'));
const AVATAR_OWN = AVATAR_OPTIONS.filter((o) => (AVATAR_ICON_CATEGORIES as readonly string[]).includes(o.category));
const TOTAL_ICONS = CREATION_OPTIONS.length + PROP_OWN.length + STICKER_OWN.length + AVATAR_OWN.length;

test('generateCreationIcons：全量生成（含造物专属）+ 幂等 + force 重生', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  // 首次：全部生成，映射落库
  const r1 = await generateCreationIcons(adapters, store);
  assert.equal(r1.generated.length, TOTAL_ICONS);
  assert.equal(r1.skipped.length, 0);
  assert.equal(r1.failed.length, 0);
  assert.ok(store.getCreationIcon('cat').length > 0, 'cat 应有图标 hash');
  assert.ok(store.getCreationIcon('prop_flower').length > 0, 'prop_flower 应有图标 hash');
  assert.ok(store.getCreationIcon('stk_sun').length > 0, 'stk_sun 贴纸图案应有图标 hash');
  assert.ok(store.getCreationIcon('av_boy').length > 0, 'av_boy 形象图标应有 hash');
  assert.ok(store.getCreationIcon('av_hair_twin').length > 0, 'av_hair_twin 形象图标应有 hash');
  assert.equal(store.getCreationIcon('av_col_red'), '', 'av_ 的 color 类不生图（客户端色块）');
  assert.equal(Object.keys(store.listCreationIcons()).length, TOTAL_ICONS);
  // 幂等：再跑全部跳过
  const r2 = await generateCreationIcons(adapters, store);
  assert.equal(r2.generated.length, 0);
  assert.equal(r2.skipped.length, TOTAL_ICONS);
  // force：全量重生
  const r3 = await generateCreationIcons(adapters, store, { force: true });
  assert.equal(r3.generated.length, TOTAL_ICONS);
  assert.equal(r3.skipped.length, 0);
});

test('generateCreationIcons：造物 color/size 复用造角色图标，不重复生成', async () => {
  const store = new WorldStore();
  await generateCreationIcons(createMockAdapters(), store);
  // 造物库里的 color/size 项（如 red/small）用的是造角色同 id 的图标，映射里只有一份
  const propColorSize = PROP_CREATION_OPTIONS.filter((o) => o.category === 'color' || o.category === 'size');
  for (const o of propColorSize) {
    assert.ok(!o.id.startsWith('prop_'), `${o.id} 应是复用的造角色 id（非 prop_ 前缀）`);
    assert.ok(store.getCreationIcon(o.id).length > 0, `复用的 ${o.id} 应已由造角色库生成`);
  }
  // 造物专属 kind/motion 都各自生成了
  for (const o of PROP_OWN) {
    assert.ok(store.getCreationIcon(o.id).length > 0, `造物专属 ${o.id} 应生成`);
  }
});

test('generateCreationIcons：only 限定只生成造物专属图标', async () => {
  const store = new WorldStore();
  const ids = PROP_OWN.map((o) => o.id);
  const r = await generateCreationIcons(createMockAdapters(), store, { only: ids });
  assert.equal(r.generated.length, PROP_OWN.length, '只生成指定的造物图标');
  assert.equal(store.getCreationIcon('cat'), '', '未指定的造角色图标不生成');
});

test('图标映射持久化 roundtrip：重开 store 仍在', async () => {
  const { rmSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const dir = join(tmpdir(), 'maliang-test-creation-icons');
  rmSync(dir, { recursive: true, force: true });
  try {
    const store = new WorldStore(dir);
    await generateCreationIcons(createMockAdapters(), store);
    const catHash = store.getCreationIcon('cat');
    assert.ok(catHash.length > 0);
    const store2 = new WorldStore(dir);
    assert.equal(store2.getCreationIcon('cat'), catHash, '重开后映射仍在');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('admin 端点：POST 生成 / GET 列表', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const post = await app.inject({ method: 'POST', url: '/admin/creation-icons' });
    assert.equal(post.statusCode, 200);
    const body = post.json() as { generated: string[]; icons: Record<string, string> };
    assert.equal(body.generated.length, TOTAL_ICONS);
    assert.ok(body.icons.cat && body.icons.cat.length > 0);
    assert.ok(body.icons.prop_flower && body.icons.prop_flower.length > 0, '造物图标也随端点生成');

    const get = await app.inject({ method: 'GET', url: '/admin/creation-icons' });
    assert.equal(get.statusCode, 200);
    const listed = (get.json() as { icons: Record<string, string> }).icons;
    assert.equal(Object.keys(listed).length, TOTAL_ICONS);
  } finally {
    await app.close();
  }
});

test('生成后 creation_prompt 的选项带上真实 iconAsset', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    seedFairyWorld(store);
    await generateCreationIcons(createMockAdapters(), store); // 先生成图标
    const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
    const session = newVoiceSession();
    const limiter = new RateLimiter(100, 100);
    await handleWsMessage(
      fakeSocket(),
      JSON.stringify({ type: 'voice_transcript', worldId: 'default', characterId: fairy.id, transcript: '我想要一只小动物' }),
      createMockAdapters(), store, limiter, 'test', session,
    );
    // A2：入口先问 recipient（其 self/大家选项无 iconAsset，村民用立绘）。答「大家」后进入 kind 追问——
    // kind 才走图标库，选项应带上真实 iconAsset。
    const sock = fakeSocket();
    await handleWsMessage(
      sock,
      JSON.stringify({ type: 'creation_reply', worldId: 'default', characterId: fairy.id, optionId: 'everyone' }),
      createMockAdapters(), store, limiter, 'test', session,
    );
    const prompt = sock.sent.find((m) => m.type === 'creation_prompt' && m.category !== 'recipient');
    assert.ok(prompt, '答完 recipient 应下发属性 creation_prompt');
    const options = prompt!.options as Array<{ id: string; iconAsset: string }>;
    assert.ok(options.length > 0);
    for (const o of options) assert.ok(o.iconAsset.length > 0, `选项 ${o.id} 应带 iconAsset`);
  } finally {
    await app.close();
  }
});
