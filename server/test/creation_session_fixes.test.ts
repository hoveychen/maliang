// 引导式创造的三个循环缺陷修复（session-context P1）：
// ① 点选选项 → 服务端按 option.category 确定性入账，不再依赖 LLM 把 label 解析进 updatedAttrs；
// ② openrouter guideCreation/guideProp 的 prompt 带上「已问类别 + 上一轮问题」，LLM 有上下文解读答案；
// ③ advanceCreation 服务端统一超轮兜底强制造（此前只有 mock 里有 turnCount>=5，线上会无限追问）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { newCreationState, type CreationState, type GuideCreationResult } from '../src/types.ts';
import { optionsByCategory } from '../src/creation_options.ts';
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

/** 「笨 LLM」适配器：guide 永远追问 kind、绝不解析 updatedAttrs、绝不 done——模拟线上解析失败的最坏情况。 */
function dumbGuideAdapters(): ServiceAdapters {
  const adapters = createMockAdapters();
  const dumb = async (_state: CreationState, _input: string): Promise<GuideCreationResult> => ({
    replyText: '你想要什么样的小伙伴呀？',
    done: false,
    question: '你想要什么样的小伙伴呀？',
    category: 'kind',
    optionIds: optionsByCategory('kind').slice(0, 4).map((o) => o.id),
  });
  adapters.llm.guideCreation = dumb;
  adapters.llm.guideProp = dumb;
  return adapters;
}

async function wsWith(
  adapters: ServiceAdapters,
  store: WorldStore,
  session: VoiceSession,
  msg: Record<string, unknown>,
): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), adapters, store, limiter, 'test', session);
  return sock.sent;
}

// ── 缺陷①：点选入账不依赖 LLM ─────────────────────────────────────────────

test('缺陷①：creation_reply 点选「红」→ 即使 LLM 不解析，attrs.color 也确定性入账', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.creation = newCreationState();
    await wsWith(dumbGuideAdapters(), store, session, {
      type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'red',
    });
    assert.ok(session.creation, '笨 LLM 不 done，会话还在');
    assert.equal(session.creation!.attrs.color, '红', '点选的颜色必须由服务端按 category 直接写入 attrs');
  } finally {
    await close();
  }
});

test('缺陷①：trait 点选累积入账、不重复', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.creation = newCreationState();
    const msg = { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'fly' };
    await wsWith(dumbGuideAdapters(), store, session, msg);
    await wsWith(dumbGuideAdapters(), store, session, msg); // 重复点同一张卡
    assert.ok(session.creation);
    assert.deepEqual(session.creation!.attrs.traits, ['会飞'], 'trait 入账且去重');
  } finally {
    await close();
  }
});

// ── 缺陷③：服务端超轮兜底强制造 ──────────────────────────────────────────

test('缺陷③：LLM 永不 done 也永不解析 → 超轮后服务端强制造完（不无限追问）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.creation = newCreationState();
    const adapters = dumbGuideAdapters();
    let allSent: Array<Record<string, unknown>> = [];
    // 最多 8 轮点选；修复后应在 turnCount 兜底线（5）附近强制进入造角色收尾
    for (let i = 0; i < 8 && session.creation; i++) {
      const sent = await wsWith(adapters, store, session, {
        type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'cat',
      });
      allSent = allSent.concat(sent);
    }
    assert.equal(session.creation, null, '超轮后会话必须收尾，不能无限追问');
    assert.ok(allSent.some((m) => m.type === 'gen_complete'), '强制造要真的走完造角色（gen_complete）');
  } finally {
    await close();
  }
});

// ── 缺陷②：openrouter prompt 带上下文 ────────────────────────────────────

function captureFetch(): { captured: { body?: { messages: Array<{ role: string; content: string }> } }; restore: () => void } {
  const orig = globalThis.fetch;
  const captured: { body?: { messages: Array<{ role: string; content: string }> } } = {};
  globalThis.fetch = (async (_url: unknown, init: { body: string }) => {
    captured.body = JSON.parse(init.body);
    return {
      ok: true,
      status: 200,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({ replyText: '好呀！', done: false, question: '什么颜色呀？', category: 'color', optionIds: ['red'] }) } }],
      }),
    };
  }) as typeof fetch;
  return { captured, restore: () => { globalThis.fetch = orig; } };
}

test('缺陷②：guideCreation prompt 须带已问类别与上一轮问题（LLM 才能解读「毛毛」是在答名字）', async () => {
  const { captured, restore } = captureFetch();
  try {
    const llm = new OpenRouterLLMAdapter(new OpenRouterClient('test-key'), 'test-model');
    const state: CreationState = {
      active: true,
      goal: 'character',
      attrs: { kind: '猫', color: '红', traits: [] },
      askedCategories: ['kind', 'color', 'name'],
      turnCount: 3,
      lastQuestion: '你想给它取什么名字呀？',
    };
    await llm.guideCreation(state, '毛毛');
    assert.ok(captured.body, '应发出请求');
    const messages = captured.body!.messages;
    const all = JSON.stringify(messages);
    assert.ok(all.includes('你想给它取什么名字呀？'), 'prompt 里必须能看到上一轮问的问题');
    assert.ok(/已问|问过/.test(all), 'prompt 里必须声明已问过的类别，避免重复问');
  } finally {
    restore();
  }
});

test('缺陷②：guideProp prompt 同样带上一轮问题', async () => {
  const { captured, restore } = captureFetch();
  try {
    const llm = new OpenRouterLLMAdapter(new OpenRouterClient('test-key'), 'test-model');
    const state: CreationState = {
      active: true,
      goal: 'prop',
      attrs: { kind: '风车', traits: [] },
      askedCategories: ['kind', 'color'],
      turnCount: 2,
      lastQuestion: '你想要什么颜色的风车呀？',
    };
    await llm.guideProp(state, '彩虹色');
    const all = JSON.stringify(captured.body!.messages);
    assert.ok(all.includes('你想要什么颜色的风车呀？'), 'prompt 里必须能看到上一轮问的问题');
  } finally {
    restore();
  }
});
