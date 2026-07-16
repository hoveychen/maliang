import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import {
  handleWsMessage,
  newVoiceSession,
  isConnectionDead,
  HEARTBEAT_TIMEOUT_MS,
} from '../src/server.ts';

function ctx() {
  const store = new WorldStore();
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  return { store, sent, socket, adapters: createMockAdapters(), limiter: new RateLimiter(100, 100) };
}

test('ping → 回 pong，标记 pingCapable，刷新 lastSeenMs', async () => {
  const { store, sent, socket, adapters, limiter } = ctx();
  const session = newVoiceSession();
  session.lastSeenMs = 0; // 陈旧值，验证被刷新
  await handleWsMessage(socket, JSON.stringify({ type: 'ping' }), adapters, store, limiter, 'c1', session);
  assert.deepEqual(sent.map((m) => m.type), ['pong'], '仅回一条 pong');
  assert.equal(session.pingCapable, true, 'ping 后标记本连接会发 ping');
  assert.ok(session.lastSeenMs > 0, 'lastSeenMs 被刷新到当前时刻');
});

test('任意消息都刷新 lastSeenMs（不止 ping）', async () => {
  const { store, socket, adapters, limiter } = ctx();
  store.createWorld('w1');
  const session = newVoiceSession();
  session.lastSeenMs = 0;
  await handleWsMessage(socket, JSON.stringify({ type: 'time_sync', t0: 5 }), adapters, store, limiter, 'c1', session);
  assert.ok(session.lastSeenMs > 0, 'time_sync 也刷新 lastSeenMs');
  assert.equal(session.pingCapable, false, '非 ping 消息不置 pingCapable');
});

test('isConnectionDead：老客户端(未发过 ping)永不判死，哪怕极久静默', () => {
  const session = newVoiceSession();
  session.pingCapable = false;
  session.lastSeenMs = 0;
  const now = HEARTBEAT_TIMEOUT_MS * 100; // 远超超时
  assert.equal(isConnectionDead(session, now), false, '老客户端零流量不误杀');
});

test('isConnectionDead：新客户端(发过 ping)超时才判死', () => {
  const session = newVoiceSession();
  session.pingCapable = true;
  session.lastSeenMs = 10_000;
  assert.equal(
    isConnectionDead(session, 10_000 + HEARTBEAT_TIMEOUT_MS - 1),
    false,
    '未到超时不判死',
  );
  assert.equal(
    isConnectionDead(session, 10_000 + HEARTBEAT_TIMEOUT_MS + 1),
    true,
    '超时判死',
  );
});
