// 远端玩家跨端锚点（remote-player-anchors P1，docs/character-anchors-design.md §5「玩家的存设备档案 + actors 流转发」）：
// 玩家 anchors 存在设备档案，随 world_info.profile 上报进服务端 Player 记录，再经 presence 转发给同场景其他人，
// 让「别人看到的我」也吃到真锚点（而非 alpha 兜底）。本测试覆盖服务端半段：
//   - world_info 建 Player 时把 profile.anchors 落库（轻校验/夹紧）
//   - 畸形 anchors 丢弃、不污染 Player
//   - presenceOf 把 Player.anchors 带进对外视图
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession, presenceOf } from '../src/server.ts';

const ANCHORS = {
  headTop: { x: 0.5, y: 0.08 },
  handL: { x: 0.2, y: 0.6 },
  handR: { x: 0.8, y: 0.6 },
  source: 'vision' as const,
};

function harness() {
  const store = new WorldStore();
  store.createWorld('w1');
  const socket = { send: (_s: string) => {} };
  const session = newVoiceSession();
  return { store, socket, session };
}

async function register(h: ReturnType<typeof harness>, profile: Record<string, unknown>) {
  await handleWsMessage(
    h.socket,
    JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: 'p1', sceneId: 'village', profile }),
    createMockAdapters(), h.store, new RateLimiter(100, 100), 'conn1', h.session,
  );
}

test('world_info：profile 带 anchors → 落进 Player 记录', async () => {
  const h = harness();
  await register(h, { name: '朵朵', spriteAsset: 'deadbeef', anchors: ANCHORS });
  const p = h.store.getPlayer('p1');
  assert.ok(p, '应建玩家行');
  assert.deepEqual(p?.anchors, ANCHORS, 'anchors 应原样落库');
});

test('world_info：畸形 anchors（缺手）→ 丢弃，不污染 Player', async () => {
  const h = harness();
  await register(h, { name: '朵朵', spriteAsset: 'deadbeef', anchors: { headTop: { x: 0.5, y: 0.1 } } });
  assert.equal(h.store.getPlayer('p1')?.anchors, undefined, '缺手的 anchors 应被丢弃');
});

test('world_info：越界坐标 → 夹紧到 [0,1]', async () => {
  const h = harness();
  await register(h, {
    name: '朵朵', spriteAsset: 'deadbeef',
    anchors: { headTop: { x: 1.5, y: -0.2 }, handL: { x: 0.2, y: 0.6 }, handR: { x: 0.8, y: 0.6 } },
  });
  assert.deepEqual(h.store.getPlayer('p1')?.anchors?.headTop, { x: 1.0, y: 0.0 }, '越界坐标应夹紧');
});

test('presenceOf：Player.anchors 带进对外视图', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.upsertPlayer({ id: 'p1', name: '朵朵', nickname: '', gender: 'girl', color: '', spriteAsset: 'deadbeef', createdAt: '', anchors: ANCHORS });
  const pres = presenceOf(store, 'w1', 'village', 'p1');
  assert.deepEqual(pres.anchors, ANCHORS, 'presence 应带 anchors');
});

test('presenceOf：无 anchors 的老档 → presence 不带该字段（远端走 alpha 兜底）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.upsertPlayer({ id: 'p2', name: '小明', nickname: '', gender: 'boy', color: '', spriteAsset: 'cafe', createdAt: '' });
  const pres = presenceOf(store, 'w1', 'village', 'p2');
  assert.equal(pres.anchors, undefined, '老档 presence 不应带 anchors');
});
