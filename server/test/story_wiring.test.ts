// M2 P2（docs/m2-story-director-design.md §4.1/§4.2）：storyRole 供给面早返回 +
// gate 搭话 start_story 意图分支 + startStoryAsync 直供开演 + 选角层 buildStoryStageOpts。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { handleWsMessage, newVoiceSession, projectCharacterFor, settleStoryInteraction, startStoryAsync } from '../src/server.ts';
import { respondToTranscript } from '../src/voice.ts';
import { pickTaskCandidate } from '../src/tasks.ts';
import { STORY_BOOKS, storyCharacterId, type StoryBook } from '../src/story_books.ts';
import { StoryDirector } from '../src/story_director.ts';
import { StageDirector } from '../src/stage_session.ts';
import { buildStoryStageOpts, DebutError } from '../src/stage_debut.ts';
import { WorldHub } from '../src/world_hub.ts';
import { ANON_PLAYER, type ActiveTask, type Character } from '../src/types.ts';

const W = 'w1';

function seedChar(
  store: WorldStore,
  id: string,
  name: string,
  opts: { isFairy?: boolean; storyRole?: Character['storyRole'] } = {},
): Character {
  const c: Character = {
    id, worldId: W, isFairy: opts.isFairy ?? false, name, personality: '爱笑', voiceId: 'v-' + id,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
    storyRole: opts.storyRole,
  };
  store.addCharacter(c);
  return c;
}

/** 注册一个临时测试册（three_act_play 是仓里真实存在的剧本，选角层能读到源码）。 */
function withBook(fn: (book: StoryBook) => Promise<void> | void): Promise<void> | void {
  const book: StoryBook = {
    id: 'wiring_pigs',
    title: '接线小猪',
    sceneId: 'village',
    gateCastId: 'pig_big',
    cast: [
      { castId: 'pig_big', name: '猪大哥', personality: '稳重', voiceId: 'v-pig', visualDescription: '', position: { tileX: 1, tileY: 1 }, greetingStyle: 'gentle' },
      { castId: 'wolf', name: '大灰狼', personality: '憨萌', voiceId: 'v-wolf', visualDescription: '', position: { tileX: 2, tileY: 2 }, greetingStyle: 'playful', noResidence: true },
    ],
    chapters: [{ screenplay: 'three_act_play', stampStyle: 'star' }],
  };
  STORY_BOOKS[book.id] = book;
  const done = () => { delete STORY_BOOKS[book.id]; };
  try {
    const r = fn(book);
    if (r instanceof Promise) return r.finally(done);
    done();
  } catch (e) {
    done();
    throw e;
  }
}

function freshStore(): WorldStore {
  const store = new WorldStore();
  store.createWorld(W);
  store.setLocations(W, ['池塘']);
  return store;
}

// ── 供给面早返回：未入住的故事角色不派活/不漏话/不迎客 ─────────────────────

test('pickTaskCandidate：未入住故事角色不派活，入住(resident)后放行', () => {
  const store = freshStore();
  seedChar(store, 'pig1', '猪小弟', { storyRole: { bookId: 'b', castId: 'pig_small', resident: false } });
  seedChar(store, 'npc1', '小兔'); // 有别的村民，deliver/bring 可行
  assert.equal(pickTaskCandidate(W, 'pig1', ANON_PLAYER, store, () => 0), null);

  const pig = store.getCharacter(W, 'pig1')!;
  pig.storyRole = { ...pig.storyRole!, resident: true };
  store.saveCharacter(pig);
  assert.notEqual(pickTaskCandidate(W, 'pig1', ANON_PLAYER, store, () => 0), null);
});

test('npc_wishes 下发：未入住故事角色不在漏话名单里，入住后出现', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔');
  seedChar(store, 'wolf1', '大灰狼', { storyRole: { bookId: 'b', castId: 'wolf', resident: false } });
  seedChar(store, 'pig1', '猪小弟', { storyRole: { bookId: 'b', castId: 'pig_small', resident: true } });
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'world_info', worldId: W, playerId: ANON_PLAYER }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession(),
  );
  const wishes = sent.filter((m) => m['type'] === 'npc_wishes').pop()!['wishes'] as { characterId: string }[];
  const ids = wishes.map((w) => w.characterId);
  assert.ok(ids.includes('npc1'));
  assert.ok(ids.includes('pig1'), '已入住的故事角色进供给面');
  assert.ok(!ids.includes('wolf1'), '未入住的故事角色（狼）绝不漏话');
});

test('projectCharacterFor：未入住故事角色不附社交字段（客户端 greet_eligible 恒 false）', () => {
  const store = freshStore();
  const wolf = seedChar(store, 'wolf1', '大灰狼', { storyRole: { bookId: 'b', castId: 'wolf', resident: false } });
  const pig = seedChar(store, 'pig1', '猪小弟', { storyRole: { bookId: 'b', castId: 'pig_small', resident: true } });
  const wolfView = projectCharacterFor(wolf, 'kid1') as { socialType?: string; familiarity?: string };
  assert.equal(wolfView.socialType, undefined);
  assert.equal(wolfView.familiarity, undefined);
  const pigView = projectCharacterFor(pig, 'kid1') as { socialType?: string };
  assert.notEqual(pigView.socialType, undefined, '入住后正常参与社交');
});

test('villager_hail：未入住故事角色不回招呼 TTS（纵深防线）', async () => {
  const store = freshStore();
  seedChar(store, 'wolf1', '大灰狼', { storyRole: { bookId: 'b', castId: 'wolf', resident: false } });
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'villager_hail', worldId: W, villagerId: 'wolf1' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession(),
  );
  assert.equal(sent.filter((m) => m['type'] === 'villager_hail_tts').length, 0);
});

// ── gate 搭话意图：start_story 摘成 storyRequest ─────────────────────────

test('gate 角色被说「给我讲故事」：routeIntent 归 start_story，摘成 storyRequest 不漏给客户端', () =>
  withBook(async (book) => {
    const store = freshStore();
    seedChar(store, 'gate1', '猪大哥', { storyRole: { bookId: book.id, castId: 'pig_big', resident: false } });
    const r = await respondToTranscript(W, 'gate1', 'kid1', '给我讲故事吧', createMockAdapters(), store);
    assert.equal(r.storyRequest, book.id);
    assert.ok(!r.behaviorScript?.commands.some((c) => c.type === 'start_story'), 'start_story 不下发客户端');
  }));

test('非 gate 故事角色没有 start_story 能力：同一句话不产生 storyRequest', () =>
  withBook(async (book) => {
    const store = freshStore();
    seedChar(store, 'wolf1', '大灰狼', { storyRole: { bookId: book.id, castId: 'wolf', resident: false } });
    const r = await respondToTranscript(W, 'wolf1', 'kid1', '给我讲故事吧', createMockAdapters(), store);
    assert.equal(r.storyRequest, undefined);
  }));

test('普通村民（无 storyRole）说「讲故事」也不触发', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔');
  const r = await respondToTranscript(W, 'npc1', 'kid1', '给我讲故事吧', createMockAdapters(), store);
  assert.equal(r.storyRequest, undefined);
});

// ── startStoryAsync：应下→开演；busy/互动中只说兜底句 ────────────────────

function collectSocket() {
  const sent: Record<string, unknown>[] = [];
  return { sent, socket: { send: (s: string) => sent.push(JSON.parse(s)) } };
}

test('startStoryAsync：能开就应下 leadIn，演出 done 后进度迁 interacting', () =>
  withBook(async (book) => {
    const store = freshStore();
    // 幕带互动才会停在 interacting（withBook 缺省幕无互动，这里补一个）
    book.chapters[0]!.interaction = { kind: 'task', type: 'visit', npcCastId: 'pig_big', locationName: '草房', ask: 'a', thanks: 't' };
    seedChar(store, 'gate1', '猪大哥', { storyRole: { bookId: book.id, castId: 'pig_big', resident: false } });
    const stages = new StageDirector(new WorldHub());
    const stories = new StoryDirector(store, async () => ({ status: 'done' }));
    const { sent, socket } = collectSocket();
    const session = newVoiceSession();
    session.playerId = 'kid1';
    session.clientTts = true;
    await startStoryAsync(socket, session, W, 'gate1', book.id, '好呀，开演！', createMockAdapters(), store, new WorldHub(), stages, stories);
    assert.deepEqual(sent.map((m) => m['type']), ['praise_tts']);
    assert.equal(sent[0]!['text'], '好呀，开演！');
    assert.equal(sent[0]!['voiceId'], 'v-gate1', '应答句用 gate 角色自己的音色');
    await new Promise((r) => setImmediate(r)); // trigger 不被 await：等 mock 演出收场落状态
    assert.equal(store.getStoryProgress(W, 'kid1').books[book.id]!.state, 'interacting');
  }));

test('startStoryAsync：世界已在演出只说兜底句，不开演', () =>
  withBook(async (book) => {
    const store = freshStore();
    seedChar(store, 'gate1', '猪大哥', { storyRole: { bookId: book.id, castId: 'pig_big', resident: false } });
    const stages = new StageDirector(new WorldHub());
    let triggered = 0;
    const stories = new StoryDirector(store, async () => {
      triggered += 1;
      return { status: 'done' };
    });
    // 用另一场演出占住世界：activeIn 恒真最简单的方式是打桩
    const busyStages = { activeIn: () => true, atCapacity: () => false } as unknown as StageDirector;
    const { sent, socket } = collectSocket();
    const session = newVoiceSession();
    session.clientTts = true;
    await startStoryAsync(socket, session, W, 'gate1', book.id, '好呀！', createMockAdapters(), store, new WorldHub(), busyStages, stories);
    await new Promise((r) => setImmediate(r));
    assert.equal(triggered, 0, '没开演');
    assert.equal(sent.length, 1);
    assert.notEqual(sent[0]!['text'], '好呀！', '说的是兜底句不是应答句');
    void stages;
  }));

test('startStoryAsync：互动幕没做完只提醒，不重演', () =>
  withBook(async (book) => {
    const store = freshStore();
    book.chapters[0]!.interaction = { kind: 'task', type: 'visit', npcCastId: 'pig_big', locationName: '草房', ask: 'a', thanks: 't' };
    seedChar(store, 'gate1', '猪大哥', { storyRole: { bookId: book.id, castId: 'pig_big', resident: false } });
    let triggered = 0;
    const stories = new StoryDirector(store, async () => {
      triggered += 1;
      return { status: 'done' };
    });
    const session = newVoiceSession();
    session.playerId = 'kid1';
    session.clientTts = true;
    const { socket } = collectSocket();
    // 先正常开演一次进 interacting
    await startStoryAsync(socket, session, W, 'gate1', book.id, '', createMockAdapters(), store, new WorldHub(), new StageDirector(new WorldHub()), stories);
    await new Promise((r) => setImmediate(r));
    assert.equal(triggered, 1);
    // 再搭话：只提醒
    const { sent } = collectSocket();
    const sock2 = { send: (s: string) => sent.push(JSON.parse(s)) };
    await startStoryAsync(sock2, session, W, 'gate1', book.id, '好呀！', createMockAdapters(), store, new WorldHub(), new StageDirector(new WorldHub()), stories);
    await new Promise((r) => setImmediate(r));
    assert.equal(triggered, 1, '没重演');
    assert.match(String(sent[0]!['text']), /没做完/);
  }));

// ── 尾声自动接演（M2 尾声 UX 修复：拼完砖房不必再搭话就直接看谢幕+入住）──────

test('settleStoryInteraction：最后一个互动幕完成后自动接演无互动尾声→整册完结入住', () =>
  withBook(async (book) => {
    // 两幕册：幕0 build 互动、幕1 尾声无互动
    book.chapters = [
      { screenplay: 'three_act_play', interaction: { kind: 'build', blueprintId: 'house', npcCastId: 'pig_big', ask: '帮我盖砖房', thanks: '盖好啦' }, stampStyle: 'heart' },
      { screenplay: 'three_act_play' }, // 尾声：无互动
    ];
    const store = freshStore();
    seedChar(store, 'gate1', '猪大哥', { storyRole: { bookId: book.id, castId: 'pig_big', resident: false } });
    const calls: number[] = [];
    const stories = new StoryDirector(store, async ({ chapter }) => { calls.push(chapter); return { status: 'done' }; }, STORY_BOOKS);
    // 进度置为「幕0 build 互动中」——玩家刚把砖房拼好，落成点要来结算
    store.setStoryProgress(W, 'kid1', { books: { [book.id]: { chapter: 0, state: 'interacting', rewarded: [], settled: false, activeChapter: 0 } } });

    const task: ActiveTask = {
      id: 't1', type: 'wish', npcId: 'gate1', npcName: '猪大哥', stampStyle: 'heart',
      storyBookId: book.id, storyChapter: 0, storyThanks: '房子盖好啦！',
    };
    const { sent, socket } = collectSocket();
    const session = newVoiceSession();
    session.playerId = 'kid1';
    session.clientTts = true;
    await settleStoryInteraction(socket, W, 'kid1', task, createMockAdapters(), store, stories, true, 'village', session);
    await new Promise((r) => setImmediate(r)); // 自动接演的 trigger 不被 await：等尾声收场落状态

    assert.ok(sent.some((m) => m['type'] === 'task_complete'), '拼房本身要先结算发盖章');
    assert.deepEqual(calls, [1], '自动接演了尾声幕（幕1），无需玩家再搭话');
    const bp = store.getStoryProgress(W, 'kid1').books[book.id]!;
    assert.equal(bp.settled, true, '尾声演完整册完结（入住）');
    assert.equal(bp.chapter, 2);
  }));

test('settleStoryInteraction：非最后互动幕完成后不自动接演（下一幕仍要玩家玩）', () =>
  withBook(async (book) => {
    // 三幕册：幕0 build、幕1 build（仍互动）、幕2 尾声
    book.chapters = [
      { screenplay: 'three_act_play', interaction: { kind: 'build', blueprintId: 'house', npcCastId: 'pig_big', ask: 'a', thanks: 't' }, stampStyle: 'heart' },
      { screenplay: 'three_act_play', interaction: { kind: 'build', blueprintId: 'house', npcCastId: 'pig_big', ask: 'a', thanks: 't' }, stampStyle: 'medal' },
      { screenplay: 'three_act_play' },
    ];
    const store = freshStore();
    seedChar(store, 'gate1', '猪大哥', { storyRole: { bookId: book.id, castId: 'pig_big', resident: false } });
    const calls: number[] = [];
    const stories = new StoryDirector(store, async ({ chapter }) => { calls.push(chapter); return { status: 'done' }; }, STORY_BOOKS);
    store.setStoryProgress(W, 'kid1', { books: { [book.id]: { chapter: 0, state: 'interacting', rewarded: [], settled: false, activeChapter: 0 } } });
    const task: ActiveTask = { id: 't1', type: 'wish', npcId: 'gate1', npcName: '猪大哥', stampStyle: 'heart', storyBookId: book.id, storyChapter: 0 };
    const { socket } = collectSocket();
    const session = newVoiceSession();
    session.playerId = 'kid1';
    session.clientTts = true;
    await settleStoryInteraction(socket, W, 'kid1', task, createMockAdapters(), store, stories, true, 'village', session);
    await new Promise((r) => setImmediate(r));
    assert.deepEqual(calls, [], '幕1还要玩家自己拼，不能自动跳过');
    assert.equal(store.getStoryProgress(W, 'kid1').books[book.id]!.settled, false);
  }));

// ── 选角层 buildStoryStageOpts ───────────────────────────────────────────

test('buildStoryStageOpts：按册 cast 直取角色组演员表，在线小朋友入列', () =>
  withBook((book) => {
    const store = freshStore();
    seedChar(store, storyCharacterId(book.id, 'pig_big'), '猪大哥');
    seedChar(store, storyCharacterId(book.id, 'wolf'), '大灰狼');
    const hub = new WorldHub();
    hub.join(W, { clientId: 'c1', playerId: 'kid1', sceneId: 'village', send: () => {}, sendText: () => {}, posBin: false, sendBinary: () => {} } as never);
    const opts = buildStoryStageOpts(store, hub, W, 'kid1', book, 0);
    assert.ok(opts.code.length > 0, '剧本源码读出来了');
    assert.deepEqual(
      opts.actors.map((a) => ({ id: a.id, name: a.name, isPlayer: a.isPlayer })),
      [
        { id: storyCharacterId(book.id, 'pig_big'), name: '猪大哥', isPlayer: false },
        { id: storyCharacterId(book.id, 'wolf'), name: '大灰狼', isPlayer: false },
        { id: 'kid1', name: '小朋友', isPlayer: true },
      ],
    );
  }));

test('buildStoryStageOpts：故事角色缺席/剧本不存在抛 DebutError（宁可不演）', () =>
  withBook((book) => {
    const store = freshStore();
    const hub = new WorldHub();
    assert.throws(() => buildStoryStageOpts(store, hub, W, '', book, 0), DebutError);
    seedChar(store, storyCharacterId(book.id, 'pig_big'), '猪大哥');
    seedChar(store, storyCharacterId(book.id, 'wolf'), '大灰狼');
    book.chapters[0]!.screenplay = 'no_such_play';
    assert.throws(() => buildStoryStageOpts(store, hub, W, '', book, 0), DebutError);
  }));
