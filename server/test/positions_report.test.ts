import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WORLD_CENTER_TILE, type Character, type Player } from '../src/types.ts';

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
  assert.deepEqual(store.getPlayer('p1')?.position, { tileX: 5, tileY: 6 });
});

test('positions_report：玩家 tile 落地；越界玩家 tile 丢弃', async () => {
  const { store, send } = harness();
  seedChar(store, 'c1');
  seedPlayer(store, 'p1');

  await send({ type: 'positions_report', worldId: 'w1', playerId: 'p1', chars: [{ id: 'c1', tileX: 1, tileY: 1 }], player: { tileX: 9, tileY: 9 } });
  assert.deepEqual(store.getPlayer('p1')?.position, { tileX: 9, tileY: 9 });

  await send({ type: 'positions_report', worldId: 'w1', playerId: 'p1', chars: [{ id: 'c1', tileX: 2, tileY: 2 }], player: { tileX: 500, tileY: 500 } });
  assert.deepEqual(store.getPlayer('p1')?.position, { tileX: 9, tileY: 9 }, '越界不覆盖旧值');
});

test('positions_report：无 playerId 时不写玩家位置（不误挂到别人头上）', async () => {
  const { store, send } = harness();
  seedChar(store, 'c1');
  seedPlayer(store, 'p1');

  await send({ type: 'positions_report', worldId: 'w1', chars: [{ id: 'c1', tileX: 1, tileY: 1 }], player: { tileX: 9, tileY: 9 } });
  assert.equal(store.getPlayer('p1')?.position, undefined);
});

test('world_state 回带 playerPos：上次离开时的 tile', async () => {
  const { store, sent, send } = harness();
  seedPlayer(store, 'p1');
  store.setPlayerTile('p1', { tileX: 11, tileY: 22 });

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

test('positions_report：角色 id 属于别的世界 → 不跨世界写入', async () => {
  const { store, sent, send } = harness();
  store.createWorld('w2');
  seedChar(store, 'c1'); // 在 w1

  await send({ type: 'positions_report', worldId: 'w2', chars: [{ id: 'c1', tileX: 1, tileY: 1 }] });

  assert.equal(sent[0]?.type, 'error');
  assert.deepEqual(store.getCharacter('w1', 'c1')?.position, WORLD_CENTER_TILE);
});
