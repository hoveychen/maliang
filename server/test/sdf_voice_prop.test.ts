import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer, createPropAsync, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { respondToTranscript } from '../src/voice.ts';
import { RateLimiter } from '../src/ratelimit.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seededStore(): Promise<{ store: WorldStore; fairyId: string; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  await app.inject({ method: 'GET', url: '/worlds/default' }); // 建 default 世界 + 种小神仙
  const fairy = store.listCharacters('default').find((c) => c.isFairy);
  assert.ok(fairy);
  return { store, fairyId: fairy!.id, close: () => app.close() };
}

// 「变一朵小花」对小神仙说 → create_prop 被摘出为 propRequest，脚本不下发客户端
test('respondToTranscript: 造物意图摘出 propRequest', async () => {
  const { store, fairyId, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const r = await respondToTranscript('default', fairyId, '', '帮我变一朵会点头的小花', adapters, store);
    assert.equal(r.propRequest, '帮我变一朵会点头的小花');
    assert.equal(r.behaviorScript, undefined); // 摘空后不下发
    assert.ok(r.replyText.length > 0);
  } finally {
    await close();
  }
});

// 没有 create_prop 能力的普通角色说同样的话 → 不触发造物
test('respondToTranscript: 无 create_prop 能力不触发造物', async () => {
  const { store, fairyId, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const fairy = store.getCharacter('default', fairyId)!;
    const plain = { ...fairy, id: 'npc-1', isFairy: false, abilities: ['move_to'] };
    store.addCharacter(plain);
    const r = await respondToTranscript('default', 'npc-1', '', '帮我变一朵小花', adapters, store);
    assert.equal(r.propRequest, undefined);
  } finally {
    await close();
  }
});

// 异步造物：prop_created 推送 + 入库；违禁词 → prop_failed 且不入库
test('createPropAsync: 设计→校验→持久化→推送 / 审核拦截', async () => {
  const { store, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', '会走路的小房子', adapters, store);
    assert.equal(sock.sent.length, 1);
    assert.equal(sock.sent[0].type, 'prop_created');
    const prop = sock.sent[0].prop as { id: string; spec: { parts: unknown[] }; tile: null };
    assert.ok(prop.spec.parts.length > 0);
    assert.equal(prop.tile, null);
    assert.equal(store.listProps('default').length, 1);

    const sock2 = fakeSocket();
    await createPropAsync(sock2, 'default', '一把恐怖的枪', adapters, store);
    assert.equal(sock2.sent[0].type, 'prop_failed');
    assert.equal(store.listProps('default').length, 1); // 没多存
  } finally {
    await close();
  }
});

// 落位回报 + 磁盘持久化 roundtrip：重开 store 后 props 与 tile 都还在
test('prop_place 落位回报 + worlds.json roundtrip', async () => {
  const dir = join(tmpdir(), 'maliang-test-voice-prop');
  rmSync(dir, { recursive: true, force: true });
  const adapters = createMockAdapters();
  const store = new WorldStore(dir);
  const app = await buildServer({ adapters, store });
  try {
    await app.inject({ method: 'GET', url: '/worlds/default' });
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', '造一个小风车', adapters, store);
    const propId = (sock.sent[0].prop as { id: string }).id;

    const limiter = new RateLimiter(100, 100);
    const sock2 = fakeSocket();
    await handleWsMessage(
      sock2,
      JSON.stringify({ type: 'prop_place', worldId: 'default', propId, tileX: 12, tileY: 34 }),
      adapters, store, limiter, 'test', newVoiceSession(),
    );
    assert.equal(sock2.sent.length, 0); // 成功无回包
    assert.deepEqual(store.listProps('default')[0].tile, [12, 34]);

    // GET /worlds 带 props
    const world = await app.inject({ method: 'GET', url: '/worlds/default' });
    const body = world.json() as { props: Array<{ id: string; tile: [number, number] }> };
    assert.equal(body.props.length, 1);
    assert.deepEqual(body.props[0].tile, [12, 34]);

    // 重开 store：props 从 worlds.json 恢复
    const store2 = new WorldStore(dir);
    assert.equal(store2.listProps('default').length, 1);
    assert.deepEqual(store2.listProps('default')[0].tile, [12, 34]);

    // 未知 propId → error 回包
    const sock3 = fakeSocket();
    await handleWsMessage(
      sock3,
      JSON.stringify({ type: 'prop_place', worldId: 'default', propId: 'nope', tileX: 1, tileY: 1 }),
      adapters, store, limiter, 'test', newVoiceSession(),
    );
    assert.equal(sock3.sent[0].type, 'error');
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
