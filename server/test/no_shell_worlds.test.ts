import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { buildServer, handleWsMessage, newVoiceSession } from '../src/server.ts';

// 空壳 world 脏数据根治（docs 见对话记录）：
//  ① POST /worlds 端点删除——它是唯一凭空造「只有点点」壳 world 的路径，无合法调用方。
//  ② world_info / startVisit 加护栏——对不存在的 world 不落孤儿 visit 行。

test('POST /worlds 端点已移除（不再凭空造壳 world）', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const res = await app.inject({ method: 'POST', url: '/worlds' });
    assert.equal(res.statusCode, 404, 'POST /worlds 应已下线，返回 404');
    // 兜底：即便路由存在也绝不能留下壳 world
    assert.equal(store.listWorlds().length, 0, '不应创建任何 world');
  } finally {
    await app.close();
  }
});

test('world_info：对不存在的 world 不落孤儿 visit、不起会话', async () => {
  const store = new WorldStore();
  // 故意不 createWorld('ghost')
  const sent: unknown[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const adapters = createMockAdapters();
  const rest = [adapters, store, new RateLimiter(100, 100), 'conn1', session] as const;

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'ghost', playerId: 'p1' }), ...rest);

  assert.equal(store.listVisits('ghost').length, 0, '不存在的 world 不应落 visit 行');
  assert.equal(session.visit, null, '不存在的 world 不应起会话');
});

test('startVisit：纵深护栏——world 不存在直接不落行', () => {
  const store = new WorldStore();
  const id = store.startVisit('ghost', 'p1', 1000);
  assert.equal(id, -1, 'world 不存在应返回 -1（未落库）');
  assert.equal(store.listVisits('ghost').length, 0, '不应有 visit 行');
});

test('world_info：对存在的 world 仍正常落 visit（不误伤）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: unknown[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const adapters = createMockAdapters();
  const rest = [adapters, store, new RateLimiter(100, 100), 'conn1', session] as const;

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: 'p1' }), ...rest);

  assert.equal(store.listVisits('w1').length, 1, '存在的 world 应正常记一条 visit');
  assert.ok(session.visit, '应起会话');
});
