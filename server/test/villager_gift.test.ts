import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { MAX_FLOWERS, type Character } from '../src/types.ts';

function seedChar(store: WorldStore, id: string, greetingStyle: string, isFairy = false): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy, name: id, personality: '', voiceId: 'v1', greetingStyle,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function setup(): { store: WorldStore } {
  const store = new WorldStore();
  store.createWorld('w1');
  return { store };
}

async function gift(store: WorldStore, villagerId: string, playerId: string): Promise<any[]> {
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  session.playerId = playerId;
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'villager_gift', worldId: 'w1', villagerId }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session,
  );
  return sent;
}

test('外向村民给陌生玩家送花：钱包 +1，回 wallet_update 带 gift.villagerId', async () => {
  const { store } = setup();
  seedChar(store, 'ext', 'warm'); // 外向
  const before = store.getWallet('w1', 'p1').flowers; // 懒发初始花
  const sent = await gift(store, 'ext', 'p1');
  assert.deepEqual(sent.map((m) => m.type), ['wallet_update']);
  assert.equal(sent[0].gift.villagerId, 'ext');
  assert.equal(sent[0].wallet.flowers, before + 1, '钱包多一朵');
  assert.equal(store.getWallet('w1', 'p1').flowers, before + 1, '权威钱包也 +1');
});

test('同一村民不重复送：第二次静默无 wallet_update（防刷）', async () => {
  const { store } = setup();
  seedChar(store, 'ext', 'playful');
  await gift(store, 'ext', 'p1');
  const second = await gift(store, 'ext', 'p1');
  assert.equal(second.length, 0, '已送过 → 不再送，不回包');
});

test('内向村民不送花', async () => {
  const { store } = setup();
  seedChar(store, 'intro', 'shy'); // 内向
  const sent = await gift(store, 'intro', 'p1');
  assert.equal(sent.length, 0, '只有外向村民主动送花');
});

test('仙子不送花', async () => {
  const { store } = setup();
  seedChar(store, 'fairy', 'warm', true);
  const sent = await gift(store, 'fairy', 'p1');
  assert.equal(sent.length, 0);
});

test('钱包已满 9：静默不送，且不标记 gifted（钱包腾出后仍可送）', async () => {
  const { store } = setup();
  seedChar(store, 'ext', 'warm');
  store.setFlowers('w1', 'p1', MAX_FLOWERS);
  const sent = await gift(store, 'ext', 'p1');
  assert.equal(sent.length, 0, '满 9 不送');
  // 花掉一朵腾出格子后，同一村民仍能送（说明满时没白标 gifted）
  store.spendFlower('w1', 'p1', 1);
  const retry = await gift(store, 'ext', 'p1');
  assert.equal(retry.length, 1, '腾出格子后可补送');
  assert.equal(retry[0].type, 'wallet_update');
});

test('不同玩家各自独立收花（gifted 按村民×玩家分）', async () => {
  const { store } = setup();
  seedChar(store, 'ext', 'warm');
  const a = await gift(store, 'ext', 'pA');
  const b = await gift(store, 'ext', 'pB');
  assert.equal(a.length, 1, 'pA 收到');
  assert.equal(b.length, 1, 'pB 也收到（各算各的）');
});

test('村民不存在：静默', async () => {
  const { store } = setup();
  const sent = await gift(store, 'ghost', 'p1');
  assert.equal(sent.length, 0);
});
