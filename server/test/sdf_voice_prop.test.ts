import { ANON_PLAYER } from '../src/types.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer, createPropAsync, createCharacterAsync, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
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
  seedFairyWorld(store);
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

// 「我想要一只小猫」对小神仙说 → create_character 被摘出为 characterRequest，脚本不下发客户端
test('respondToTranscript: 造角色意图摘出 characterRequest', async () => {
  const { store, fairyId, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const r = await respondToTranscript('default', fairyId, '', '我想要一只会飞的小猫', adapters, store);
    assert.equal(r.characterRequest, '我想要一只会飞的小猫');
    assert.equal(r.propRequest, undefined); // 造角色不误判成造物
    assert.equal(r.behaviorScript, undefined); // 摘空后不下发
    assert.ok(r.replyText.length > 0);
  } finally {
    await close();
  }
});

// 没有 create_character 能力的普通角色说同样的话 → 不触发造角色
test('respondToTranscript: 无 create_character 能力不触发造角色', async () => {
  const { store, fairyId, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const fairy = store.getCharacter('default', fairyId)!;
    const plain = { ...fairy, id: 'npc-2', isFairy: false, abilities: ['move_to'] };
    store.addCharacter(plain);
    const r = await respondToTranscript('default', 'npc-2', '', '我想要一只小猫', adapters, store);
    assert.equal(r.characterRequest, undefined);
  } finally {
    await close();
  }
});

// 异步造物：item_created 推送 + items 实体行 + 背包一份；违禁词 → prop_failed 且不入库
test('createPropAsync: 设计→校验→实体行+背包→推送 / 审核拦截', async () => {
  const { store, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', ANON_PLAYER, '会走路的小房子', adapters, store);
    // sent[0] 是开造即报的 prop_pending（客户端据此立熔炉），成品跟在后面；
    // 造完还会补一条 npc_wishes（造物已被发现 → 重发漏话，见 wishes.ts），故不写死总长度。
    assert.equal(sock.sent[0].type, 'prop_pending');
    assert.equal(sock.sent[1].type, 'item_created');
    const item = sock.sent[1].item as { id: string; worldId: string; renderRef: string; spec: { parts: unknown[] } };
    assert.equal(item.worldId, 'default', '造物实体归属世界（据此可拾起）');
    assert.equal(item.renderRef, 'sdf_inline');
    assert.ok(item.spec.parts.length > 0);
    assert.equal(store.listWorldItems('default').length, 1, '实体行入库');
    assert.deepEqual(sock.sent[1].bag, { [item.id]: 1 }, '造好即入背包');

    const sock2 = fakeSocket();
    await createPropAsync(sock2, 'default', ANON_PLAYER, '一把恐怖的枪', adapters, store);
    assert.equal(sock2.sent[1].type, 'prop_failed');
    assert.equal(store.listWorldItems('default').length, 1); // 没多存
  } finally {
    await close();
  }
});

// 异步造角色：gen_progress 逐阶段 + gen_complete 入库；违禁词 → gen_failed 且不入库
test('createCharacterAsync: 造角色管线→gen_complete 入库 / 审核拦截', async () => {
  const { store, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const before = store.listCharacters('default').length;
    const sock = fakeSocket();
    await createCharacterAsync(sock, 'default', ANON_PLAYER, '一只会飞的小猫', adapters, store);
    const types = sock.sent.map((m) => m.type);
    assert.ok(types.includes('gen_progress')); // 逐阶段推进
    const done = sock.sent.find((m) => m.type === 'gen_complete');
    assert.ok(done, 'should emit gen_complete');
    const character = done!.character as { id: string; isFairy: boolean };
    assert.equal(character.isFairy, false); // 造出来的是普通角色，不是又一个小仙子
    assert.equal(store.listCharacters('default').length, before + 1); // 入库

    // 审核拦截走 gen_failed：造角色审的是 spec（mock designCharacter 会把输入洗成安全 spec，
    // 无法靠脏输入触发），故直接覆写 moderateText 强制拒绝，验证 catch→gen_failed 且不入库。
    const blocking = { ...adapters, moderation: { moderateText: async () => ({ allowed: false, reason: 'x' }) } };
    const sock2 = fakeSocket();
    await createCharacterAsync(sock2, 'default', ANON_PLAYER, '一只小狗', blocking, store);
    assert.equal(sock2.sent.at(-1)!.type, 'gen_failed'); // 审核拦截
    assert.equal(store.listCharacters('default').length, before + 1); // 没多存
  } finally {
    await close();
  }
});

// 端到端：对小仙子说「想要一只小猫」→ 语音回合摘出 characterRequest → 异步造角色 gen_complete
test('语音造角色端到端：respondToTranscript 摘出 → createCharacterAsync 落地', async () => {
  const { store, fairyId, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const before = store.listCharacters('default').length;
    const r = await respondToTranscript('default', fairyId, '', '我想要一只小恐龙', adapters, store);
    assert.ok(r.characterRequest, '应摘出 characterRequest');
    const sock = fakeSocket();
    await createCharacterAsync(sock, 'default', ANON_PLAYER, r.characterRequest!, adapters, store);
    assert.ok(sock.sent.some((m) => m.type === 'gen_complete'));
    assert.equal(store.listCharacters('default').length, before + 1);
  } finally {
    await close();
  }
});

// 造物入背包 + 磁盘持久化 roundtrip：重开 store 后实体行与背包都还在；
// GET /worlds 的 items 带上造物；场景无矩阵时摆放 → error 不动账。
test('item_created 入背包 + 磁盘 roundtrip + 无矩阵摆放拒绝', async () => {
  const dir = join(tmpdir(), 'maliang-test-voice-prop');
  rmSync(dir, { recursive: true, force: true });
  const adapters = createMockAdapters();
  const store = new WorldStore(dir);
  const app = await buildServer({ adapters, store });
  try {
    seedFairyWorld(store);
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', ANON_PLAYER, '造一个小风车', adapters, store);
    const itemId = ((sock.sent.find((m) => m.type === 'item_created'))!.item as { id: string }).id;

    // GET /worlds 的 items 含该造物（内置 + 世界造物）
    const world = await app.inject({ method: 'GET', url: '/worlds/default' });
    const body = world.json() as { items: Array<{ id: string }> };
    assert.ok(body.items.some((d) => d.id === itemId));

    // 重开 store：实体行与背包都在
    const store2 = new WorldStore(dir);
    assert.equal(store2.listWorldItems('default').length, 1);
    assert.deepEqual(store2.getBag('default', ANON_PLAYER), { [itemId]: 1 });

    // default 世界此时没有场景矩阵：item_place → error，背包不动
    const limiter = new RateLimiter(100, 100);
    const sock3 = fakeSocket();
    await handleWsMessage(
      sock3,
      JSON.stringify({ type: 'item_place', worldId: 'default', itemId, tileX: 1, tileY: 1 }),
      adapters, store, limiter, 'test', newVoiceSession(),
    );
    assert.equal(sock3.sent[0].type, 'error');
    assert.deepEqual(store.getBag('default', ANON_PLAYER), { [itemId]: 1 }, '失败不动账');
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

// 异步施法占位符：扣花成功后立刻推 prop_pending，客户端据此退出对话、就地长出魔法熔炉，
// 孩子自由走动而不是卡在对话里干等。设计/生图慢，这条信号必须抢在它们前面发出去。
test('createPropAsync: 扣花后立刻推 prop_pending（先于 item_created）', async () => {
  const { store, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', ANON_PLAYER, '一朵小花', adapters, store);
    assert.equal(sock.sent[0]!.type, 'prop_pending', '第一条必须是 prop_pending');
    assert.equal(sock.sent[1]!.type, 'item_created');
    // 花在开造那一刻就扣掉：占位符立起来的同时钱包要对得上
    assert.ok(sock.sent[0]!.wallet, 'prop_pending 应带上扣花后的钱包');
  } finally {
    await close();
  }
});

// 造失败也要让客户端能收起熔炉：prop_pending 已经发出去了，失败必须跟一条 prop_failed。
test('createPropAsync: 审核拦截时 prop_pending 之后跟 prop_failed', async () => {
  const { store, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', ANON_PLAYER, '一把恐怖的枪', adapters, store);
    assert.equal(sock.sent[0]!.type, 'prop_pending');
    assert.equal(sock.sent[1]!.type, 'prop_failed');
  } finally {
    await close();
  }
});

// 花不够时根本没开造：不该立熔炉，只推 reward_denied。
test('createPropAsync: 小红花不足 → 不发 prop_pending', async () => {
  const { store, close } = await seededStore();
  try {
    const adapters = createMockAdapters();
    while (store.spendFlower('default', ANON_PLAYER)) { /* 花光 */ }
    const sock = fakeSocket();
    await createPropAsync(sock, 'default', ANON_PLAYER, '一朵小花', adapters, store);
    assert.ok(!sock.sent.some((m) => m.type === 'prop_pending'), '没开造就不该立熔炉');
  } finally {
    await close();
  }
});
