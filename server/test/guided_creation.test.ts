import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { ANON_PLAYER, INITIAL_FLOWERS, newCreationState, type CreationState, type GuideCreationResult } from '../src/types.ts';
import { CREATION_OPTIONS, findOption, optionsByCategory } from '../src/creation_options.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seeded(): Promise<{ store: WorldStore; fairyId: string; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  await app.inject({ method: 'GET', url: '/worlds/default' });
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  return { store, fairyId: fairy.id, close: () => app.close() };
}

/** 驱动一条 WS 消息（每次新 mock 适配器，隔离状态）。 */
async function ws(store: WorldStore, session: VoiceSession, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), createMockAdapters(), store, limiter, 'test', session);
  return sock.sent;
}

// 模拟 P2 状态机做的事：把一轮结果的增量并回 state（供多轮累积测试用）
function apply(state: CreationState, r: GuideCreationResult): void {
  const u = r.updatedAttrs;
  if (u) {
    if (u.kind) state.attrs.kind = u.kind;
    if (u.color) state.attrs.color = u.color;
    if (u.size) state.attrs.size = u.size;
    if (u.personality) state.attrs.personality = u.personality;
    if (u.name) state.attrs.name = u.name;
    if (u.traits) state.attrs.traits = u.traits;
  }
  if (r.category) state.askedCategories.push(r.category);
  state.turnCount += 1;
}

test('图标库：类别齐全、id 唯一、name 无图标不进库', () => {
  const ids = CREATION_OPTIONS.map((o) => o.id);
  assert.equal(new Set(ids).size, ids.length, 'id 必须唯一');
  assert.ok(optionsByCategory('kind').length >= 2);
  assert.ok(optionsByCategory('color').length >= 2);
  assert.equal(CREATION_OPTIONS.some((o) => o.category === 'name'), false, 'name 走语音，不进图标库');
  assert.equal(findOption('cat')?.label, '猫');
});

test('guideCreation：含糊首句 → 追问 kind + 给合法选项 id', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideCreation(newCreationState(), '我想要一个朋友');
  assert.equal(r.done, false);
  assert.equal(r.category, 'kind');
  assert.ok(r.optionIds && r.optionIds.length >= 2 && r.optionIds.length <= 4);
  // 选项必须都是图标库里 kind 类的真实 id
  for (const id of r.optionIds!) assert.equal(findOption(id)?.category, 'kind');
  assert.ok(r.replyText.length > 0);
});

test('guideCreation：多轮累积 → 攒够(kind+color)即 done + 汇出描述', async () => {
  const { llm } = createMockAdapters();
  const state = newCreationState();
  const r1 = await llm.guideCreation(state, '小猫');       // 给 kind
  apply(state, r1);
  assert.equal(state.attrs.kind, '猫');
  assert.equal(r1.done, false);
  const r2 = await llm.guideCreation(state, '红');         // 给 color → 够了
  apply(state, r2);
  assert.equal(state.attrs.color, '红');
  assert.equal(r2.done, true);
  assert.ok(r2.description && r2.description.includes('猫') && r2.description.includes('红'));
});

test('guideCreation：快捷方式——首句说全 → 首轮即 done', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideCreation(newCreationState(), '一只会飞的红色小猫');
  assert.equal(r.done, true);
  assert.ok(r.description!.includes('猫'));
  assert.ok(r.description!.includes('红'));
  assert.ok(r.description!.includes('会飞'));
});

test('guideCreation：语音名字——问过 name 后自由文本当名字', async () => {
  const { llm } = createMockAdapters();
  // 构造一个已攒够但仍在问名字的状态：kind+color 已有，上一轮问的是 name
  const state: CreationState = {
    active: true,
    goal: 'character',
    attrs: { kind: '猫', color: '红', traits: [] },
    askedCategories: ['name'],
    turnCount: 3,
  };
  const r = await llm.guideCreation(state, '咪咪');
  assert.equal(r.updatedAttrs?.name, '咪咪');
});

test('guideCreation：提前造——说「就这样」立即 done', async () => {
  const { llm } = createMockAdapters();
  const state: CreationState = { active: true, goal: 'character', attrs: { kind: '狗', traits: [] }, askedCategories: ['kind'], turnCount: 1 };
  const r = await llm.guideCreation(state, '就这样');
  assert.equal(r.done, true);
});

test('guideCreation：超轮兜底——turnCount 到上限强制 done', async () => {
  const { llm } = createMockAdapters();
  const state: CreationState = { active: true, goal: 'character', attrs: { kind: '兔', traits: [] }, askedCategories: ['kind', 'color', 'trait', 'name', 'personality'], turnCount: 5 };
  const r = await llm.guideCreation(state, '嗯');
  assert.equal(r.done, true);
});

// ── P2 状态机 + WS 协议 ──────────────────────────────────────────────────

test('voice_transcript 入口：对小仙子说含糊造角色 → 开会话 + 下发 creation_prompt(图标选项)', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小动物' });
    assert.equal(session.creation?.active, true);
    const prompt = sent.find((m) => m.type === 'creation_prompt');
    assert.ok(prompt, '应下发 creation_prompt');
    const options = prompt!.options as Array<{ id: string }>;
    assert.ok(options.length >= 2 && options.length <= 4);
    assert.equal(sent.some((m) => m.type === 'character_response'), false, '入口不发普通 character_response');
  } finally {
    await close();
  }
});

const LEAD_IN = '好呀，我这就变出来！'; // mock routeIntent 对造角色意图生成的前置话语

test('缺陷②：入口先说前置话语，并入第一个问句一起念（一次 TTS，不抢播）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小动物' });
    const prompt = sent.find((m) => m.type === 'creation_prompt');
    assert.ok(prompt, '应下发 creation_prompt');
    const reply = String(prompt!.replyText);
    assert.ok(reply.startsWith(LEAD_IN), `问句应以前置话语开头，实际：${reply}`);
    assert.ok(reply.length > LEAD_IN.length, '前置话语之后还要接第一个问句');
    // question 字段仍是纯问句（客户端用它做选项标题），不带前置话语
    assert.equal(String(prompt!.question).startsWith(LEAD_IN), false, 'question 只放问句本身');
    assert.equal(sent.some((m) => m.type === 'character_response'), false, '入口仍不发普通 character_response');
  } finally {
    await close();
  }
});

test('缺陷②：快捷路径（首轮即 done）也要把前置话语念出来，不能吞掉', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只会飞的红色小猫' });
    assert.equal(sent.some((m) => m.type === 'creation_prompt'), false, '快捷路径不追问');
    const spoken = sent.find((m) => m.type === 'praise_tts' && String(m.text) === LEAD_IN);
    assert.ok(spoken, `快捷路径也应念出前置话语，实际消息：${sent.map((m) => m.type).join(',')}`);
  } finally {
    await close();
  }
});

test('多轮：入口给类型 → creation_reply 点颜色 → 攒够 done → gen_complete 入库', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const before = store.listCharacters('default').length;
    // 入口：说「小猫」→ 有 kind，缺颜色 → 追问
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小猫' });
    assert.equal(session.creation?.attrs.kind, '猫');
    assert.equal(session.creation?.active, true);
    // 点颜色卡「红」→ 攒够 → 造
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'red' });
    assert.equal(session.creation, null, '造完清掉会话');
    assert.ok(sent.some((m) => m.type === 'gen_complete'), '应 gen_complete');
    assert.equal(store.listCharacters('default').length, before + 1, '角色入库');
  } finally {
    await close();
  }
});

test('快捷方式：一句说全 → 入口首轮即 done，不发 creation_prompt', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const before = store.listCharacters('default').length;
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只会飞的红色小猫' });
    assert.equal(session.creation, null, '首轮即完成，不留会话');
    assert.equal(sent.some((m) => m.type === 'creation_prompt'), false, '快捷路径不追问');
    assert.ok(sent.some((m) => m.type === 'gen_complete'));
    assert.equal(store.listCharacters('default').length, before + 1);
  } finally {
    await close();
  }
});

test('小红花扣费：引导造角色 done → 恰扣 1 朵花，gen_complete 带最新钱包', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    assert.equal(store.getWallet('default', ANON_PLAYER).flowers, INITIAL_FLOWERS, '新世界初始 3 花');
    // 快捷路径：一句说全 → 首轮即 done → createCharacterAsync 扣 1 朵
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只会飞的红色小猫' });
    const done = sent.find((m) => m.type === 'gen_complete')!;
    assert.ok(done, '应 gen_complete');
    assert.equal(store.getWallet('default', ANON_PLAYER).flowers, INITIAL_FLOWERS - 1, '造角色恰扣 1 朵(不重复扣)');
    assert.equal((done.wallet as { flowers: number }).flowers, INITIAL_FLOWERS - 1, 'gen_complete 带扣费后钱包');
  } finally {
    await close();
  }
});

test('小红花门槛：0 花时造角色被拦 → gen_denied，不开会话不入库', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    store.spendFlower('default', ANON_PLAYER, INITIAL_FLOWERS); // 花光
    const session = newVoiceSession();
    const before = store.listCharacters('default').length;
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小猫' });
    const denied = sent.find((m) => m.type === 'gen_denied');
    assert.ok(denied, '0 花应回 gen_denied');
    assert.equal(denied!.reason, 'no_flowers');
    assert.equal(session.creation, null, '0 花不开引导会话');
    assert.equal(sent.some((m) => m.type === 'gen_complete'), false, '不应造出角色');
    assert.equal(store.listCharacters('default').length, before, '角色数不变');
    assert.equal(store.getWallet('default', ANON_PLAYER).flowers, 0, '拦截不动账');
  } finally {
    await close();
  }
});

test('creation_reply 无进行中会话 → voice_failed', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'cat' });
    assert.equal(sent[0]?.type, 'voice_failed');
  } finally {
    await close();
  }
});

test('creation_cancel / leave_world 清掉会话', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小狗' });
    assert.notEqual(session.creation, null);
    await ws(store, session, { type: 'creation_cancel' });
    assert.equal(session.creation, null);
    // 再开一次，用 leave_world 清
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小兔' });
    assert.notEqual(session.creation, null);
    await ws(store, session, { type: 'leave_world', worldId: 'default' });
    assert.equal(session.creation, null);
  } finally {
    await close();
  }
});

test('会话进行中普通语音不走 routeIntent：说话被当作造角色答复', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小猫' });
    assert.equal(session.creation?.attrs.kind, '猫');
    // 会话中说「蓝」→ 应累积成颜色(造角色答复)，而非走闲聊/指令
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '蓝' });
    // 蓝色→攒够→done gen_complete；且全程不出现 character_response(没走 routeIntent)
    assert.equal(sent.some((m) => m.type === 'character_response'), false);
    assert.ok(sent.some((m) => m.type === 'gen_complete'));
  } finally {
    await close();
  }
});
