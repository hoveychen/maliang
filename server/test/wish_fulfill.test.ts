// 心愿兑现闭环的端到端：村民盼着一样东西 → 小仙子真造出来 → 村民认出来、道谢、盖章。
// 这是「我自己发现了新玩法」满足感的最后一环——少了它，漏话就只是句怪话。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { createPropAsync, createStickerAsync, createCharacterAsync } from '../src/server.ts';
import { pickTaskCandidate } from '../src/tasks.ts';
import { WISHES, pickThanks } from '../src/wishes.ts';
import { ANON_PLAYER, type ActiveTask, type Character } from '../src/types.ts';

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
  seedChar(store, 'fairy', '小神仙', true);
  return store;
}

/** 手工给玩家安一个指定 ability 的心愿委托（绕过 hash 认领，测哪个玩法就安哪个）。 */
function setWish(store: WorldStore, ability: string): ActiveTask {
  const task: ActiveTask = {
    id: 't1', type: 'wish', npcId: 'npc1', npcName: '小兔', stampStyle: 'smile', wishAbility: ability,
  };
  store.setActiveTask('w1', ANON_PLAYER, task);
  return task;
}

function collect(): { sent: Record<string, unknown>[]; socket: { send: (s: string) => void } } {
  const sent: Record<string, unknown>[] = [];
  return { sent, socket: { send: (s: string) => sent.push(JSON.parse(s)) } };
}

test('造物兑现心愿：盖章 + 委托清掉 + 村民用自己的音色道谢', async () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  const { sent, socket } = collect();

  await createPropAsync(socket, 'w1', ANON_PLAYER, '一棵会开花的树', createMockAdapters(), store);

  const done = sent.find((m) => m['type'] === 'task_complete');
  assert.ok(done, '心愿达成应推 task_complete（复用现成的盖章庆祝演出）');
  assert.equal((done['task'] as ActiveTask).npcName, '小兔');
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 1, '应盖 1 章');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null, '心愿达成后委托应清掉');

  const praise = sent.find((m) => m['type'] === 'praise_tts');
  assert.ok(praise, '应有道谢语音——没人认出来他帮了忙，满足感就断了');
  assert.equal(praise['voiceId'], 'v-npc1', '道谢必须用【许愿的那个村民】自己的音色');
  const thanks = WISHES.create_prop!.thanks;
  assert.ok(
    thanks.some((t) => String(praise['text']).startsWith(t)),
    `道谢词该出自该心愿的 thanks，实际是「${String(praise['text'])}」`,
  );
});

test('造物同时把玩法记进 discovered——此后全世界不再漏这个心愿', async () => {
  const store = seedWorld();
  const { socket } = collect();
  assert.deepEqual(store.getDiscovered('w1', ANON_PLAYER), []);

  await createPropAsync(socket, 'w1', ANON_PLAYER, '一棵小树', createMockAdapters(), store);

  assert.deepEqual(store.getDiscovered('w1', ANON_PLAYER), ['create_prop']);
  // 心愿池少了 create_prop → 这个村民改口念别的（不会再有人念叨造物）
  const next = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store);
  assert.notEqual(next?.wishAbility, 'create_prop', '已发现的玩法不该再被认领');
});

test('没人许愿时造物只算发现，不盖章（不平白送章）', async () => {
  const store = seedWorld();
  const { sent, socket } = collect();

  await createPropAsync(socket, 'w1', ANON_PLAYER, '一棵小树', createMockAdapters(), store);

  assert.ok(!sent.some((m) => m['type'] === 'task_complete'), '没有进行中心愿，不该盖章');
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 0);
  assert.deepEqual(store.getDiscovered('w1', ANON_PLAYER), ['create_prop'], '但发现照记');
});

test('造错东西不算兑现：村民盼着伙伴，你造了个物件 → 心愿原样留着', async () => {
  const store = seedWorld();
  setWish(store, 'create_character'); // 盼的是活伙伴
  const { sent, socket } = collect();

  await createPropAsync(socket, 'w1', ANON_PLAYER, '一棵小树', createMockAdapters(), store); // 造的是物件

  assert.ok(!sent.some((m) => m['type'] === 'task_complete'), '玩法对不上，不该判定心愿达成');
  assert.ok(store.getActiveTask('w1', ANON_PLAYER), '心愿没实现就是没实现，委托要留着');
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 0);
});

test('造贴纸兑现贴纸心愿', async () => {
  const store = seedWorld();
  setWish(store, 'create_sticker');
  const { sent, socket } = collect();

  await createStickerAsync(socket, 'w1', ANON_PLAYER, '一个红色的太阳', createMockAdapters(), store);

  assert.ok(sent.some((m) => m['type'] === 'task_complete'), '贴纸心愿应被造贴纸兑现');
  assert.deepEqual(store.getDiscovered('w1', ANON_PLAYER), ['create_sticker']);
});

test('造角色兑现伙伴心愿', async () => {
  const store = seedWorld();
  setWish(store, 'create_character');
  const { sent, socket } = collect();

  await createCharacterAsync(socket, 'w1', ANON_PLAYER, '一只毛茸茸的小猫', createMockAdapters(), store);

  assert.ok(sent.some((m) => m['type'] === 'task_complete'), '伙伴心愿应被造角色兑现');
  assert.deepEqual(store.getDiscovered('w1', ANON_PLAYER), ['create_character']);
});

test('造失败（审核挡）不算发现、不兑现——没造出来就是没造出来', async () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  const { sent, socket } = collect();
  const blocked = { ...createMockAdapters(), moderation: { async moderateText() { return { allowed: false, reason: 'x' }; } } };

  await createPropAsync(socket, 'w1', ANON_PLAYER, '坏东西', blocked as unknown as ReturnType<typeof createMockAdapters>, store);

  assert.ok(sent.some((m) => m['type'] === 'prop_failed'));
  assert.deepEqual(store.getDiscovered('w1', ANON_PLAYER), [], '没造出来不该算发现');
  assert.ok(store.getActiveTask('w1', ANON_PLAYER), '没造出来不该兑现心愿');
});

test('道谢词取自许愿村民的心愿库（不是通用套话）', () => {
  const wish = WISHES.create_character!;
  assert.equal(pickThanks(wish, () => 0), wish.thanks[0]);
  assert.ok(!wish.thanks[0]!.includes('盖章'), '道谢是它的真情实感，不是发奖公告');
});
