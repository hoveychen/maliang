import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import {
  handleWsMessage,
  newVoiceSession,
  startSessionVisit,
  recordVisitTurn,
  endSessionVisit,
} from '../src/server.ts';
import type { Character, MemoryExtractionContext } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string): Character {
  const c: Character = {
    id, worldId, isFairy: false, name: '小兔', personality: '活泼开朗', voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: ['move_to', 'deliver_message'], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

/** 计数版 mock：包一层 extractMemory 数调用次数，验「省调用」。 */
function countingAdapters() {
  const base = createMockAdapters();
  const counter = { extract: 0 };
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async extractMemory(ctx: MemoryExtractionContext) {
        counter.extract++;
        return base.llm.extractMemory(ctx);
      },
    },
  };
  return { adapters, counter };
}

test('Visit：world_info 起会话 → 多轮对话只在 leave_world 批量抽一次（省调用）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const sent: unknown[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const { adapters, counter } = countingAdapters();
  const rest = [adapters, store, new RateLimiter(100, 100), 'conn1', session] as const;

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: 'p1' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '我叫朵朵' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好呀' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '再见啦' }), ...rest);
  assert.equal(counter.extract, 0, '会话进行中不应抽取');

  await handleWsMessage(socket, JSON.stringify({ type: 'leave_world' }), ...rest);
  assert.equal(counter.extract, 1, '离开时对该角色只批量抽一次（3 轮 → 1 次调用，省调用）');
  assert.deepEqual(store.getMemories('c1', 'p1').map((m) => m.text), ['小朋友叫朵朵'], '整段会话抽出名字');
  assert.equal(session.visit, null, 'leave_world 后 Visit 应收尾清出');
  const visits = store.listVisits('w1');
  assert.equal(visits.length, 1, '应记一条 Visit');
  assert.ok(visits[0]!.endedAt !== null, 'Visit 应已收尾（ended_at 落值）');
});

test('Visit：掉线（socket.close 兜底 endSessionVisit）也 flush 会话记忆并收尾', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const sent: unknown[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const { adapters } = countingAdapters();
  const rest = [adapters, store, new RateLimiter(100, 100), 'conn1', session] as const;

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: 'p1' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '我叫朵朵' }), ...rest);
  // 不发 leave_world，直接模拟 socket.close 的兜底 flush
  await endSessionVisit(session, adapters, store, 2000);

  assert.deepEqual(store.getMemories('c1', 'p1').map((m) => m.text), ['小朋友叫朵朵'], '掉线也应抽出记忆');
  assert.equal(session.visit, null, '兜底后 Visit 应收尾');
  assert.ok(store.listVisits('w1')[0]!.endedAt !== null, 'Visit 应已收尾');
});

test('recordVisitTurn：单角色超阈值中途 flush（清空已抽取增量，兜底长会话掉线）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const session = newVoiceSession();
  const adapters = createMockAdapters();
  startSessionVisit(session, 'w1', 'p1', adapters, store, 1000);
  for (let i = 0; i < 19; i++) recordVisitTurn(session, 'w1', 'p1', 'c1', `话${i}`, '嗯', adapters, store);
  assert.equal(session.visit!.pending.get('c1')!.length, 19, '未到阈值应继续累积');
  recordVisitTurn(session, 'w1', 'p1', 'c1', '第二十句', '嗯', adapters, store); // 第 20 句触发中途 flush
  assert.equal(session.visit!.pending.get('c1')!.length, 0, '到阈值应中途 flush 并清空增量（增量已交给后台抽取）');
});

test('startSessionVisit：换世界/重开会话先收尾旧 Visit（不丢旧世界的记忆）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.createWorld('w2');
  seedChar(store, 'w1', 'c1');
  const session = newVoiceSession();
  const adapters = createMockAdapters();
  startSessionVisit(session, 'w1', 'p1', adapters, store, 1000);
  recordVisitTurn(session, 'w1', 'p1', 'c1', '我叫朵朵', '你好', adapters, store);
  // 未 leave 直接进新世界 → 旧 Visit 应被收尾
  startSessionVisit(session, 'w2', 'p1', adapters, store, 2000);
  assert.equal(session.visit!.worldId, 'w2', '当前 Visit 应指向新世界');
  const visits = store.listVisits();
  const w1v = visits.find((v) => v.worldId === 'w1')!;
  assert.ok(w1v.endedAt !== null, '旧世界 Visit 应已收尾');
});
