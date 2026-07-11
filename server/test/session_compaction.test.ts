// session 超长压缩（session-context P3）：
// 上下文（history+摘要）超阈值 → 较旧轮次压成摘要、history 只留近尾；摘要注入 routeIntent。
// 阈值缺省 200k 字（中文≈1字/token），本文件用 SESSION_COMPACT_CHARS 调小做端到端验证——
// 必须在 import server.ts 之前设好（模块加载时读一次），故全文件用动态 import。
process.env.SESSION_COMPACT_CHARS = '600';

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { ChatTurn } from '../src/types.ts';
import type { ServiceAdapters } from '../src/adapters/types.ts';

const { createMockAdapters } = await import('../src/adapters/mock.ts');
const { buildServer, handleWsMessage, newVoiceSession, maybeCompactVisit } = await import('../src/server.ts');
const { WorldStore } = await import('../src/persistence.ts');
const { RateLimiter } = await import('../src/ratelimit.ts');
type VoiceSession = ReturnType<typeof newVoiceSession>;

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seeded() {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  await app.inject({ method: 'GET', url: '/worlds/default' });
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  return { store, fairyId: fairy.id, close: () => app.close() };
}

function capturingAdapters(): { adapters: ServiceAdapters; summaries: (string | undefined)[] } {
  const adapters = createMockAdapters();
  const summaries: (string | undefined)[] = [];
  const orig = adapters.llm.routeIntent.bind(adapters.llm);
  adapters.llm.routeIntent = async (transcript, ctx) => {
    summaries.push(ctx.sessionSummary);
    return orig(transcript, ctx);
  };
  return { adapters, summaries };
}

async function wsWith(adapters: ServiceAdapters, store: InstanceType<typeof WorldStore>, session: VoiceSession, msg: Record<string, unknown>) {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), adapters, store, limiter, 'test', session);
  return sock.sent;
}

test('maybeCompactVisit：超阈值 → 旧轮次折叠成摘要，history 只留近尾 10 条', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const adapters = createMockAdapters();
    const session = newVoiceSession();
    await wsWith(adapters, store, session, { type: 'world_info', worldId: 'default', locations: [] });
    const turns: ChatTurn[] = [];
    for (let i = 0; i < 30; i++) turns.push({ role: i % 2 === 0 ? 'child' : 'npc', text: `第${i}句`.padEnd(60, '呀'), ts: 0 });
    session.visit!.history.set(fairyId, turns);
    await maybeCompactVisit(session, fairyId, adapters, store); // 30×60字 > 600 阈值
    const hist = session.visit!.history.get(fairyId)!;
    assert.equal(hist.length, 10, '压缩后只留近尾 10 条');
    assert.ok(hist[0].text.startsWith('第20句'), '留下的是最近的轮次');
    const summary = session.visit!.summary.get(fairyId);
    assert.ok(summary && summary.includes('压缩了20条'), `摘要应折叠了前 20 条：${summary}`);
  } finally {
    await close();
  }
});

test('maybeCompactVisit：未超阈值不动 history、不出摘要', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const adapters = createMockAdapters();
    const session = newVoiceSession();
    await wsWith(adapters, store, session, { type: 'world_info', worldId: 'default', locations: [] });
    const turns: ChatTurn[] = Array.from({ length: 12 }, (_, i) => ({ role: (i % 2 === 0 ? 'child' : 'npc') as ChatTurn['role'], text: '短', ts: 0 }));
    session.visit!.history.set(fairyId, turns);
    await maybeCompactVisit(session, fairyId, adapters, store);
    assert.equal(session.visit!.history.get(fairyId)!.length, 12, '没超阈值不该动');
    assert.equal(session.visit!.summary.get(fairyId), undefined);
  } finally {
    await close();
  }
});

test('openrouter：sessionSummary 注入 routeIntent 的 system；compactSession 带上次摘要与旧轮次', async () => {
  const { OpenRouterLLMAdapter } = await import('../src/adapters/openrouter_llm.ts');
  const { OpenRouterClient } = await import('../src/adapters/openrouter_client.ts');
  const bodies: Array<{ messages: Array<{ role: string; content: string }> }> = [];
  const orig = globalThis.fetch;
  globalThis.fetch = (async (_url: unknown, init: { body: string }) => {
    bodies.push(JSON.parse(init.body));
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: '{"kind":"chat","replyText":"好","emotion":"happy"}' } }] }) };
  }) as typeof fetch;
  try {
    const llm = new OpenRouterLLMAdapter(new OpenRouterClient('test-key'), 'test-model');
    await llm.routeIntent('你好', {
      characterName: '小蓝', personality: '活泼', abilities: [],
      sessionSummary: '之前聊过小朋友喜欢恐龙',
    });
    const system = bodies[0].messages.find((m) => m.role === 'system')!.content;
    assert.ok(system.includes('之前聊过小朋友喜欢恐龙'), 'system 应注入压缩摘要');

    await llm.compactSession({
      characterName: '小蓝', personality: '活泼',
      previousSummary: '上次的摘要内容',
      turns: [{ role: 'child', text: '我们去河边吧', ts: 0 }, { role: 'npc', text: '好呀走！', ts: 0 }],
    });
    const user = bodies[1].messages.find((m) => m.role === 'user')!.content;
    assert.ok(user.includes('上次的摘要内容'), '压缩要并入上次摘要');
    assert.ok(user.includes('我们去河边吧'), '压缩要带旧轮次原文');
  } finally {
    globalThis.fetch = orig;
  }
});

test('端到端：对话把上下文聊超阈值 → 自动压缩 → 摘要注入后续 routeIntent，长对话不丢头', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const { adapters, summaries } = capturingAdapters();
    const session = newVoiceSession();
    await wsWith(adapters, store, session, { type: 'world_info', worldId: 'default', locations: [] });
    // 每轮 child 40 字 + mock 回显 ≈ 100 字；600 字阈值几轮就破 → recordVisitTurn 自动触发压缩
    for (let i = 1; i <= 12; i++) {
      await wsWith(adapters, store, session, {
        type: 'voice_transcript', worldId: 'default', characterId: fairyId,
        transcript: `这是第${i}轮的话`.padEnd(40, '呀'),
      });
      await new Promise((r) => setTimeout(r, 5)); // 压缩是后台 fire-and-forget，等一拍
    }
    assert.ok(session.visit!.summary.get(fairyId), '聊超阈值后应产生压缩摘要');
    assert.ok(summaries.some((s) => s && s.includes('压缩了')), '压缩后的轮次 routeIntent 应收到 sessionSummary');
    const hist = session.visit!.history.get(fairyId)!;
    assert.ok(hist.length < 24, `history 应被压缩过（现 ${hist.length} 条）`);
  } finally {
    await close();
  }
});
