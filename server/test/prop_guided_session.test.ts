// 引导式造物品的 WS 会话流：入口开 prop 会话（非直造）、creation_prompt 走物品图标、
// 多轮点选累积、done 走 createPropAsync（prop_pending + item_created）。与造角色 guided_creation 平行。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seeded(): Promise<{ store: WorldStore; fairyId: string; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  seedFairyWorld(store);
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  return { store, fairyId: fairy.id, close: () => app.close() };
}

async function ws(store: WorldStore, session: VoiceSession, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), createMockAdapters(), store, limiter, 'test', session);
  return sock.sent;
}

// A2「给谁做的」：造物会话最前先问一步 recipient。测试统一答「大家」(不预填 size，保留后续属性追问)。
async function answerRecipient(store: WorldStore, session: VoiceSession, fairyId: string): Promise<Array<Record<string, unknown>>> {
  return ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'everyone' });
}

test('入口：对小仙子说「变个风车」→ 开 prop 会话 + 下发 creation_prompt，不直造、不发普通回应', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    assert.equal(session.creation?.goal, 'prop', '会话目标应为 prop');
    assert.equal(session.creation?.active, true);
    const prompt = sent.find((m) => m.type === 'creation_prompt');
    assert.ok(prompt, '应下发 creation_prompt 追问');
    const options = prompt!.options as Array<{ id: string }>;
    assert.ok(options.length >= 2 && options.length <= 4);
    assert.equal(sent.some((m) => m.type === 'character_response'), false, '入口不发普通 character_response');
    assert.equal(sent.some((m) => m.type === 'prop_pending'), false, '要先引导，不在入口就开造');
  } finally {
    await close();
  }
});

test('多轮：入口给种类 → creation_reply 点颜色 → 攒够 done → prop_pending + item_created 落库', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const before = store.listWorldItems('default').length;
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    await answerRecipient(store, session, fairyId); // A2：先答 recipient，才解析入口意图
    assert.equal(session.creation?.attrs.kind, '风车');
    assert.equal(session.creation?.active, true);
    // 点颜色卡「红」(复用造角色 color id) → 攒够 → 造
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'red' });
    assert.equal(session.creation, null, '造完会话应清空');
    assert.equal(sent.some((m) => m.type === 'prop_pending'), true, '开造即报 prop_pending');
    assert.equal(sent.some((m) => m.type === 'item_created'), true, '造好推 item_created');
    assert.equal(store.listWorldItems('default').length, before + 1, '造物实体入库');
  } finally {
    await close();
  }
});

test('快捷路径：一句说全「变一个红色的风车」→ 答 recipient 后即造，不追问属性', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const before = store.listWorldItems('default').length;
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个红色的风车' });
    assert.equal(session.creation?.active, true, 'A2：入口先问 recipient');
    const sent = await answerRecipient(store, session, fairyId); // 一句说全 → 答完 recipient 即造
    assert.equal(sent.some((m) => m.type === 'creation_prompt'), false, '不再追问属性');
    assert.equal(sent.some((m) => m.type === 'item_created'), true, '直接造出来');
    assert.equal(store.listWorldItems('default').length, before + 1);
    assert.equal(session.creation, null);
  } finally {
    await close();
  }
});

test('creation_reply 点物品专属图标（prop_ 前缀）也能解析出中文 label 推进', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个东西' });
    await answerRecipient(store, session, fairyId); // A2：先答 recipient，进入属性追问
    // 点「球」种类卡（物品专属 id prop_ball；label 不与颜色/大小 label 子串碰撞）
    await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'prop_ball' });
    assert.equal(session.creation?.attrs.kind, '球', 'prop_ball 应经 findPropOption 解析成中文 label 球');
  } finally {
    await close();
  }
});

test('花不够：不进 prop 会话，推 prop_denied 引导攒花', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    while (store.spendFlower('default', session.playerId)) { /* 花光 */ }
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    assert.equal(session.creation, null, '没花不开会话');
    assert.equal(sent.some((m) => m.type === 'prop_denied'), true);
    assert.equal(sent.some((m) => m.type === 'prop_pending'), false);
  } finally {
    await close();
  }
});
