// npc_wishes 下发：客户端拿到「每个村民该漏哪几句话」，自己按距离衰减地播（见 npc_wish_voice.gd）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { handleWsMessage, newVoiceSession, createPropAsync } from '../src/server.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { WISHES, IDLE_DOING, WISH_ABILITIES, wishFor } from '../src/wishes.ts';
import { ANON_PLAYER, type Character } from '../src/types.ts';

interface WishPush { characterId: string; voiceId: string; lines: string[] }

function seedChar(store: WorldStore, id: string, name: string, isFairy = false): void {
  const c: Character = {
    id, worldId: 'w1', isFairy, name, personality: 'p', voiceId: 'v-' + id,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
}

function seedWorld(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'npc1', '小兔');
  seedChar(store, 'npc2', '小蓝');
  seedChar(store, 'fairy', '小神仙', true);
  return store;
}

function harness(store: WorldStore) {
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession()] as const;
  const wishesOf = (): WishPush[] | undefined => {
    const msgs = sent.filter((m) => m['type'] === 'npc_wishes');
    return msgs.length ? (msgs[msgs.length - 1]!['wishes'] as WishPush[]) : undefined;
  };
  return { sent, socket, rest, wishesOf };
}

test('进世界即下发漏话候选：每个村民带自己的音色 + 一组心愿漏话', async () => {
  const store = seedWorld();
  const { socket, rest, wishesOf } = harness(store);

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);

  const wishes = wishesOf();
  assert.ok(wishes, '进世界应下发 npc_wishes');
  assert.equal(wishes.length, 2, '两个村民各一份');
  assert.ok(!wishes.some((w) => w.characterId === 'fairy'), '仙子不在列——她的台词是预制 WAV，走 FairyVoice');

  const w1 = wishes.find((w) => w.characterId === 'npc1')!;
  assert.equal(w1.voiceId, 'v-npc1', '漏话要用村民自己的音色');
  const mine = wishFor('npc1', [])!;
  assert.deepEqual(w1.lines, mine.leaks, '下发的是整个 leaks 数组（客户端自己轮换，省往返）');
});

test('发现玩法后重发：那个心愿的话从此没人再念叨', async () => {
  const store = seedWorld();
  const { socket, rest, wishesOf } = harness(store);
  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);

  // 找一个此刻正念叨造物的村民（心愿按 id 稳定认领）
  const before = wishesOf()!;
  const propTalker = before.find((w) => w.lines === WISHES.create_prop!.leaks
    || w.lines.every((l, i) => l === WISHES.create_prop!.leaks[i]));

  await createPropAsync(socket, 'w1', ANON_PLAYER, '一棵小树', createMockAdapters(), store);

  const after = wishesOf()!;
  for (const w of after) {
    assert.notDeepEqual(w.lines, WISHES.create_prop!.leaks,
      `村民 ${w.characterId} 还在念叨已经玩过的造物——「已发现的不再提」失效了`);
  }
  if (propTalker) {
    const now = after.find((w) => w.characterId === propTalker.characterId)!;
    assert.notDeepEqual(now.lines, propTalker.lines, '刚才念叨造物的那个村民应该改口了');
  }
});

test('下发 discovered 持久口径：仙子重启后不该再念叨已经会用的引路', async () => {
  const store = seedWorld();
  store.addDiscovered('w1', ANON_PLAYER, 'guide_to');
  const { sent, socket, rest } = harness(store);

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);

  const push = sent.find((m) => m['type'] === 'npc_wishes')!;
  assert.deepEqual(push['discovered'], ['guide_to'],
    '客户端的 _guide_used 只记「本次进世界」，重启就忘——持久口径必须由服务端下发');
});

test('玩法全发现后回落纯氛围自语——不再勾任何玩法，但世界还有活气', async () => {
  const store = seedWorld();
  for (const a of WISH_ABILITIES) store.addDiscovered('w1', ANON_PLAYER, a);
  const { socket, rest, wishesOf } = harness(store);

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);

  for (const w of wishesOf()!) {
    assert.deepEqual(w.lines, IDLE_DOING, '心愿池空了应回落 IDLE_DOING');
  }
});

test('没小红花时不漏「要花钱」的心愿——免得勾起兴趣却造不起', async () => {
  const store = seedWorld();
  store.spendFlower('w1', ANON_PLAYER, 3); // 花光
  const { socket, rest, wishesOf } = harness(store);

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);

  const costlyLeaks = WISH_ABILITIES
    .filter((a) => WISHES[a]!.costsFlower)
    .flatMap((a) => WISHES[a]!.leaks);
  for (const w of wishesOf()!) {
    for (const line of w.lines) {
      assert.ok(!costlyLeaks.includes(line), `没花了还在漏要花钱的心愿：「${line}」`);
    }
  }
});
