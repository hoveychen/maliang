import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer, buildDebugState } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

function seed(store: WorldStore): void {
  store.createWorld('w1');
  const c: Character = {
    id: 'c1', worldId: 'w1', isFairy: false, name: '小兔', personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 2, tileY: 3 }, abilities: ['move_to'], relationships: {},
  };
  store.addCharacter(c);
  store.upsertPlayer({ id: 'p1', name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉', spriteAsset: '', createdAt: '2026-07-08' });
  store.addMemory('c1', { text: '小朋友叫朵朵', kind: 'identity', aboutPlayer: 'p1', ts: 0 });
  store.addChatTurn('c1', 'p1', 'child', '你好', 0);
  store.addChatTurn('c1', 'p1', 'npc', '你好朵朵', 0);
  const vid = store.startVisit('w1', 'p1', 1000);
  store.endVisit(vid, 2000);
}

test('buildDebugState：汇总玩家/世界/角色/记忆/对话/Visit 只读快照', () => {
  const store = new WorldStore();
  seed(store);
  const s = buildDebugState(store);
  assert.equal(s.players.length, 1);
  assert.equal(s.players[0]!.name, '朵朵');
  assert.equal(s.worlds.length, 1);
  const w = s.worlds[0]!;
  assert.equal(w.id, 'w1');
  const c = w.characters.find((x) => x.id === 'c1')!;
  assert.equal(c.name, '小兔');
  assert.deepEqual(c.memories.map((m) => m.text), ['小朋友叫朵朵']);
  assert.equal(c.memories[0]!.kind, 'identity');
  assert.deepEqual(c.chatTurns.map((t) => t.text), ['你好', '你好朵朵']);
  assert.equal(c.chatTurns[0]!.playerId, 'p1');
  assert.equal(w.visits.length, 1);
  assert.ok(w.visits[0]!.endedAt !== null);
});

test('GET /debug/state 与 /debug：无 token 配置时开放，JSON 与 HTML 正常', async () => {
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const stateRes = await app.inject({ method: 'GET', url: '/debug/state' });
    assert.equal(stateRes.statusCode, 200);
    const s = stateRes.json() as { players: unknown[]; worlds: unknown[] };
    assert.equal(s.players.length, 1);
    assert.equal(s.worlds.length, 1);
    const htmlRes = await app.inject({ method: 'GET', url: '/debug' });
    assert.equal(htmlRes.statusCode, 200);
    assert.match(htmlRes.headers['content-type'] as string, /text\/html/);
    assert.match(htmlRes.body, /maliang 状态后台/);
    assert.match(htmlRes.body, /\/debug\/state/); // 页面确实去拉 state 接口
  } finally {
    await app.close();
  }
});

test('GET /debug/state：配置 MALIANG_ADMIN_TOKEN 后无 token 拒绝、带 token 放行', async () => {
  const prev = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'secret-xyz';
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const denied = await app.inject({ method: 'GET', url: '/debug/state' });
    assert.equal(denied.statusCode, 403, '无 token 应拒绝');
    const okQuery = await app.inject({ method: 'GET', url: '/debug/state?token=secret-xyz' });
    assert.equal(okQuery.statusCode, 200, '?token= 应放行');
    const okHeader = await app.inject({ method: 'GET', url: '/debug/state', headers: { 'x-admin-token': 'secret-xyz' } });
    assert.equal(okHeader.statusCode, 200, 'x-admin-token 头应放行');
  } finally {
    await app.close();
    if (prev === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prev;
  }
});
