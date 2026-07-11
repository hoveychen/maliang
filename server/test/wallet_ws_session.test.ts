import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession, createPropAsync, createCharacterAsync } from '../src/server.ts';
import { INITIAL_FLOWERS, type Player } from '../src/types.ts';

function harness() {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const send = (msg: object, session = newVoiceSession()) =>
    handleWsMessage(socket, JSON.stringify(msg), createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session);
  return { store, sent, send };
}

function player(id: string): Player {
  return { id, name: 'n', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
}

test('world_state 下发的是该 session 玩家自己的钱包', async () => {
  const { store, sent, send } = harness();
  store.upsertPlayer(player('A'));
  store.upsertPlayer(player('B'));
  // A 花掉两朵
  store.spendFlower('w1', 'A', 2);

  const sessA = newVoiceSession();
  await send({ type: 'world_info', worldId: 'w1', playerId: 'A', locations: [] }, sessA);
  const wsA = sent.find((m) => m.type === 'world_state');
  assert.equal(wsA.wallet.flowers, INITIAL_FLOWERS - 2, 'A 看到自己花剩的');

  sent.length = 0;
  const sessB = newVoiceSession();
  await send({ type: 'world_info', worldId: 'w1', playerId: 'B', locations: [] }, sessB);
  const wsB = sent.find((m) => m.type === 'world_state');
  assert.equal(wsB.wallet.flowers, INITIAL_FLOWERS, 'B 看到的是自己满额的钱包');
});

test('造物扣的是该玩家的花，不动别人的', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };

  await createPropAsync(socket, 'w1', 'A', '一棵小树', createMockAdapters(), store);

  assert.equal(store.getWallet('w1', 'A').flowers, INITIAL_FLOWERS - 1, 'A 的花被扣了一朵');
  assert.equal(store.getWallet('w1', 'B').flowers, INITIAL_FLOWERS, 'B 一分未动');
  assert.ok(sent.some((m) => m.type === 'item_created'), '造物成功');
});

test('造角色扣的是该玩家的花', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const socket = { send: () => {} };

  await createCharacterAsync(socket, 'w1', 'A', '一只小猫', createMockAdapters(), store);

  assert.equal(store.getWallet('w1', 'A').flowers, INITIAL_FLOWERS - 1);
  assert.equal(store.getWallet('w1', 'B').flowers, INITIAL_FLOWERS);
});

test('无 playerId 的连接落到匿名钱包，不碰具名玩家', async () => {
  const { store, sent, send } = harness();
  store.upsertPlayer(player('A'));

  await send({ type: 'world_info', worldId: 'w1', locations: [] }); // 不带 playerId
  const ws = sent.find((m) => m.type === 'world_state');
  assert.equal(ws.wallet.flowers, INITIAL_FLOWERS);

  assert.equal(store.getWallet('w1', 'A').flowers, INITIAL_FLOWERS, 'A 的钱包没被匿名连接建/改');
});
