// 造物记忆（session-context P5）：
// 造完角色/物品，小仙子记一条 kind='creation' 的记忆（归属当前玩家）；
// 下次造物会话与 routeIntent 都能看到「最近造过的东西」，支持「帮我造刚才的小动物，但是会飞的」。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { newCreationState, type CreationState } from '../src/types.ts';
import { OpenRouterLLMAdapter } from '../src/adapters/openrouter_llm.ts';
import { OpenRouterClient } from '../src/adapters/openrouter_client.ts';
import type { ServiceAdapters } from '../src/adapters/types.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seeded(): Promise<{ store: WorldStore; fairyId: string; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  await app.inject({ method: 'GET', url: '/worlds/default' });
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  return { store, fairyId: fairy.id, close: () => app.close() };
}

async function ws(adapters: ServiceAdapters, store: WorldStore, session: VoiceSession, msg: Record<string, unknown>) {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), adapters, store, limiter, 'test', session);
  return sock.sent;
}

test('造角色完成 → 仙子记 creation 记忆（归属玩家，含描述）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    // 快捷路径：一句说全 → 首轮即造
    const sent = await ws(createMockAdapters(), store, session, {
      type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只会飞的红色小猫',
    });
    assert.ok(sent.some((m) => m.type === 'gen_complete'), '角色应造出来');
    const mems = store.getMemories(fairyId, 'kid-1').filter((m) => m.kind === 'creation');
    assert.equal(mems.length, 1, '造完仙子应记一条 creation 记忆');
    assert.ok(mems[0].text.includes('猫'), `记忆应包含造了什么：${mems[0].text}`);
    assert.equal(mems[0].aboutPlayer, 'kid-1', '记忆归属当前玩家');
  } finally {
    await close();
  }
});

test('造物品完成 → 仙子记 creation 记忆', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    const sent = await ws(createMockAdapters(), store, session, {
      type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个红色的风车',
    });
    assert.ok(sent.some((m) => m.type === 'item_created'), '物品应造出来');
    const mems = store.getMemories(fairyId, 'kid-1').filter((m) => m.kind === 'creation');
    assert.equal(mems.length, 1);
    assert.ok(mems[0].text.includes('风车'), `记忆应包含造了什么：${mems[0].text}`);
  } finally {
    await close();
  }
});

test('再开造物会话 → CreationState 带上「最近造过」，guide prompt 注入（支持「刚才的小动物」）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    store.addMemory(fairyId, { text: '帮小朋友造过新伙伴「毛毛」（一只红色的小猫）', kind: 'creation', aboutPlayer: 'kid-1', ts: 0 });
    // 含糊入口 → 开引导会话
    await ws(createMockAdapters(), store, session, {
      type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小动物',
    });
    assert.ok(session.creation?.active, '应开引导会话');
    assert.ok(
      session.creation!.recentCreations?.some((t) => t.includes('毛毛')),
      '会话状态应带上最近造过的东西',
    );
  } finally {
    await close();
  }
});

test('openrouter guide：recentCreations 注入 system；routeIntent 注入「帮小朋友造过的东西」分组', async () => {
  const bodies: Array<{ messages: Array<{ role: string; content: string }> }> = [];
  const orig = globalThis.fetch;
  globalThis.fetch = (async (_url: unknown, init: { body: string }) => {
    bodies.push(JSON.parse(init.body));
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: '{"replyText":"好","done":false,"question":"什么颜色？","category":"color","optionIds":["red"],"kind":"chat","emotion":"happy"}' } }] }) };
  }) as typeof fetch;
  try {
    const llm = new OpenRouterLLMAdapter(new OpenRouterClient('test-key'), 'test-model');
    const state: CreationState = { ...newCreationState(), recentCreations: ['帮小朋友造过新伙伴「毛毛」（一只红色的小猫）'] };
    await llm.guideCreation(state, '帮我造刚才的小动物，但是会飞的');
    const guideSystem = bodies[0].messages.find((m) => m.role === 'system')!.content;
    assert.ok(guideSystem.includes('毛毛'), 'guide system 应带最近造过的东西');

    await llm.routeIntent('帮我造刚才的小动物', {
      characterName: '小仙子', personality: '温柔', abilities: ['create_character'],
      memory: [{ text: '帮小朋友造过新伙伴「毛毛」（一只红色的小猫）', kind: 'creation' }],
    });
    const intentSystem = bodies[1].messages.find((m) => m.role === 'system')!.content;
    assert.ok(intentSystem.includes('毛毛'), 'routeIntent 记忆注入应包含 creation 分组');
  } finally {
    globalThis.fetch = orig;
  }
});
