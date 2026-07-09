import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character, WorldProp } from '../src/types.ts';

function makeCharacter(id: string, worldId: string, name: string, isFairy = false): Character {
  return {
    id, worldId, isFairy, name, personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: '一只小兔', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 2, tileY: 3 }, abilities: ['move_to'], relationships: {},
  };
}

/** 造两个世界：w1 有角色/记忆/对话/物品/会话/背包，w2 空。玩家 p1。 */
function seed(store: WorldStore): void {
  store.createWorld('w1');
  store.createWorld('w2');
  store.addCharacter(makeCharacter('c1', 'w1', '小兔'));
  store.addCharacter(makeCharacter('fairy1', 'w1', '小神仙', true));
  store.upsertPlayer({ id: 'p1', name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉', spriteAsset: '', createdAt: '2026-07-08' });
  store.addMemory('c1', { text: '小朋友叫朵朵', kind: 'identity', aboutPlayer: 'p1', ts: 0 });
  store.addChatTurn('c1', 'p1', 'child', '你好', 0);
  store.addChatTurn('c1', 'p1', 'npc', '你好朵朵', 0);
  const prop: WorldProp = {
    id: 'prop1',
    spec: { name: '小花', parts: [] } as unknown as WorldProp['spec'],
    tile: [3, 4],
    state: 'placed',
  };
  store.addProp('w1', prop);
  store.addSticker('w1', 'flower', 2);
  store.setLocations('w1', ['小池塘']);
  const v1 = store.startVisit('w1', 'p1', 1000);
  store.endVisit(v1, 2000);
  store.startVisit('w1', 'p1', 3000); // 进行中
}

async function makeApp() {
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  return app;
}

test('GET /debug/api/overview：各资源计数 + 最近会话', async () => {
  const app = await makeApp();
  try {
    const res = await app.inject({ method: 'GET', url: '/debug/api/overview' });
    assert.equal(res.statusCode, 200);
    const s = res.json();
    assert.equal(s.players, 1);
    assert.equal(s.worlds, 2);
    assert.equal(s.characters, 2);
    assert.equal(s.props, 1);
    assert.equal(s.visits.total, 2);
    assert.equal(s.visits.active, 1);
    assert.equal(s.recentVisits.length, 2);
    assert.equal(s.recentVisits[0].startedAt, 3000, '最近会话按开始时间倒序');
  } finally {
    await app.close();
  }
});

test('GET /debug/api/players 与 /debug/api/players/:id：列表带会话统计，详情带记忆/对话归属', async () => {
  const app = await makeApp();
  try {
    const list = await app.inject({ method: 'GET', url: '/debug/api/players' });
    assert.equal(list.statusCode, 200);
    const ps = list.json().players;
    assert.equal(ps.length, 1);
    assert.equal(ps[0].name, '朵朵');
    assert.equal(ps[0].visitCount, 2);
    assert.equal(ps[0].lastVisitAt, 3000);

    const detail = await app.inject({ method: 'GET', url: '/debug/api/players/p1' });
    assert.equal(detail.statusCode, 200);
    const d = detail.json();
    assert.equal(d.player.id, 'p1');
    assert.equal(d.visits.length, 2);
    assert.equal(d.memories.length, 1);
    assert.equal(d.memories[0].characterName, '小兔');
    assert.equal(d.memories[0].items[0].text, '小朋友叫朵朵');
    assert.equal(d.chats.length, 1);
    assert.equal(d.chats[0].turns.length, 2);

    const missing = await app.inject({ method: 'GET', url: '/debug/api/players/nope' });
    assert.equal(missing.statusCode, 404);
  } finally {
    await app.close();
  }
});

test('GET /debug/api/worlds 与 /debug/api/worlds/:id：列表计数摘要，详情带角色/物品/会话', async () => {
  const app = await makeApp();
  try {
    const list = await app.inject({ method: 'GET', url: '/debug/api/worlds' });
    assert.equal(list.statusCode, 200);
    const ws = list.json().worlds;
    assert.equal(ws.length, 2);
    const w1 = ws.find((w: { id: string }) => w.id === 'w1');
    assert.equal(w1.characterCount, 2);
    assert.equal(w1.fairyCount, 1);
    assert.equal(w1.propCount, 1);
    assert.equal(w1.visitCount, 2);
    assert.equal(w1.activeVisitCount, 1);
    assert.equal(w1.inventory.flower, 2);
    assert.deepEqual(w1.locations, ['小池塘']);

    const detail = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1' });
    assert.equal(detail.statusCode, 200);
    const d = detail.json();
    assert.equal(d.characters.length, 2);
    const c1 = d.characters.find((c: { id: string }) => c.id === 'c1');
    assert.equal(c1.memoryCount, 1);
    assert.equal(c1.chatTurnCount, 2);
    assert.equal(d.props.length, 1);
    assert.equal(d.visits.length, 2);

    const missing = await app.inject({ method: 'GET', url: '/debug/api/worlds/nope' });
    assert.equal(missing.statusCode, 404);
  } finally {
    await app.close();
  }
});

test('角色摘要 spriteAnimStatus 与玩家详情 spriteAnim：无立绘 none，有动画 ready', async () => {
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    // 无立绘 → none（角色表 + 玩家详情都兜底）
    const before = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1' });
    assert.equal(before.json().characters.find((c: { id: string }) => c.id === 'c1').spriteAnimStatus, 'none');
    const pBefore = await app.inject({ method: 'GET', url: '/debug/api/players/p1' });
    assert.equal(pBefore.json().spriteAnim.status, 'none');

    // 给角色/玩家挂上立绘并置动画 ready → 状态透出
    const meta = { cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60 };
    const sprite = store.putAsset({ bytes: Uint8Array.from([1]), mime: 'image/png' });
    const c1 = store.getCharacter('w1', 'c1')!;
    c1.appearance.spriteAsset = sprite;
    store.saveCharacter(c1);
    store.setSpriteAnimReady(sprite, 'atlasA', meta);
    const p1 = store.getPlayer('p1')!;
    store.upsertPlayer({ ...p1, spriteAsset: sprite });

    const after = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1' });
    assert.equal(after.json().characters.find((c: { id: string }) => c.id === 'c1').spriteAnimStatus, 'ready');
    const pAfter = await app.inject({ method: 'GET', url: '/debug/api/players/p1' });
    assert.equal(pAfter.json().spriteAnim.status, 'ready');
    assert.equal(pAfter.json().spriteAnim.animAsset, 'atlasA');
  } finally {
    await app.close();
  }
});

test('GET /debug/api/worlds/:id/characters/:cid：完整角色 + 记忆 + 对话 + 动画状态', async () => {
  const app = await makeApp();
  try {
    const res = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1/characters/c1' });
    assert.equal(res.statusCode, 200);
    const d = res.json();
    assert.equal(d.character.name, '小兔');
    assert.equal(d.character.personality, '活泼');
    assert.equal(d.memories.length, 1);
    assert.equal(d.chatTurns.length, 2);
    assert.equal(d.spriteAnim.status, 'none');

    const missing = await app.inject({ method: 'GET', url: '/debug/api/worlds/w1/characters/nope' });
    assert.equal(missing.statusCode, 404);
  } finally {
    await app.close();
  }
});

test('/debug/api/*：配置 MALIANG_ADMIN_TOKEN 后无 token 拒绝、带 token 放行', async () => {
  const prev = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'secret-abc';
  const store = new WorldStore();
  seed(store);
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    for (const url of ['/debug/api/overview', '/debug/api/players', '/debug/api/worlds', '/debug/api/worlds/w1', '/debug/api/worlds/w1/characters/c1']) {
      const denied = await app.inject({ method: 'GET', url });
      assert.equal(denied.statusCode, 403, `${url} 无 token 应拒绝`);
      const okQuery = await app.inject({ method: 'GET', url: `${url}?token=secret-abc` });
      assert.equal(okQuery.statusCode, 200, `${url} ?token= 应放行`);
      const okHeader = await app.inject({ method: 'GET', url, headers: { 'x-admin-token': 'secret-abc' } });
      assert.equal(okHeader.statusCode, 200, `${url} x-admin-token 应放行`);
    }
  } finally {
    await app.close();
    if (prev === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prev;
  }
});
