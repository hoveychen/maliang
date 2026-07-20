// M2 P4（docs/m2-story-director-design.md §4.4/§4.5）：storyTask 物化与结算——
// 幕闭环（演出→委托→完成→盖章+纪念贴纸→推进）/ 重看跳奖 / build 免花完成点 / 入住翻 resident+供给面放行。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { createBuildAsync, handleWsMessage, newVoiceSession, startStoryAsync } from '../src/server.ts';
import { materializeStoryTask, pickTaskCandidate } from '../src/tasks.ts';
import { THREE_PIGS, storyCharacterId } from '../src/story_books.ts';
import { seedStoryCharacters, settleStoryResidency } from '../src/story_seed.ts';
import { StoryDirector } from '../src/story_director.ts';
import { StageDirector } from '../src/stage_session.ts';
import { WorldHub } from '../src/world_hub.ts';
import type { ServiceAdapters } from '../src/adapters/types.ts';

const W = 'w1';
const P = 'kid1';
const BOOK = THREE_PIGS.id;

async function seededStore(adapters: ServiceAdapters): Promise<WorldStore> {
  const store = new WorldStore();
  store.createWorld(W);
  store.setLocations(W, ['池塘', '大风车']);
  const r = await seedStoryCharacters(adapters, store, W, THREE_PIGS);
  assert.equal(r.created.length, 4);
  return store;
}

function harness(store: WorldStore, adapters: ServiceAdapters) {
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  session.playerId = P;
  session.clientTts = true;
  const stages = new StageDirector(new WorldHub());
  const stories = new StoryDirector(store, async () => ({ status: 'done' }));
  const msg = (m: Record<string, unknown>) =>
    handleWsMessage(socket, JSON.stringify(m), adapters, store, new RateLimiter(100, 100), 'c1', session, new WorldHub(), stages, stories);
  const last = (type: string) => sent.filter((m) => m['type'] === type).pop();
  const trigger = () => startStoryAsync(socket, session, W, storyCharacterId(BOOK, 'pig_big'), BOOK, '', adapters, store, new WorldHub(), stages, stories);
  return { sent, socket, session, stages, stories, msg, last, trigger };
}

const tick = () => new Promise((r) => setImmediate(r));

// ── 物化 ────────────────────────────────────────────────────────────────

test('materializeStoryTask：visit 现选地点 / deliver 指册内角色本名 / build 记蓝图不勾 wishAbility', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  const visit = materializeStoryTask(W, P, THREE_PIGS, 0, store, () => 0)!;
  assert.equal(visit.type, 'visit');
  assert.equal(visit.locationName, '池塘'); // rand=0 恒取第一个地点
  assert.equal(visit.storyBookId, BOOK);
  assert.equal(visit.storyChapter, 0);
  assert.ok(visit.storyAsk && visit.storyThanks);

  const deliver = materializeStoryTask(W, P, THREE_PIGS, 1, store, () => 0)!;
  assert.equal(deliver.type, 'deliver');
  assert.equal(deliver.targetName, '猪小弟');
  assert.ok(deliver.message);

  const build = materializeStoryTask(W, P, THREE_PIGS, 2, store, () => 0)!;
  assert.equal(build.type, 'wish');
  assert.equal(build.storyBlueprintId, 'house');
  assert.equal(build.wishAbility, undefined, '不勾 wishAbility：任意造物不得误完成剧情 build');

  // 尾声无互动 → null；角色缺席（干净世界）→ null
  assert.equal(materializeStoryTask(W, P, THREE_PIGS, 3, store), null);
  const empty = new WorldStore();
  empty.createWorld(W);
  empty.setLocations(W, ['池塘']);
  assert.equal(materializeStoryTask(W, P, THREE_PIGS, 0, empty), null);
});

// ── 幕闭环：演出→task_offer→完成→盖章+贴纸→推进 ─────────────────────────

test('幕 1 闭环：演出收场递 visit 委托，完成即盖章+发「草垛」贴纸+游标推进', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  const h = harness(store, adapters);

  await h.trigger();
  await tick();
  const offer = h.last('task_offer')!;
  const task = offer['task'] as { type: string; locationName?: string; storyBookId?: string };
  assert.equal(task.type, 'visit');
  assert.equal(task.storyBookId, BOOK);
  assert.ok(store.getActiveTask(W, P), '委托已设为进行中');

  const before = store.getWallet(W, P).stampsTotal;
  await h.msg({ type: 'task_event', worldId: W, kind: 'visit_done', locationName: task.locationName });
  const done = h.last('task_complete')!;
  assert.equal((done['task'] as { storyBookId?: string }).storyBookId, BOOK);
  assert.equal(done['sticker'], 'story_straw');
  assert.equal(done['rewatch'], undefined);
  assert.equal(store.getWallet(W, P).stampsTotal, before + 1, '盖了 1 章');
  assert.equal(store.getBag(W, P)['story_straw'], 1, '纪念贴纸进背包');
  assert.equal(store.getActiveTask(W, P), null);
  const bp = store.getStoryProgress(W, P).books[BOOK]!;
  assert.equal(bp.chapter, 1);
  assert.equal(bp.state, 'idle');
});

test('互动中委托丢了（不想做了）：再搭话重物化补递，不卡死在互动态', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  const h = harness(store, adapters);
  await h.trigger();
  await tick();
  assert.ok(h.last('task_offer'));
  store.setActiveTask(W, P, null); // 模拟 abandonTask
  await h.trigger();
  await tick();
  const offers = h.sent.filter((m) => m['type'] === 'task_offer');
  assert.equal(offers.length, 2, '重触发补递了委托');
  assert.ok(store.getActiveTask(W, P));
});

// ── build 幕：免花 + 落成完成点 ──────────────────────────────────────────

test('幕 3 build：0 花也能拼（免花不扣不退），落成即结算盖章+「砖房」贴纸', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  const h = harness(store, adapters);
  // 快进到幕 2（build）：直接用 director 语义走完前两幕
  for (const _ of [0, 1]) {
    await h.trigger();
    await tick();
    const t = store.getActiveTask(W, P)!;
    if (t.type === 'visit') await h.msg({ type: 'task_event', worldId: W, kind: 'visit_done', locationName: t.locationName });
    else await h.msg({ type: 'task_event', worldId: W, kind: 'deliver_done', targetName: t.targetName });
  }
  assert.equal(store.getStoryProgress(W, P).books[BOOK]!.chapter, 2);
  await h.trigger(); // 幕 2 演出 → build 委托
  await tick();
  const task = store.getActiveTask(W, P)!;
  assert.equal(task.storyBlueprintId, 'house');

  // 花光钱包：剧情拼装不设经济闸
  while (store.getWallet(W, P).flowers > 0) store.spendFlower(W, P);
  const stampsBefore = store.getWallet(W, P).stampsTotal;
  await createBuildAsync(h.socket, W, P, 'house', { wall: 'wall_brick' }, adapters, store, true, '', 'village', h.stories);
  // 免花：没扣钱也没 prop_denied；落成 item_created + story 结算 task_complete
  assert.equal(h.last('prop_denied'), undefined);
  assert.ok(h.last('item_created'));
  const done = h.last('task_complete')!;
  assert.equal(done['sticker'], 'story_brick');
  assert.equal(store.getWallet(W, P).stampsTotal, stampsBefore + 1);
  assert.equal(store.getBag(W, P)['story_brick'], 1);
  // build 是最后一个互动幕：落成结算后尾声自动接演（M2 尾声 UX），整册完结入住——
  // 游标越过尾声幕到末尾、settled 置真，不再停在幕 3 等孩子重新搭话。
  await tick();
  const bp = store.getStoryProgress(W, P).books[BOOK]!;
  assert.equal(bp.chapter, 4);
  assert.equal(bp.settled, true);
});

// ── 尾声入住 + 重看跳奖 ─────────────────────────────────────────────────

test('尾声演完整册完结：小猪＋狼都入住（resident+委托链+供给面放行）；重看不再发奖', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  const h = harness(store, adapters);
  // 走完三幕互动
  for (const _ of [0, 1]) {
    await h.trigger();
    await tick();
    const t = store.getActiveTask(W, P)!;
    if (t.type === 'visit') await h.msg({ type: 'task_event', worldId: W, kind: 'visit_done', locationName: t.locationName });
    else await h.msg({ type: 'task_event', worldId: W, kind: 'deliver_done', targetName: t.targetName });
  }
  await h.trigger();
  await tick();
  // build 是最后一个互动幕：落成后尾声自动接演（M2 尾声 UX），无需再手动搭话触发尾声
  await createBuildAsync(h.socket, W, P, 'house', { wall: 'wall_brick' }, adapters, store, true, '', 'village', h.stories);
  await tick();
  const bp = store.getStoryProgress(W, P).books[BOOK]!;
  assert.equal(bp.settled, true);
  for (const castId of ['pig_big', 'pig_mid', 'pig_small']) {
    const pig = store.getCharacter(W, storyCharacterId(BOOK, castId))!;
    assert.equal(pig.storyRole?.resident, true, `${castId} 入住`);
    assert.ok(pig.taskChain, `${castId} 带上了专属委托链`);
  }
  // 狼改邪归正也入住（收编成可搭话村民）：翻 resident + 带专属委托链
  const wolf = store.getCharacter(W, storyCharacterId(BOOK, 'wolf'))!;
  assert.equal(wolf.storyRole?.resident, true, '狼也入住');
  assert.ok(wolf.taskChain, '狼带上了专属委托链');
  // 供给面放行：入住的小猪能派活了
  assert.notEqual(pickTaskCandidate(W, storyCharacterId(BOOK, 'pig_big'), 'kid2', store, () => 0), null);

  // 重看幕 0：完成互动不再盖章、不再发贴纸
  await h.trigger(); // settled 后缺省从幕 0 重看
  await tick();
  const t = store.getActiveTask(W, P)!;
  const stamps = store.getWallet(W, P).stampsTotal;
  await h.msg({ type: 'task_event', worldId: W, kind: 'visit_done', locationName: t.locationName });
  const done = h.last('task_complete')!;
  assert.equal(done['rewatch'], true);
  assert.equal(done['sticker'], undefined, '重看不再发贴纸');
  assert.equal(store.getWallet(W, P).stampsTotal, stamps, '重看不再盖章');
  assert.equal(store.getBag(W, P)['story_straw'], 1, '贴纸没变两张');
});

test('settleStoryResidency 幂等：二次结算不重复翻转', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  assert.equal(settleStoryResidency(W, THREE_PIGS, store, adapters.llm).length, 4); // 三猪＋狼
  assert.equal(settleStoryResidency(W, THREE_PIGS, store, adapters.llm).length, 0);
});

// ── 纪念贴纸不进小铺 ─────────────────────────────────────────────────────

test('sticker_buy 拒绝 souvenir：纪念贴纸买不到', async () => {
  const adapters = createMockAdapters();
  const store = await seededStore(adapters);
  const h = harness(store, adapters);
  await h.msg({ type: 'sticker_buy', worldId: W, itemId: 'story_straw' });
  assert.equal(h.last('sticker_bought'), undefined);
  assert.equal((h.last('error') ?? {})['error'], 'not a sticker');
  assert.equal(store.getBag(W, P)['story_straw'], undefined);
  // 普通内置贴纸照常能买
  await h.msg({ type: 'sticker_buy', worldId: W, itemId: 'sticker_sun' });
  assert.ok(h.last('sticker_bought'));
});
