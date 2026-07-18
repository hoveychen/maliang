// 供给合流（M1 P2，docs/m1-wish-supply-design.md §2.2）：pickTaskCandidate 三级优先
// （心愿 → 该村民的链步 → 通用跑腿）+ 链步物化目标现选 + 完成结算推进 nextIndex +
// costsFlower 跳步不卡链 + 话术接线（describeTask/praiseLine）+ voice 懒生成。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import {
  pickTaskCandidate,
  describeTask,
  praiseLine,
  completeTaskOnEvent,
  completeWishOnAbility,
  beginWishTrial,
  completeWishRefine,
} from '../src/tasks.ts';
import { respondToTranscript } from '../src/voice.ts';
import { WISH_ABILITIES } from '../src/wishes.ts';
import { ANON_PLAYER, type ChainStep, type Character, type TaskChain } from '../src/types.ts';

function seedChar(store: WorldStore, id: string, name: string, opts: { isFairy?: boolean; taskChain?: TaskChain } = {}): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy: opts.isFairy ?? false, name, personality: '爱笑爱热闹', voiceId: 'v-' + id,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
    taskChain: opts.taskChain,
  };
  store.addCharacter(c);
  return c;
}

/** 三步测试链：visit → deliver(带自己的话) → wish(要花)。 */
function testChain(): TaskChain {
  const steps: ChainStep[] = [
    { type: 'visit', leak: '我想找个好地方…还没去看过呢。', ask: '帮我去看看好不好？', thanks: '你去看过啦，太好啦！' },
    { type: 'deliver', message: '茶会就要开始啦，请来玩呀', leak: '茶会的消息还没人知道呢…', ask: '帮我把消息带给他吧。', thanks: '消息带到啦！' },
    { type: 'wish', wishAbility: 'create_prop', desire: '一张摆点心的小桌子', leak: '要是有张小桌子就好啦…', ask: '小桌子只有小仙子变得出来呀。', thanks: '小桌子有啦！茶会成啦！' },
  ];
  return { steps, nextIndex: 0 };
}

function freshStore(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  store.setLocations('w1', ['池塘', '大山']);
  return store;
}

/** 玩法全发现：一级心愿池打空，供给落到二级链步/三级跑腿。 */
function discoverAll(store: WorldStore): void {
  for (const a of WISH_ABILITIES) store.addDiscovered('w1', ANON_PLAYER, a);
}

/** 把钱包花光（初始 3 朵）。 */
function goBroke(store: WorldStore): void {
  while (store.getWallet('w1', ANON_PLAYER).flowers > 0) store.spendFlower('w1', ANON_PLAYER);
}

const rand = () => 0; // 确定性：pick 恒取第一个

// ── 三级优先级 ───────────────────────────────────────────────────────────

test('一级压二级：玩法没发现完时，心愿优先于链步', () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔', { taskChain: testChain() });
  seedChar(store, 'npc2', '小蓝');
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(task?.type, 'wish');
  assert.equal(task?.chainIndex, undefined, '一级心愿不该带链标记');
});

test('二级压三级：心愿池空后，链步优先于通用跑腿，目标发起时现选', () => {
  const store = freshStore();
  discoverAll(store);
  seedChar(store, 'npc1', '小兔', { taskChain: testChain() });
  seedChar(store, 'npc2', '小蓝');
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(task?.type, 'visit');
  assert.equal(task?.chainNpcId, 'npc1');
  assert.equal(task?.chainIndex, 0);
  assert.ok(['池塘', '大山'].includes(task!.locationName!), 'visit 链步的地点该从世界现选');
  assert.equal(task?.chainStep?.thanks, '你去看过啦，太好啦！');
});

test('链尽回落三级：nextIndex 越界后出的是不带链标记的通用跑腿', () => {
  const store = freshStore();
  discoverAll(store);
  const chain = testChain();
  chain.nextIndex = chain.steps.length;
  seedChar(store, 'npc1', '小兔', { taskChain: chain });
  seedChar(store, 'npc2', '小蓝');
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.ok(task, '链走完供给不该断——通用跑腿兜底');
  assert.equal(task.chainIndex, undefined);
});

// ── 链步物化 ────────────────────────────────────────────────────────────

test('deliver 链步带自己的话；目标村民从当前场景现选', () => {
  const store = freshStore();
  discoverAll(store);
  const chain = testChain();
  chain.nextIndex = 1; // 直接站在 deliver 步
  seedChar(store, 'npc1', '小兔', { taskChain: chain });
  seedChar(store, 'npc2', '小蓝');
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(task?.type, 'deliver');
  assert.equal(task?.message, '茶会就要开始啦，请来玩呀');
  assert.equal(task?.targetName, '小蓝');
  assert.equal(task?.chainIndex, 1);
});

test('deliver/bring 链步在场景没别人时跳过（不可行），先给下一可行步', () => {
  const store = freshStore();
  discoverAll(store);
  const chain = testChain();
  chain.nextIndex = 1; // deliver 需要别人，但场景里只有它自己
  seedChar(store, 'npc1', '小兔', { taskChain: chain });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(task?.type, 'wish', '不可行的 deliver 该跳过，落到 wish 步');
  assert.equal(task?.chainIndex, 2);
});

// ── costsFlower 门禁 ────────────────────────────────────────────────────

test('买不起就跳步不卡链：没花时 wish(要花)链步跳过，先给下一可行步', () => {
  const store = freshStore();
  discoverAll(store);
  goBroke(store);
  const steps: ChainStep[] = [
    { type: 'wish', wishAbility: 'create_prop', desire: '小桌子', leak: 'l', ask: 'a', thanks: 't' },
    { type: 'visit', leak: 'l2', ask: 'a2', thanks: 't2' },
  ];
  seedChar(store, 'npc1', '小兔', { taskChain: { steps, nextIndex: 0 } });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(task?.type, 'visit');
  assert.equal(task?.chainIndex, 1);
});

test('有花时 wish(要花)链步正常发起；免费 wish(play_game/guide_to)不受钱包限制', () => {
  const store = freshStore();
  discoverAll(store);
  seedChar(store, 'npc1', '小兔', { taskChain: testChain() });
  const c = store.getCharacter('w1', 'npc1')!;
  c.taskChain!.nextIndex = 2;
  store.saveCharacter(c);
  const rich = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(rich?.type, 'wish');
  assert.equal(rich?.wishAbility, 'create_prop');
  assert.equal(rich?.chainIndex, 2);

  // 没花 + 免费 wish 链步：照发
  const store2 = freshStore();
  discoverAll(store2);
  goBroke(store2);
  const freeSteps: ChainStep[] = [
    { type: 'wish', wishAbility: 'play_game', desire: '来一局游戏', leak: 'l', ask: 'a', thanks: 't' },
    { type: 'visit', leak: 'l2', ask: 'a2', thanks: 't2' },
    { type: 'visit', leak: 'l3', ask: 'a3', thanks: 't3' },
  ];
  seedChar(store2, 'npc1', '小兔', { taskChain: { steps: freeSteps, nextIndex: 0 } });
  const free = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store2, rand);
  assert.equal(free?.wishAbility, 'play_game');
});

// ── 完成结算推进 nextIndex ──────────────────────────────────────────────

test('completeTaskOnEvent 完成链步跑腿 → nextIndex 推进到下一步', () => {
  const store = freshStore();
  discoverAll(store);
  seedChar(store, 'npc1', '小兔', { taskChain: testChain() });
  seedChar(store, 'npc2', '小蓝');
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand)!;
  assert.equal(task.chainIndex, 0);
  store.setActiveTask('w1', ANON_PLAYER, task);
  const done = completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'visit_done', locationName: task.locationName }, store);
  assert.ok(done);
  assert.equal(store.getCharacter('w1', 'npc1')?.taskChain?.nextIndex, 1);
});

test('completeWishOnAbility 完成链步心愿 → nextIndex 推进', () => {
  const store = freshStore();
  discoverAll(store);
  const chain = testChain();
  chain.nextIndex = 2;
  seedChar(store, 'npc1', '小兔', { taskChain: chain });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand)!;
  assert.equal(task.wishAbility, 'create_prop');
  store.setActiveTask('w1', ANON_PLAYER, task);
  const done = completeWishOnAbility('w1', ANON_PLAYER, 'create_prop', store);
  assert.ok(done);
  assert.equal(store.getCharacter('w1', 'npc1')?.taskChain?.nextIndex, 3);
});

test('completeWishRefine 调对体型盖章 → 链步心愿同样推进 nextIndex', () => {
  const store = freshStore();
  discoverAll(store);
  const chain = testChain();
  chain.nextIndex = 2;
  seedChar(store, 'npc1', '小兔', { taskChain: chain });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand)!;
  store.setActiveTask('w1', ANON_PLAYER, task);
  const trial = beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-1', 'big', store);
  assert.ok(trial, '链步心愿也该能进试用');
  const refined = completeWishRefine('w1', ANON_PLAYER, 'item-1', 'small', store);
  assert.ok(refined && 'satisfied' in refined && refined.satisfied);
  assert.equal(store.getCharacter('w1', 'npc1')?.taskChain?.nextIndex, 3);
});

test('跳过的步不回头：完成后面的步后，游标越过被跳过的步（链是见面礼，不是清单）', () => {
  const store = freshStore();
  discoverAll(store);
  goBroke(store);
  const steps: ChainStep[] = [
    { type: 'wish', wishAbility: 'create_prop', desire: '小桌子', leak: 'l', ask: 'a', thanks: 't' },
    { type: 'visit', leak: 'l2', ask: 'a2', thanks: 't2' },
  ];
  seedChar(store, 'npc1', '小兔', { taskChain: { steps, nextIndex: 0 } });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand)!;
  assert.equal(task.chainIndex, 1);
  store.setActiveTask('w1', ANON_PLAYER, task);
  completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'visit_done', locationName: task.locationName }, store);
  assert.equal(store.getCharacter('w1', 'npc1')?.taskChain?.nextIndex, 2, '游标该越过被跳过的 wish 步');
  // 链已尽：回落通用跑腿
  seedChar(store, 'npc2', '小蓝');
  const next = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand);
  assert.equal(next?.chainIndex, undefined);
});

// ── 话术接线 ────────────────────────────────────────────────────────────

test('describeTask：链步注入 ask 底稿；wish 链步用 desire 而非通用心愿库 context', () => {
  const store = freshStore();
  discoverAll(store);
  const chain = testChain();
  chain.nextIndex = 2;
  seedChar(store, 'npc1', '小兔', { taskChain: chain });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand)!;
  const desc = describeTask(task);
  assert.ok(desc.includes('一张摆点心的小桌子'), `wish 链步该用 desire：${desc}`);
  assert.ok(desc.includes('小桌子只有小仙子变得出来呀'), `链步该带 ask 底稿：${desc}`);
});

test('praiseLine：链步完成用这一步自己的道谢', () => {
  const store = freshStore();
  discoverAll(store);
  seedChar(store, 'npc1', '小兔', { taskChain: testChain() });
  const task = pickTaskCandidate('w1', 'npc1', ANON_PLAYER, store, rand)!;
  store.setActiveTask('w1', ANON_PLAYER, task);
  const done = completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'visit_done', locationName: task.locationName }, store)!;
  const line = praiseLine(done.task, done, rand);
  assert.ok(line.startsWith('你去看过啦，太好啦！'), `该用链步的 thanks：${line}`);
});

// ── voice 懒生成接线 ────────────────────────────────────────────────────

test('存量角色心愿池空且无链：搭话时懒生成补链（幂等，一次到位）', async () => {
  const store = freshStore();
  discoverAll(store);
  seedChar(store, 'npc1', '小兔'); // 无链的存量角色
  await respondToTranscript('w1', 'npc1', ANON_PLAYER, '你好呀', createMockAdapters(), store);
  const chain = store.getCharacter('w1', 'npc1')?.taskChain;
  assert.ok(chain, '搭话后该长出链');
  assert.ok(chain.steps.length >= 3);
});

test('心愿池未空时不懒生成：一级供给还在，别抢跑', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔');
  await respondToTranscript('w1', 'npc1', ANON_PLAYER, '你好呀', createMockAdapters(), store);
  assert.equal(store.getCharacter('w1', 'npc1')?.taskChain, undefined);
});
