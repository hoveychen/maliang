import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer, generateCreationIcons, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { CREATION_OPTIONS } from '../src/creation_options.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

test('generateCreationIcons：全量生成 + 幂等 + force 重生', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  // 首次：全部生成，映射落库
  const r1 = await generateCreationIcons(adapters, store);
  assert.equal(r1.generated.length, CREATION_OPTIONS.length);
  assert.equal(r1.skipped.length, 0);
  assert.equal(r1.failed.length, 0);
  assert.ok(store.getCreationIcon('cat').length > 0, 'cat 应有图标 hash');
  assert.equal(Object.keys(store.listCreationIcons()).length, CREATION_OPTIONS.length);
  // 幂等：再跑全部跳过
  const r2 = await generateCreationIcons(adapters, store);
  assert.equal(r2.generated.length, 0);
  assert.equal(r2.skipped.length, CREATION_OPTIONS.length);
  // force：全量重生
  const r3 = await generateCreationIcons(adapters, store, { force: true });
  assert.equal(r3.generated.length, CREATION_OPTIONS.length);
  assert.equal(r3.skipped.length, 0);
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
    assert.equal(body.generated.length, CREATION_OPTIONS.length);
    assert.ok(body.icons.cat && body.icons.cat.length > 0);

    const get = await app.inject({ method: 'GET', url: '/admin/creation-icons' });
    assert.equal(get.statusCode, 200);
    const listed = (get.json() as { icons: Record<string, string> }).icons;
    assert.equal(Object.keys(listed).length, CREATION_OPTIONS.length);
  } finally {
    await app.close();
  }
});

test('生成后 creation_prompt 的选项带上真实 iconAsset', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    await app.inject({ method: 'GET', url: '/worlds/default' }); // 种小神仙
    await generateCreationIcons(createMockAdapters(), store); // 先生成图标
    const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
    const session = newVoiceSession();
    const sock = fakeSocket();
    await handleWsMessage(
      sock,
      JSON.stringify({ type: 'voice_transcript', worldId: 'default', characterId: fairy.id, transcript: '我想要一只小动物' }),
      createMockAdapters(), store, new RateLimiter(100, 100), 'test', session,
    );
    const prompt = sock.sent.find((m) => m.type === 'creation_prompt');
    assert.ok(prompt, '应下发 creation_prompt');
    const options = prompt!.options as Array<{ id: string; iconAsset: string }>;
    assert.ok(options.length > 0);
    for (const o of options) assert.ok(o.iconAsset.length > 0, `选项 ${o.id} 应带 iconAsset`);
  } finally {
    await app.close();
  }
});
