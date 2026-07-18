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

// ── P2：清理入口 ────────────────────────────────────────────────

test('deleteWorld：级联删角色/记忆/对话/visit，且只删目标世界', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.createWorld('w2'); // 无辜旁观世界，不应被误删
  const char = {
    id: 'c1', worldId: 'w1', isFairy: false, name: '小兔', personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle' as const,
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: [], relationships: {},
  };
  store.addCharacter(char);
  store.addMemory('c1', { text: '小朋友叫朵朵', kind: 'identity', aboutPlayer: 'p1', ts: 1 });
  store.addChatTurn('c1', 'p1', 'child', '你好', 1);
  store.startVisit('w1', 'p1', 1000);

  // w2 也放点东西，验证不被误删
  store.addCharacter({ ...char, id: 'c2', worldId: 'w2' });
  store.startVisit('w2', 'p2', 2000);

  const deleted = store.deleteWorld('w1');
  assert.equal(deleted, true, '删成功返回 true');
  assert.equal(store.worldExists('w1'), false, 'world 行应没了');
  assert.equal(store.listCharacters('w1').length, 0, '角色应级联删');
  assert.equal(store.getMemories('c1', 'p1').length, 0, '记忆应级联删');
  assert.equal(store.getRecentTurns('c1', 'p1', 10).length, 0, '对话应级联删');
  assert.equal(store.listVisits('w1').length, 0, 'visit 应级联删');

  // w2 毫发无损
  assert.equal(store.worldExists('w2'), true, '旁观世界不应被删');
  assert.equal(store.listCharacters('w2').length, 1, '旁观世界角色还在');
  assert.equal(store.listVisits('w2').length, 1, '旁观世界 visit 还在');
});

test('deleteWorld：删不存在的 world 返回 false（幂等，不炸）', () => {
  const store = new WorldStore();
  assert.equal(store.deleteWorld('ghost'), false);
});

test('DELETE /admin/worlds/:id：门禁 + 删除 + 不存在返回 404', async () => {
  process.env.MALIANG_ADMIN_TOKEN = 'secret';
  const store = new WorldStore();
  store.createWorld('doomed');
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    // 无 token → 403
    const denied = await app.inject({ method: 'DELETE', url: '/admin/worlds/doomed' });
    assert.equal(denied.statusCode, 403, '无 token 应 403');
    assert.equal(store.worldExists('doomed'), true, '被拒时不应删');

    // 带 token → 200 且真的删了
    const ok = await app.inject({ method: 'DELETE', url: '/admin/worlds/doomed', headers: { 'x-admin-token': 'secret' } });
    assert.equal(ok.statusCode, 200, '带 token 应 200');
    assert.equal(store.worldExists('doomed'), false, '应真的删掉');

    // 不存在的 world → 404
    const missing = await app.inject({ method: 'DELETE', url: '/admin/worlds/ghost', headers: { 'x-admin-token': 'secret' } });
    assert.equal(missing.statusCode, 404, '不存在的 world 应 404');
  } finally {
    await app.close();
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
