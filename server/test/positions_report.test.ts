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

test('positions_report 流式：不同场景的同世界连接收不到转发（跨场景幽灵）', async () => {
  const { store, conn } = relayHarness();
  seedChar(store, 'c1');
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'forest' });
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', sceneId: 'village', playerId: 'pa', t: 1,
    chars: [{ id: 'c1', tileX: 10, tileY: 20, x: 100.5, y: 200.25 }],
    player: { tileX: 5, tileY: 6, x: 50.0, y: 60.0 },
  });

  assert.equal(b.ofType('positions_relay').length, 0, '森林里的 B 不该看见村里 A 的位置流');
});

test('positions_report 流式：同场景照常转发（场景过滤不误伤）', async () => {
  const { store, conn } = relayHarness();
  seedChar(store, 'c1');
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'forest' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'forest' });
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', sceneId: 'forest', playerId: 'pa', t: 7,
    chars: [{ id: 'c1', tileX: 10, tileY: 20, x: 1.5, y: 2.5 }],
  });

  const relay = b.ofType('positions_relay');
  assert.equal(relay.length, 1, '同一场景仍要互见');
  assert.deepEqual(relay[0].chars, [{ id: 'c1', x: 1.5, y: 2.5 }]);
});

test('positions_report 流式：走 portal 换场景后，位置流跟着新场景走', async () => {
  const { store, conn } = relayHarness();
  seedChar(store, 'c1');
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'forest' });
  // A 走 portal 去森林 → 与 B 同场景
  await a.say({ type: 'enter_scene', worldId: 'w1', sceneId: 'forest' });
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', sceneId: 'forest', playerId: 'pa', t: 9,
    chars: [{ id: 'c1', tileX: 3, tileY: 3, x: 3.5, y: 3.5 }],
  });

  assert.equal(b.ofType('positions_relay').length, 1, 'enter_scene 后 hub 里的场景要跟着更新');
});

test('positions_report 流式：不带 sceneId（高频流的真实载荷）时按 session 所在场景落盘', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village' });
  await a.say({ type: 'enter_scene', worldId: 'w1', sceneId: 'forest' });

  // 高频流（backend.gd send_positions_stream）不带 sceneId —— 不能因此把位置写回 village
  await a.say({
    type: 'positions_report', worldId: 'w1', playerId: 'pa', t: 3,
    chars: [], player: { tileX: 8, tileY: 9, x: 8.5, y: 9.5 },
  });

  assert.deepEqual(store.getPlayerTile('w1', 'forest', 'pa'), { tileX: 8, tileY: 9 }, '应落在 forest');
  assert.equal(store.getPlayerTile('w1', DEFAULT_SCENE, 'pa'), undefined, '不该漏写进 village');
});

test('positions_report：角色 id 属于别的世界 → 不跨世界写入', async () => {
  const { store, sent, send } = harness();
  store.createWorld('w2');
  seedChar(store, 'c1'); // 在 w1

  await send({ type: 'positions_report', worldId: 'w2', chars: [{ id: 'c1', tileX: 1, tileY: 1 }] });

  assert.equal(sent[0]?.type, 'error');
  assert.deepEqual(store.getCharacter('w1', 'c1')?.position, WORLD_CENTER_TILE);
});

// ── C 档球位置流 / 所有权广播（realtime-game-primitives §5）───────────────────
test('positions_report 流式：球位置(balls)转发给同场景他端(排除自己)，球不持久化为角色', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb' });
  a.sent.length = 0;
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', playerId: 'pa', t: 42,
    chars: [], balls: [{ id: 'ball1', x: 12.5, y: 34.5, vx: 6.0, vy: -1.5 }],
  });

  assert.equal(a.ofType('positions_relay').length, 0, '发送者不收自己的球流');
  const relay = b.ofType('positions_relay');
  assert.equal(relay.length, 1, '球流也要按场景转发（哪怕没有 chars/player 在动）');
  assert.equal(relay[0].t, 42);
  assert.deepEqual(relay[0].balls, [{ id: 'ball1', x: 12.5, y: 34.5, vx: 6.0, vy: -1.5 }]);
  // 球不是角色：不该被当角色持久化（getCharacter 查无）
  assert.equal(store.getCharacter('w1', 'ball1'), undefined, '球不持久化为角色');
});

test('positions_report 流式：坏球条目(缺 x/y 或缺 id)静默丢弃，不连坐整批', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb' });
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', playerId: 'pa', t: 1,
    chars: [], balls: [
      { id: '', x: 1, y: 1 },          // 空 id
      { id: 'good', x: 5, y: 6 },      // 合法（缺速度默认 0）
      { id: 'nox', y: 6 },             // 缺 x
    ],
  });

  const relay = b.ofType('positions_relay');
  assert.equal(relay.length, 1);
  assert.deepEqual(relay[0].balls, [{ id: 'good', x: 5, y: 6, vx: 0, vy: 0 }], '只留合法球，速度缺省 0');
});

test('positions_report 流式：跨场景收不到球流（幽灵球）', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'forest' });
  b.sent.length = 0;

  await a.say({
    type: 'positions_report', worldId: 'w1', sceneId: 'village', playerId: 'pa', t: 1,
    chars: [], balls: [{ id: 'ball1', x: 1, y: 1, vx: 0, vy: 0 }],
  });

  assert.equal(b.ofType('positions_relay').length, 0, '隔壁场景不该收到球流');
});

test('ball_kick：转发给同场景他端(排除自己)，服务端盖章踢者身份 + 携速度', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb' });
  a.sent.length = 0;
  b.sent.length = 0;

  // 踢者身份由服务端从 session.playerId 盖章（而非收端查 presence），与喊话 voiceId 盖章同源。
  await a.say({ type: 'ball_kick', worldId: 'w1', ballId: 'ball1', playerId: 'pa', x: 10, y: 20, vx: 6, vy: 0, t: 99 });

  assert.equal(a.ofType('ball_kick').length, 0, '踢者自己不收回自己的广播（本地已预测）');
  const k = b.ofType('ball_kick');
  assert.equal(k.length, 1);
  assert.equal(k[0].ballId, 'ball1');
  assert.equal(k[0].playerId, 'pa', '踢者身份由服务端盖章为 session.playerId');
  assert.equal(k[0].x, 10);
  assert.equal(k[0].vx, 6);
  assert.equal(k[0].t, 99);
});

test('ball_settle：转发给同场景他端(排除自己)，不带 playerId/速度', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb' });
  a.sent.length = 0;
  b.sent.length = 0;

  await a.say({ type: 'ball_settle', worldId: 'w1', ballId: 'ball1', x: 15, y: 25, t: 7 });

  assert.equal(a.ofType('ball_settle').length, 0);
  const s = b.ofType('ball_settle');
  assert.equal(s.length, 1);
  assert.equal(s[0].ballId, 'ball1');
  assert.equal(s[0].x, 15);
  assert.equal(s[0].t, 7);
  assert.equal(s[0].playerId, undefined, 'settle 不转所有权给某人，只交回中立');
  assert.equal(s[0].vx, undefined);
});

test('ball_kick：空 ballId 忽略；跨场景收不到', async () => {
  const { store, conn } = relayHarness();
  seedPlayer(store, 'pa');
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'forest' });
  b.sent.length = 0;

  await a.say({ type: 'ball_kick', worldId: 'w1', ballId: '', x: 1, y: 1, vx: 1, vy: 0 }); // 空 id
  await a.say({ type: 'ball_kick', worldId: 'w1', ballId: 'ball1', x: 1, y: 1, vx: 1, vy: 0 }); // 跨场景

  assert.equal(b.ofType('ball_kick').length, 0, '空 id 被忽略、跨场景不达');
});
