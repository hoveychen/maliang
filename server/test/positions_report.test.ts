import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldHub } from '../src/world_hub.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character, type Player } from '../src/types.ts';

function seedChar(store: WorldStore, id: string): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, abilities: [], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function seedPlayer(store: WorldStore, id: string): void {
  const p: Player = { id, name: '小明', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
  store.upsertPlayer(p);
}

/** 建一个种好世界/角色的 store + 收包 socket。 */
function harness() {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const send = (msg: object, session = newVoiceSession()) =>
    handleWsMessage(socket, JSON.stringify(msg), createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session);
  return { store, sent, send };
}

test('positions_report：批量落地角色 tile，成功无回包', async () => {
  const { store, sent, send } = harness();
  seedChar(store, 'c1');
  seedChar(store, 'c2');

  await send({
    type: 'positions_report', worldId: 'w1',
    chars: [{ id: 'c1', tileX: 10, tileY: 20 }, { id: 'c2', tileX: 3, tileY: 4 }],
  });

  assert.deepEqual(sent, [], '成功不回包（与 prop_place 一致）');
  assert.deepEqual(store.getCharacter('w1', 'c1')?.position, { tileX: 10, tileY: 20 });
  assert.deepEqual(store.getCharacter('w1', 'c2')?.position, { tileX: 3, tileY: 4 });
});

test('positions_report：越界 tile 静默丢弃，同批合法条目照常落地', async () => {
  const { store, sent, send } = harness();
  seedChar(store, 'good');
  seedChar(store, 'bad');

  await send({
    type: 'positions_report', worldId: 'w1',
    chars: [
      { id: 'bad', tileX: 500, tileY: 500 },   // 旧世界死值：越界
      { id: 'good', tileX: 7, tileY: 8 },
      { id: 'bad', tileX: -1, tileY: 0 },      // 负数
      { id: 'bad', tileX: 75, tileY: 0 },      // 上界开区间
      { id: 'bad', tileX: 1.5, tileY: 0 },     // 非整数
    ],
  });

  assert.deepEqual(sent, [], '有一个落地就不报错');
  assert.deepEqual(store.getCharacter('w1', 'good')?.position, { tileX: 7, tileY: 8 });
  assert.deepEqual(store.getCharacter('w1', 'bad')?.position, WORLD_CENTER_TILE, '坏条目一个都没写进去');
});

test('positions_report：整批无一落地（角色 id 错配）→ 回 error', async () => {
  const { sent, send } = harness();
  await send({ type: 'positions_report', worldId: 'w1', chars: [{ id: 'ghost', tileX: 1, tileY: 1 }] });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].type, 'error');
});

test('positions_report：空 chars 不回 error（静止时的心跳/只报玩家）', async () => {
  const { store, sent, send } = harness();
  seedPlayer(store, 'p1');
  const session = newVoiceSession();

  await send({ type: 'positions_report', worldId: 'w1', chars: [], player: { tileX: 5, tileY: 6 }, playerId: 'p1' }, session);

  assert.deepEqual(sent, []);
  assert.deepEqual(store.getPlayerTile('w1', DEFAULT_SCENE, 'p1'), { tileX: 5, tileY: 6 });
});

test('positions_report：玩家 tile 落地；越界玩家 tile 丢弃', async () => {
  const { store, send } = harness();
  seedChar(store, 'c1');
  seedPlayer(store, 'p1');

  await send({ type: 'positions_report', worldId: 'w1', playerId: 'p1', chars: [{ id: 'c1', tileX: 1, tileY: 1 }], player: { tileX: 9, tileY: 9 } });
  assert.deepEqual(store.getPlayerTile('w1', DEFAULT_SCENE, 'p1'), { tileX: 9, tileY: 9 });

  await send({ type: 'positions_report', worldId: 'w1', playerId: 'p1', chars: [{ id: 'c1', tileX: 2, tileY: 2 }], player: { tileX: 500, tileY: 500 } });
  assert.deepEqual(store.getPlayerTile('w1', DEFAULT_SCENE, 'p1'), { tileX: 9, tileY: 9 }, '越界不覆盖旧值');
});

test('positions_report：无 playerId 时不写玩家位置（不误挂到别人头上）', async () => {
  const { store, send } = harness();
  seedChar(store, 'c1');
  seedPlayer(store, 'p1');

  await send({ type: 'positions_report', worldId: 'w1', chars: [{ id: 'c1', tileX: 1, tileY: 1 }], player: { tileX: 9, tileY: 9 } });
  assert.equal(store.getPlayerTile('w1', DEFAULT_SCENE, 'p1'), undefined);
});

test('world_state 回带 playerPos：上次离开时的 tile', async () => {
  const { store, sent, send } = harness();
  seedPlayer(store, 'p1');
  store.setPlayerTile('w1', DEFAULT_SCENE, 'p1', { tileX: 11, tileY: 22 });

  await send({ type: 'world_info', worldId: 'w1', playerId: 'p1', locations: [] });

  const ws = sent.find((m) => m.type === 'world_state');
  assert.ok(ws, '应回 world_state');
  assert.deepEqual(ws.playerPos, { tileX: 11, tileY: 22 });
});

test('world_state：首次进世界（无档案/无坐标）不带 playerPos', async () => {
  const { store, sent, send } = harness();
  seedPlayer(store, 'p1'); // 有档案但从没上报过位置

  await send({ type: 'world_info', worldId: 'w1', playerId: 'p1', locations: [] });

  const ws = sent.find((m) => m.type === 'world_state');
  assert.equal(ws.playerPos, undefined, '客户端据此按小神仙旁降生');
});

/** 两个客户端进同一世界的收包台（带 hub，测复制位置转发）。 */
function relayHarness() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const conn = (connKey: string) => {
    const sent: any[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const session = newVoiceSession();
    const say = (msg: object) => handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub);
    return { sent, say, ofType: (t: string) => sent.filter((m) => m.type === t) };
  };
  return { store, conn };
}

test('positions_report 流式：世界坐标转发给同世界其他连接（排除自己），tile 仍持久化', async () => {
  const { store, conn } = relayHarness();
  seedChar(store, 'c1');
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb' });
  a.sent.length = 0;
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', playerId: 'pa', t: 12345,
    chars: [{ id: 'c1', tileX: 10, tileY: 20, x: 100.5, y: 200.25 }],
    player: { tileX: 5, tileY: 6, x: 50.0, y: 60.0 },
  });

  // 自己不回收自己的复制包
  assert.equal(a.ofType('positions_relay').length, 0, '发送者不该收到自己的转发');
  // 同世界另一端收到，携世界坐标 + 玩家(以 playerId 为 actor 键) + 时戳
  const relay = b.ofType('positions_relay');
  assert.equal(relay.length, 1);
  assert.equal(relay[0].t, 12345);
  assert.deepEqual(relay[0].chars, [{ id: 'c1', x: 100.5, y: 200.25 }]);
  assert.deepEqual(relay[0].player, { id: 'pa', x: 50.0, y: 60.0 });
  // tile 照常持久化
  assert.deepEqual(store.getCharacter('w1', 'c1')?.position, { tileX: 10, tileY: 20 });
  assert.deepEqual(store.getPlayerTile('w1', DEFAULT_SCENE, 'pa'), { tileX: 5, tileY: 6 });
});

test('positions_report 纯 tile（无 x,y）不触发转发（维持旧持久化路径）', async () => {
  const { store, conn } = relayHarness();
  seedChar(store, 'c1');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb' });
  b.sent.length = 0;

  await a.say({ type: 'positions_report', worldId: 'w1', playerId: 'pa', chars: [{ id: 'c1', tileX: 1, tileY: 1 }] });

  assert.equal(b.ofType('positions_relay').length, 0, '无世界坐标不转发');
  assert.deepEqual(store.getCharacter('w1', 'c1')?.position, { tileX: 1, tileY: 1 });
});

test('positions_report：角色 id 属于别的世界 → 不跨世界写入', async () => {
  const { store, sent, send } = harness();
  store.createWorld('w2');
  seedChar(store, 'c1'); // 在 w1

  await send({ type: 'positions_report', worldId: 'w2', chars: [{ id: 'c1', tileX: 1, tileY: 1 }] });

  assert.equal(sent[0]?.type, 'error');
  assert.deepEqual(store.getCharacter('w1', 'c1')?.position, WORLD_CENTER_TILE);
});
