import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { pickTaskCandidate, describeTask, praiseLine, completeWishOnAbility } from '../src/tasks.ts';
import { WISH_ABILITIES, WISHES, wishFor } from '../src/wishes.ts';
import type { Character } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string, name: string, isFairy = false): Character {
  const c: Character = {
    id,
    worldId,
    isFairy,
    name,
    personality: '活泼开朗',
    voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 },
    abilities: [],
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function freshStore(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'npc1', '小兔');
  seedChar(store, 'w1', 'npc2', '小蓝');
  return store;
}

// ── 心愿优先于跑腿委托 ──────────────────────────────────────────────────

test('还没发现玩法时，村民出的是心愿委托——不是驴唇不对马嘴的跑腿活', () => {
  const store = freshStore();
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store);
  assert.ok(task);
  assert.equal(task.type, 'wish');
  assert.equal(task.wishAbility, wishFor('npc1', [])?.ability);
  assert.ok(task.stampStyle.length > 0, '心愿完成同样盖章，走的是同一套小红花经济');
});

test('玩法全被发现后，回落到常规跑腿委托（新手期 → 常规循环）', () => {
  const store = freshStore();
  for (const a of WISH_ABILITIES) store.addDiscovered('w1', 'p1', a);
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store);
  assert.ok(task);
  assert.notEqual(task.type, 'wish', '心愿池已空，不该再出心愿委托');
  assert.ok(['deliver', 'bring', 'visit'].includes(task.type));
});

test('已有进行中委托时不再出候选（幼儿单任务心智）', () => {
  const store = freshStore();
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store)!;
  store.setActiveTask('w1', 'p1', task);
  assert.equal(pickTaskCandidate('w1', 'npc2', 'p1', store), null);
});

test('小仙子不认领心愿——她是兑现心愿的人，不是许愿的人', () => {
  const store = freshStore();
  seedChar(store, 'w1', 'fairy', '小神仙', true);
  assert.equal(pickTaskCandidate('w1', 'fairy', 'p1', store), null);
});

// ── 死锁闸：买不起就不勾 ────────────────────────────────────────────────
// 心愿优先于跑腿委托，而跑腿是赚小红花的路子。若花光了、心愿池又只剩造物类，
// 唯一能接的活是造物但造不起，跑腿又被心愿挡住 → 永久卡死。这两个测试守着那条回落线。

test('没小红花时不出「要花钱」的心愿——让位给跑腿委托去赚花（防死锁）', () => {
  const store = freshStore();
  store.spendFlower('w1', 'p1', 3); // 花光初始 3 朵
  assert.equal(store.getWallet('w1', 'p1').flowers, 0);

  // 免费心愿（引路/玩游戏）也都发现过了 → 心愿池里只剩造物类，但一朵花都没有
  for (const a of WISH_ABILITIES) {
    if (!WISHES[a]!.costsFlower) store.addDiscovered('w1', 'p1', a);
  }
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store);
  assert.ok(task, '没花 + 只剩造物心愿 → 必须回落跑腿委托，否则小朋友永远赚不回花');
  assert.notEqual(task.type, 'wish', `不该派一个造不起的心愿（拿到 ${task.wishAbility}）`);
});

test('没小红花时免费心愿照常出（引路/玩游戏不花钱）', () => {
  const store = freshStore();
  store.spendFlower('w1', 'p1', 3);
  // 只把造物类标记为已发现 → 池里只剩免费心愿
  for (const a of WISH_ABILITIES) {
    if (WISHES[a]!.costsFlower) store.addDiscovered('w1', 'p1', a);
  }
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store);
  assert.ok(task);
  assert.equal(task.type, 'wish');
  assert.equal(WISHES[task.wishAbility!]!.costsFlower, false);
});

// ── prompt 描述：兑现人是小仙子 ────────────────────────────────────────

test('心愿的 prompt 描述点明「村民自己变不出来，只有小仙子能帮」', () => {
  const store = freshStore();
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store)!;
  const desc = describeTask(task);
  assert.ok(desc.includes('小兔'), '要点名是谁的念想');
  assert.ok(desc.includes('小仙子'), '不点明兑现人是小仙子，小朋友说「帮帮他」时仙子不知道该干嘛');
});

// ── 兑现闭环 ────────────────────────────────────────────────────────────

test('对上心愿的玩法 → 盖章 + 清委托', () => {
  const store = freshStore();
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store)!;
  store.setActiveTask('w1', 'p1', task);
  const before = store.getWallet('w1', 'p1').stampsTotal;

  const done = completeWishOnAbility('w1', 'p1', task.wishAbility!, store);
  assert.ok(done, '心愿对应的玩法成功了，却没判定完成');
  assert.equal(done.task.npcName, '小兔');
  assert.equal(store.getWallet('w1', 'p1').stampsTotal, before + 1);
  assert.equal(store.getActiveTask('w1', 'p1'), null, '完成后委托应清掉');
});

test('玩法对不上心愿 → 不算完成，委托原样留着（不能拿别的东西糊弄）', () => {
  const store = freshStore();
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store)!;
  store.setActiveTask('w1', 'p1', task);
  const other = WISH_ABILITIES.find((a) => a !== task.wishAbility)!;

  assert.equal(completeWishOnAbility('w1', 'p1', other, store), null);
  assert.ok(store.getActiveTask('w1', 'p1'), '不匹配时委托不该被清掉');
  assert.equal(store.getWallet('w1', 'p1').stampsTotal, 0, '不匹配不该盖章');
});

test('跑腿委托进行中时，造个东西不会误判成心愿达成', () => {
  const store = freshStore();
  for (const a of WISH_ABILITIES) store.addDiscovered('w1', 'p1', a);
  const errand = pickTaskCandidate('w1', 'npc1', 'p1', store)!;
  store.setActiveTask('w1', 'p1', errand);
  assert.equal(completeWishOnAbility('w1', 'p1', 'create_prop', store), null);
  assert.ok(store.getActiveTask('w1', 'p1'), '跑腿委托不该被造物事件清掉');
});

test('心愿达成的表扬语用的是该心愿的道谢词（村民自己的口吻，不是通用套话）', () => {
  const store = freshStore();
  const task = pickTaskCandidate('w1', 'npc1', 'p1', store)!;
  store.setActiveTask('w1', 'p1', task);
  const done = completeWishOnAbility('w1', 'p1', task.wishAbility!, store)!;
  const line = praiseLine(done.task, done, () => 0);
  const wish = WISHES[task.wishAbility!]!;
  assert.ok(line.startsWith(wish.thanks[0]!), `表扬语该以心愿道谢词开头，实际是「${line}」`);
});
