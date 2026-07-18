// M2 P1（docs/m2-story-director-design.md §3/§6）：StoryDirector 幕状态机 + story_progress 持久化。
// 覆盖验收口径：全迁移路径 / abort 回幕首 / 重看不重复发奖 / settled 幂等 / 断线重进停幕首。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { StoryDirector, type StoryStageStarter } from '../src/story_director.ts';
import type { StoryBook } from '../src/story_books.ts';
import { ANON_PLAYER } from '../src/types.ts';

const W = 'w1';
const P = 'kid1';

/** 三幕测试册：幕0 visit 委托、幕1 build、幕2 尾声（无互动，演完直接完结）。 */
function testBook(): StoryBook {
  return {
    id: 'test_pigs',
    title: '测试小猪',
    sceneId: 'village',
    gateCastId: 'pig_big',
    cast: [
      { castId: 'pig_big', name: '猪大哥', personality: '稳重', voiceId: 'v1', visualDescription: '' },
      { castId: 'wolf', name: '大灰狼', personality: '憨萌', voiceId: 'v2', visualDescription: '', noResidence: true },
    ],
    chapters: [
      {
        screenplay: 'test_pigs_1',
        interaction: { kind: 'task', type: 'visit', npcCastId: 'pig_big', locationName: '草房废墟', ask: '去看看吧', thanks: '谢谢你' },
        stampStyle: 'star',
        sticker: 'straw',
      },
      {
        screenplay: 'test_pigs_2',
        interaction: { kind: 'build', blueprintId: 'brick_house', npcCastId: 'pig_big', ask: '帮我盖砖房', thanks: '砖房盖好啦' },
        stampStyle: 'medal',
      },
      { screenplay: 'test_pigs_end' }, // 尾声：无互动
    ],
  };
}

/** 可编程 mock 舞台：按序吐预排结果，记录每次调用（world/chapter）。 */
function mockStage(results: ('done' | 'timeout' | 'killed' | 'error')[]): { starter: StoryStageStarter; calls: { worldId: string; chapter: number }[] } {
  const calls: { worldId: string; chapter: number }[] = [];
  const queue = [...results];
  const starter: StoryStageStarter = async ({ worldId, chapter }) => {
    calls.push({ worldId, chapter });
    const r = queue.shift() ?? 'done';
    if (r === 'done') return { status: 'done' };
    if (r === 'error') return { status: 'error', message: 'boom' };
    return { status: r };
  };
  return { starter, calls };
}

function freshStore(): WorldStore {
  const store = new WorldStore();
  store.createWorld(W);
  return store;
}

function director(store: WorldStore, results: ('done' | 'timeout' | 'killed' | 'error')[] = []) {
  const { starter, calls } = mockStage(results);
  const book = testBook();
  return { d: new StoryDirector(store, starter, { [book.id]: book }), calls, book };
}

// ── 全迁移路径：触发→演出→互动→发奖→推进→…→尾声完结 ─────────────────────

test('全迁移路径：三幕走完整册完结，settledNow 恰好在尾声', async () => {
  const store = freshStore();
  const { d } = director(store);

  // 幕0：演出 done → interacting
  let r = await d.trigger(W, P, 'test_pigs');
  assert.deepEqual(r, { status: 'performed', chapter: 0, outcome: 'interacting', rewatch: false });
  assert.equal(store.getStoryProgress(W, P).books['test_pigs'].state, 'interacting');
  assert.equal(store.getStoryProgress(W, P).books['test_pigs'].activeChapter, 0);

  // 幕0 互动完成 → 发奖、推进到幕1
  let adv = d.completeInteraction(W, P, 'test_pigs');
  assert.deepEqual(adv, { bookId: 'test_pigs', chapter: 0, reward: true, advanced: true, settledNow: false });
  let bp = store.getStoryProgress(W, P).books['test_pigs'];
  assert.equal(bp.state, 'idle');
  assert.equal(bp.chapter, 1);
  assert.deepEqual(bp.rewarded, [0]);
  assert.equal(bp.activeChapter, undefined);

  // 幕1 同样闭环
  r = await d.trigger(W, P, 'test_pigs');
  assert.equal(r.status, 'performed');
  assert.equal((r as { chapter: number }).chapter, 1);
  adv = d.completeInteraction(W, P, 'test_pigs');
  assert.deepEqual(adv, { bookId: 'test_pigs', chapter: 1, reward: true, advanced: true, settledNow: false });

  // 幕2 尾声：无互动，演完直接完结入住
  r = await d.trigger(W, P, 'test_pigs');
  assert.equal(r.status, 'performed');
  assert.equal((r as { outcome: string }).outcome, 'completed');
  assert.deepEqual((r as { advance?: unknown }).advance, { bookId: 'test_pigs', chapter: 2, reward: true, advanced: true, settledNow: true });
  bp = store.getStoryProgress(W, P).books['test_pigs'];
  assert.equal(bp.settled, true);
  assert.equal(bp.chapter, 3);
  assert.equal(bp.state, 'idle');
});

// ── abort 回幕首 ──────────────────────────────────────────────────────────

test('abort/timeout/error 回幕首：进度纹丝不动，重触发从同一幕从头演', async () => {
  const store = freshStore();
  const { d, calls } = director(store, ['timeout', 'killed', 'error', 'done']);

  for (const _ of [0, 1, 2]) {
    const r = await d.trigger(W, P, 'test_pigs');
    assert.equal(r.status, 'performed');
    assert.equal((r as { outcome: string }).outcome, 'aborted');
    // 中断不落任何状态：库里连行都没有（或停在幕首 idle）
    const bp = store.getStoryProgress(W, P).books['test_pigs'];
    assert.equal(bp?.state ?? 'idle', 'idle');
    assert.equal(bp?.chapter ?? 0, 0);
  }
  // 第 4 次才演完：四次都从幕 0 开演
  const r = await d.trigger(W, P, 'test_pigs');
  assert.equal((r as { outcome: string }).outcome, 'interacting');
  assert.deepEqual(calls.map((c) => c.chapter), [0, 0, 0, 0]);
});

test('startStage 抛异常等同中断：回幕首，performing 锁释放', async () => {
  const store = freshStore();
  const book = testBook();
  const d = new StoryDirector(
    store,
    async () => {
      throw new Error('worker 起不来');
    },
    { [book.id]: book },
  );
  const r = await d.trigger(W, P, 'test_pigs');
  assert.equal((r as { outcome: string }).outcome, 'aborted');
  assert.equal(d.isPerforming(W), false);
});

// ── 重看不重复发奖 ────────────────────────────────────────────────────────

test('整册完结后重看：缺省从幕 0 重演，互动完成不再发奖、游标不动', async () => {
  const store = freshStore();
  const { d } = director(store);
  // 走完整册
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs');
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs');
  await d.trigger(W, P, 'test_pigs');

  // 重看：settled 后缺省回幕 0
  const r = await d.trigger(W, P, 'test_pigs');
  assert.equal(r.status, 'performed');
  assert.equal((r as { chapter: number }).chapter, 0);
  assert.equal((r as { rewatch: boolean }).rewatch, true);
  assert.equal((r as { outcome: string }).outcome, 'interacting');

  const adv = d.completeInteraction(W, P, 'test_pigs');
  assert.deepEqual(adv, { bookId: 'test_pigs', chapter: 0, reward: false, advanced: false, settledNow: false });
  const bp = store.getStoryProgress(W, P).books['test_pigs'];
  assert.equal(bp.chapter, 3); // 游标没被重看拉回
  assert.equal(bp.settled, true);
  assert.deepEqual(bp.rewarded, [0, 1, 2]);
});

test('显式重看指定幕：只许已发过奖的幕，没看到的幕拒绝（防跳幕剧透）', async () => {
  const store = freshStore();
  const { d, calls } = director(store);
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs'); // 只完成幕 0

  // 幕 1 还没演过 → 不许当重看点
  assert.deepEqual(await d.trigger(W, P, 'test_pigs', 1), { status: 'refused', reason: 'bad_chapter' });
  // 幕 0 已发过奖 → 可重看
  const r = await d.trigger(W, P, 'test_pigs', 0);
  assert.equal((r as { rewatch: boolean }).rewatch, true);
  assert.deepEqual(calls.map((c) => c.chapter), [0, 0]);
  // 重看幕 0 完成：不发奖，且游标仍指幕 1
  const adv = d.completeInteraction(W, P, 'test_pigs');
  assert.equal(adv?.reward, false);
  assert.equal(store.getStoryProgress(W, P).books['test_pigs'].chapter, 1);
});

// ── settled 幂等 ─────────────────────────────────────────────────────────

test('settled 幂等：重看尾声再收场，settledNow 不再置真', async () => {
  const store = freshStore();
  const { d } = director(store);
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs');
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs');
  const first = await d.trigger(W, P, 'test_pigs');
  assert.equal((first as { advance?: { settledNow: boolean } }).advance?.settledNow, true);

  // 显式重看尾声（幕 2）：completed 但 settledNow=false、不发奖
  const again = await d.trigger(W, P, 'test_pigs', 2);
  assert.equal((again as { outcome: string }).outcome, 'completed');
  assert.deepEqual((again as { advance?: unknown }).advance, { bookId: 'test_pigs', chapter: 2, reward: false, advanced: false, settledNow: false });
});

test('completeInteraction 幂等：非 interacting 态（重复结算/脏调用）返回 null', async () => {
  const store = freshStore();
  const { d } = director(store);
  assert.equal(d.completeInteraction(W, P, 'test_pigs'), null); // 还没开演
  await d.trigger(W, P, 'test_pigs');
  assert.notEqual(d.completeInteraction(W, P, 'test_pigs'), null);
  assert.equal(d.completeInteraction(W, P, 'test_pigs'), null); // 二次结算不发奖
  assert.equal(d.completeInteraction(W, P, 'unknown_book'), null);
});

// ── 并发/互动中守卫 ──────────────────────────────────────────────────────

test('一世界一场：演出在飞时再触发被拒 stage_busy，收场后放行', async () => {
  const store = freshStore();
  const book = testBook();
  let release!: (r: { status: 'done' }) => void;
  const gate = new Promise<{ status: 'done' }>((res) => (release = res));
  const d = new StoryDirector(store, async () => gate, { [book.id]: book });

  const first = d.trigger(W, P, 'test_pigs');
  await Promise.resolve(); // 让 first 跑到 await startStage
  assert.equal(d.isPerforming(W), true);
  assert.deepEqual(await d.trigger(W, 'kid2', 'test_pigs'), { status: 'refused', reason: 'stage_busy' });
  release({ status: 'done' });
  await first;
  assert.equal(d.isPerforming(W), false);
});

test('互动中再搭话：不重演，返回 interacting 提醒', async () => {
  const store = freshStore();
  const { d, calls } = director(store);
  await d.trigger(W, P, 'test_pigs');
  const r = await d.trigger(W, P, 'test_pigs');
  assert.deepEqual(r, { status: 'interacting', chapter: 0 });
  assert.equal(calls.length, 1); // 没有第二次开演
});

test('未知册拒绝', async () => {
  const store = freshStore();
  const { d } = director(store);
  assert.deepEqual(await d.trigger(W, P, 'nope'), { status: 'refused', reason: 'unknown_book' });
});

// ── 持久化：story_progress 表（照 wallets 先例）─────────────────────────

test('进度按 (world, player) 分：两个小朋友互不串档；匿名归一 ANON_PLAYER', async () => {
  const store = freshStore();
  const { d } = director(store);
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs');
  assert.equal(store.getStoryProgress(W, P).books['test_pigs'].chapter, 1);
  assert.deepEqual(store.getStoryProgress(W, 'kid2'), { books: {} }); // 另一个孩子从零开始

  // 匿名键归一：空 playerId 落 ANON_PLAYER，读写同一行
  store.setStoryProgress(W, '', { books: { b: { chapter: 2, state: 'idle', rewarded: [0, 1], settled: false } } });
  assert.equal(store.getStoryProgress(W, ANON_PLAYER).books['b'].chapter, 2);
});

test('断线/崩溃重进停幕首：库里的 performing 瞬态读回归一成 idle', () => {
  const store = freshStore();
  // 模拟崩溃时落了 performing（正常路径不会写）：读回必须是 idle
  store.setStoryProgress(W, P, {
    books: { b: { chapter: 1, state: 'performing' as 'idle', rewarded: [0], settled: false, activeChapter: 1 } },
  });
  const bp = store.getStoryProgress(W, P).books['b'];
  assert.equal(bp.state, 'idle');
  assert.equal(bp.activeChapter, undefined); // 非 interacting 不留 activeChapter
  assert.equal(bp.chapter, 1);
});

test('行损坏/形状非法归一成空进度，不崩', () => {
  const store = freshStore();
  store.setStoryProgress(W, P, { books: { ok: { chapter: -2, state: 'interacting', rewarded: [0, 0, -1, 1.5, 'x'] as unknown as number[], settled: 1 as unknown as boolean }, bad: 42 as unknown as { chapter: number; state: 'idle'; rewarded: number[]; settled: boolean } } });
  const sp = store.getStoryProgress(W, P);
  assert.deepEqual(Object.keys(sp.books), ['ok']);
  assert.deepEqual(sp.books['ok'], { chapter: 0, state: 'interacting', rewarded: [0], settled: false });
  // 世界不存在：写是 no-op，读回空
  store.setStoryProgress('nope', P, { books: {} });
  assert.deepEqual(store.getStoryProgress('nope', P), { books: {} });
});

test('deleteWorld 级联清 story_progress：重建同名世界进度归零', async () => {
  const store = freshStore();
  const { d } = director(store);
  await d.trigger(W, P, 'test_pigs');
  d.completeInteraction(W, P, 'test_pigs');
  assert.equal(store.getStoryProgress(W, P).books['test_pigs'].chapter, 1);
  store.deleteWorld(W);
  store.createWorld(W);
  assert.deepEqual(store.getStoryProgress(W, P), { books: {} });
});
