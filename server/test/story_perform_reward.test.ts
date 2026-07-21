// P2（docs/s1-snow-white-design.md §5）：互动演出章发奖 emitPerformReward——
// 无 interaction 的幕演赢（completed+reward）时发盖章+贴纸，区别于 task/build 互动幕的 settleStoryInteraction。
// 尾声（无 performReward）经此只走 settledNow 入住、绝不发盖章；重看（reward=false）不发奖。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { emitPerformReward } from '../src/server.ts';
import type { StoryBook } from '../src/story_books.ts';
import type { StoryAdvanceOutcome } from '../src/story_director.ts';

const W = 'w1';
const P = 'kid1';

// mock 册：幕 0 是互动演出数数游戏（带 performReward + stampStyle + 现成 souvenir 贴纸 story_brick），幕 1 尾声。
function mockBook(): StoryBook {
  return {
    id: 'snowtest',
    title: '测试册',
    sceneId: 'village_forest',
    gateCastId: 'hero',
    cast: [
      {
        castId: 'hero',
        name: '英雄',
        personality: 'p',
        voiceId: 'zh-CN-XiaoyiNeural',
        visualDescription: 'x',
        position: { tileX: 1, tileY: 1 },
        greetingStyle: 'warm',
      },
    ],
    chapters: [
      { screenplay: 'sp_count', stampStyle: 'medal', sticker: 'story_brick', performReward: { npcCastId: 'hero', thanks: '谢谢你数得真棒！' } },
      { screenplay: 'sp_end' },
    ],
  };
}

function harness() {
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const last = (type: string) => sent.filter((m) => m['type'] === type).pop();
  return { sent, socket, last };
}

const adv = (o: Partial<StoryAdvanceOutcome>): StoryAdvanceOutcome => ({
  bookId: 'snowtest',
  chapter: 0,
  reward: true,
  advanced: true,
  settledNow: false,
  ...o,
});

test('emitPerformReward：演出章 reward 到期 → 发盖章+贴纸 task_complete，钱包+背包更新', async () => {
  const adapters = createMockAdapters();
  const store = new WorldStore();
  store.createWorld(W);
  const h = harness();
  const before = store.getWallet(W, P).stampsTotal;
  await emitPerformReward(h.socket, W, P, mockBook(), { chapter: 0, advance: adv({}) }, adapters, store, undefined, true, 'village_forest', undefined);
  const done = h.last('task_complete')!;
  assert.ok(done, '发了 task_complete');
  assert.equal(done['stampStyle'], 'medal');
  assert.equal(done['sticker'], 'story_brick');
  assert.equal((done['task'] as { storyBookId?: string; storyChapter?: number }).storyBookId, 'snowtest');
  assert.equal((done['task'] as { storyChapter?: number }).storyChapter, 0);
  assert.equal(store.getWallet(W, P).stampsTotal, before + 1, '盖了 1 章');
  assert.equal(store.getBag(W, P)['story_brick'], 1, '纪念贴纸进背包');
});

test('emitPerformReward：reward=false（重看）→ 不发 task_complete、不盖章', async () => {
  const adapters = createMockAdapters();
  const store = new WorldStore();
  store.createWorld(W);
  const h = harness();
  const before = store.getWallet(W, P).stampsTotal;
  await emitPerformReward(h.socket, W, P, mockBook(), { chapter: 0, advance: adv({ reward: false, advanced: false }) }, adapters, store, undefined, true, 'village_forest', undefined);
  assert.equal(h.last('task_complete'), undefined, '重看不发盖章');
  assert.equal(store.getWallet(W, P).stampsTotal, before, '不盖章');
});

test('emitPerformReward：无 performReward 的幕（尾声）即便 reward 到期也不发盖章', async () => {
  const adapters = createMockAdapters();
  const store = new WorldStore();
  store.createWorld(W);
  const h = harness();
  const before = store.getWallet(W, P).stampsTotal;
  // 尾声幕 chapter 1（无 performReward），reward+settledNow 都真：只可能入住，绝不发盖章
  await emitPerformReward(h.socket, W, P, mockBook(), { chapter: 1, advance: adv({ chapter: 1, settledNow: true }) }, adapters, store, undefined, true, 'village_forest', undefined);
  assert.equal(h.last('task_complete'), undefined, '尾声不发盖章');
  assert.equal(store.getWallet(W, P).stampsTotal, before, '尾声不盖章');
});
