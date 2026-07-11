// Presence：同场景在场玩家名单。位置流只在人「动起来」时才发，静止的玩家在别人屏幕上
// 根本不存在（旧行为）；presence 让进场即可见，并把真实立绘（spriteAsset）带给对端。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession, notifyHubLeave } from '../src/server.ts';
import { WorldHub } from '../src/world_hub.ts';
import { voiceForPlayer } from '../src/voice_catalog.ts';

function rig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const conn = (connKey: string) => {
    const sent: any[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const session = newVoiceSession();
    const say = (msg: object) =>
      handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub);
    return { sent, say, connKey, ofType: (t: string) => sent.filter((m) => m.type === t) };
  };
  return { store, hub, conn };
}

/** world_info 的 profile：服务端据此 upsert Player（name/spriteAsset 就是 presence 要下发的）。 */
function profile(name: string, sprite: string) {
  return { name, nickname: '', gender: 'boy', color: '蓝', spriteAsset: sprite, createdAt: '2026-01-01' };
}

test('presence：进世界即拿到同场景在场玩家快照（含真实立绘与位置）', async () => {
  const { store, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明', 'hashA') });
  store.setPlayerTile('w1', 'village', 'pa', { tileX: 12, tileY: 34 });

  const b = conn('cB');
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红', 'hashB') });

  const snap = b.ofType('actors_snapshot');
  assert.equal(snap.length, 1, 'B 进场应收到快照');
  assert.equal(snap[0].sceneId, 'village');
  assert.deepEqual(snap[0].actors, [
    { playerId: 'pa', name: '小明', spriteAsset: 'hashA', voiceId: voiceForPlayer('pa', 'boy'), tile: { tileX: 12, tileY: 34 } },
  ], '静止不动的 A 也要出现在名单里');
});

test('presence：新玩家进场，同场景的老玩家收到 actor_join（带立绘）', async () => {
  const { conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明', 'hashA') });
  a.sent.length = 0;

  const b = conn('cB');
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红', 'hashB') });

  const join = a.ofType('actor_join');
  assert.equal(join.length, 1);
  assert.equal(join[0].actor.playerId, 'pb');
  assert.equal(join[0].actor.name, '小红');
  assert.equal(join[0].actor.spriteAsset, 'hashB');
  assert.equal(join[0].sceneId, 'village');
});

test('presence：不同场景互不可见（快照不含、join 不发）', async () => {
  const { conn } = rig();
  const c = conn('cC');
  await c.say({ type: 'world_info', worldId: 'w1', playerId: 'pc', sceneId: 'forest', profile: profile('森林娃', 'hashC') });
  c.sent.length = 0;

  const b = conn('cB');
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红', 'hashB') });

  assert.deepEqual(b.ofType('actors_snapshot')[0].actors, [], 'village 里没有别人');
  assert.equal(c.ofType('actor_join').length, 0, '森林里的 C 不该收到 village 的 join');
});

test('presence：走 portal 换场景——旧场景收 actor_leave，新场景收 actor_join，自己拿新快照', async () => {
  const { store, conn } = rig();
  const b = conn('cB'); // village 留守
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红', 'hashB') });
  const c = conn('cC'); // forest 留守
  await c.say({ type: 'world_info', worldId: 'w1', playerId: 'pc', sceneId: 'forest', profile: profile('森林娃', 'hashC') });
  store.setPlayerTile('w1', 'forest', 'pc', { tileX: 5, tileY: 5 });

  const a = conn('cA'); // A 先在 village
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明', 'hashA') });
  b.sent.length = 0;
  c.sent.length = 0;
  a.sent.length = 0;

  await a.say({ type: 'enter_scene', worldId: 'w1', sceneId: 'forest' });

  assert.deepEqual(b.ofType('actor_leave'), [{ type: 'actor_leave', playerId: 'pa', sceneId: 'village' }],
    'village 的 B 要即时清掉 A 的副本');
  assert.equal(c.ofType('actor_join').length, 1, 'forest 的 C 要看见 A 进来');
  assert.equal(c.ofType('actor_join')[0].actor.playerId, 'pa');

  const snap = a.ofType('actors_snapshot');
  assert.equal(snap.length, 1, 'A 换场景后要拿到新场景的名单');
  assert.deepEqual(snap[0].actors, [
    { playerId: 'pc', name: '森林娃', spriteAsset: 'hashC', voiceId: voiceForPlayer('pc', 'boy'), tile: { tileX: 5, tileY: 5 } },
  ]);
});

test('presence：断连的 actor_leave 只发给同场景的人', async () => {
  const { hub, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明', 'hashA') });
  const b = conn('cB');
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红', 'hashB') });
  const c = conn('cC');
  await c.say({ type: 'world_info', worldId: 'w1', playerId: 'pc', sceneId: 'forest', profile: profile('森林娃', 'hashC') });
  b.sent.length = 0;
  c.sent.length = 0;

  notifyHubLeave(hub, 'cA', undefined, 'pa');

  assert.equal(b.ofType('actor_leave').length, 1, '同场景的 B 要收到');
  assert.equal(c.ofType('actor_leave').length, 0, '隔壁场景的 C 本来就看不见 A');
});
