// 对话 session 化（session-context P2）：
// - 喂给 routeIntent 的对话历史覆盖当前 Visit（进世界→离开）的全部轮次，不再截尾近 6 条；
// - 重进世界 = 全新 session：上一段 Visit 的对话不带进上下文（长期记忆走 memories，不靠 chat_turns 回放）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import type { ServiceAdapters } from '../src/adapters/types.ts';
import type { ChatTurn } from '../src/types.ts';

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

/** 包一层 mock：每次 routeIntent 把收到的 recentHistory 记下来，回复仍走 mock。 */
function capturingAdapters(): { adapters: ServiceAdapters; histories: ChatTurn[][] } {
  const adapters = createMockAdapters();
  const histories: ChatTurn[][] = [];
  const orig = adapters.llm.routeIntent.bind(adapters.llm);
  adapters.llm.routeIntent = async (transcript, ctx) => {
    histories.push((ctx.recentHistory ?? []).map((t) => ({ ...t })));
    return orig(transcript, ctx);
  };
  return { adapters, histories };
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

test('session 上下文完整：第 6 轮对话时能看到前 5 轮全部 10 条，不截尾', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const { adapters, histories } = capturingAdapters();
    const session = newVoiceSession();
    await wsWith(adapters, store, session, { type: 'world_info', worldId: 'default', locations: [] });
    for (let i = 1; i <= 6; i++) {
      await wsWith(adapters, store, session, {
        type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: `我们聊聊第${i}件事吧`,
      });
    }
    assert.equal(histories.length, 6);
    assert.equal(histories[5].length, 10, '第 6 轮应看到前 5 轮全部 10 条（child+npc），不是截尾后的 6 条');
    assert.ok(histories[5][0].text.includes('第1件事'), '最早一轮也要在上下文里');
  } finally {
    await close();
  }
});

test('重进世界=新 session：上一段 Visit 的对话不带进上下文', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const { adapters, histories } = capturingAdapters();
    const session = newVoiceSession();
    await wsWith(adapters, store, session, { type: 'world_info', worldId: 'default', locations: [] });
    await wsWith(adapters, store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '今天我去了动物园' });
    await wsWith(adapters, store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '看到了大象' });
    await wsWith(adapters, store, session, { type: 'leave_world' });
    // 重进：新 Visit，从零开始（记忆靠 flushMemory 落 memories，不靠 chat_turns 回放）
    await wsWith(adapters, store, session, { type: 'world_info', worldId: 'default', locations: [] });
    await wsWith(adapters, store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '你好呀' });
    assert.equal(histories.length, 3);
    assert.equal(histories[2].length, 0, '新 session 首轮上下文应为空，不带上一段的对话');
  } finally {
    await close();
  }
});
