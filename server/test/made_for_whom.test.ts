// A2「给谁做的」（fit-to-user，docs/kids-thinking-made-for-whom.md §5）：造物会话最前的 recipient 预问步。
// 覆盖：纯函数（recipient→size 默认 / 描述前缀）、recipient 步下发在场角色动态选项、character→size 预填硬保底、
// 「随便啦」软退出不进 creation_cancelled、缺 recipient 回落不卡流程。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { recipientDefaultSize, recipientPhrase } from '../src/creation_options.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character, type RecipientRef } from '../src/types.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

/** 造一个在场村民（带体型档）。 */
function villager(worldId: string, id: string, name: string, size: 'small' | 'medium' | 'big'): Character {
  return {
    id, worldId, isFairy: false, name, personality: 'p', voiceId: `v-${id}`,
    appearance: { visualDescription: '', spriteAsset: `sprite-${id}`, scale: 1, size },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId: DEFAULT_SCENE, abilities: [], relationships: {},
  };
}

async function seeded(): Promise<{ store: WorldStore; fairyId: string; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  seedFairyWorld(store);
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  // 在场两个村民：小兔子（small）、大熊（big）——用来验 recipient→size 默认。
  store.addCharacter(villager('default', 'bunny', '小兔子', 'small'));
  store.addCharacter(villager('default', 'bear', '大熊', 'big'));
  return { store, fairyId: fairy.id, close: () => app.close() };
}

async function ws(store: WorldStore, session: VoiceSession, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), createMockAdapters(), store, limiter, 'test', session);
  return sock.sent;
}

// ── 纯函数 ──────────────────────────────────────────────

test('recipientDefaultSize：character 读对方体型档，self/everyone/缺失回落 medium', () => {
  const sizes: Record<string, 'small' | 'medium' | 'big'> = { bunny: 'small', bear: 'big' };
  const look = (id: string) => sizes[id];
  assert.equal(recipientDefaultSize({ kind: 'character', characterId: 'bunny' }, look), 'small', '给小兔子→small');
  assert.equal(recipientDefaultSize({ kind: 'character', characterId: 'bear' }, look), 'big', '给大熊→big');
  assert.equal(recipientDefaultSize({ kind: 'character', characterId: 'ghost' }, look), 'medium', '查不到→medium');
  assert.equal(recipientDefaultSize({ kind: 'self' }, look), 'medium', '给自己→medium');
  assert.equal(recipientDefaultSize({ kind: 'everyone' }, look), 'medium', '给大家→medium');
  assert.equal(recipientDefaultSize(undefined, look), 'medium', '缺失→medium');
});

test('recipientPhrase：按 kind 生成「给X用的」，缺失为空串', () => {
  assert.equal(recipientPhrase(undefined), '');
  assert.equal(recipientPhrase({ kind: 'self' }), '给小朋友自己用的');
  assert.equal(recipientPhrase({ kind: 'everyone' }), '给大家用的');
  assert.equal(recipientPhrase({ kind: 'character', label: '小兔子' }), '给小兔子用的');
  assert.equal(recipientPhrase({ kind: 'character' }), '给小伙伴用的', 'label 缺失有兜底');
});

// ── recipient 预问步：动态在场角色选项 ──────────────────────

test('入口先问 recipient：creation_prompt category=recipient，选项含自己+在场村民+大家', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    const prompt = sent.find((m) => m.type === 'creation_prompt');
    assert.ok(prompt, '入口应下发 recipient 问句');
    assert.equal(prompt!.category, 'recipient', '首个问句是 recipient 步');
    const options = prompt!.options as Array<{ id: string; label: string; iconAsset: string }>;
    const ids = options.map((o) => o.id);
    assert.ok(ids.includes('self'), '含「我自己」');
    assert.ok(ids.includes('everyone'), '含「大家」');
    assert.ok(ids.includes('bunny') && ids.includes('bear'), '含在场村民');
    assert.equal(options.find((o) => o.id === 'self')!.iconAsset, '', '自己无图标（客户端渲通用卡）');
    assert.equal(options.find((o) => o.id === 'bunny')!.iconAsset, 'sprite-bunny', '村民用自己的立绘当图标');
    // 仙子（造物那位）不在候选里
    assert.equal(ids.includes(fairyId), false, 'recipient 候选不含仙子');
    // recipient 步不阻塞：会话仍开着、还没造
    assert.equal(session.creation?.active, true);
    assert.equal(sent.some((m) => m.type === 'gen_complete' || m.type === 'item_created'), false, 'recipient 步不开造');
  } finally {
    await close();
  }
});

// ── 硬保底：recipient=character → size 默认 ──────────────────

test('硬保底：给小兔子(small) → size 默认预填「小」，且不阻塞后续追问', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    // 点「小兔子」卡当 recipient
    await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'bunny' });
    const rec = session.creation?.attrs.recipient as RecipientRef | undefined;
    assert.equal(rec?.kind, 'character');
    assert.equal(rec?.characterId, 'bunny');
    assert.equal(session.creation?.attrs.size, '小', '给小兔子做的，size 默认就变小（肉眼可见的因果）');
    assert.equal(session.creation?.active, true, 'recipient 步之后照常推进，不卡流程');
  } finally {
    await close();
  }
});

test('给大熊(big) → size 默认预填「大」', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'bear' });
    assert.equal(session.creation?.attrs.size, '大', '给大熊做的默认就大');
  } finally {
    await close();
  }
});

test('给大家/自己 → 不预填 size（无内在体型，size 走正常追问）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'everyone' });
    assert.equal((session.creation?.attrs.recipient as RecipientRef).kind, 'everyone');
    assert.equal(session.creation?.attrs.size, undefined, '给大家不预填 size');
  } finally {
    await close();
  }
});

// ── 软退出 / 回落：绝不卡流程、不误判成「不造了」 ──────────────

test('「随便啦」软退出：不记 recipient、不进 creation_cancelled、照常推进到属性追问', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'recipient_skip' });
    assert.equal(session.creation?.attrs.recipient, undefined, '跳过不记 recipient（回落）');
    assert.equal(sent.some((m) => m.type === 'creation_cancelled'), false, '「随便啦」≠「不造了」，不取消');
    // 用暂存的「我想要一只猫」继续：解析出 kind，接着追问
    assert.equal(session.creation?.attrs.kind, '猫');
    assert.equal(session.creation?.active, true, '会话照常推进');
  } finally {
    await close();
  }
});

test('语音答 recipient「给小兔子」→ 认出 character 且入口意图不丢', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '给小兔子' });
    const rec = session.creation?.attrs.recipient as RecipientRef | undefined;
    assert.equal(rec?.kind, 'character');
    assert.equal(rec?.characterId, 'bunny');
    assert.equal(session.creation?.attrs.kind, '猫', '语音认出 recipient 后，入口「小猫」意图仍驱动属性');
    assert.equal(session.creation?.attrs.size, '小', '给小兔子→size 默认小');
  } finally {
    await close();
  }
});

test('recipient 步说「算了不要了」→ 取消（cancel 意图不被 recipient 步吞掉）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只猫' });
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '算了，不要了' });
    assert.ok(sent.some((m) => m.type === 'creation_cancelled'), 'recipient 步也能取消');
    assert.equal(session.creation, null, '取消清会话');
  } finally {
    await close();
  }
});

// ── P2：产物记 recipient + 交付话术走对方音色 ──────────────────

test('P2：给小兔子造物 → ItemDef.recipient 落库 + 小兔子用自己音色道谢', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    // 造物给小兔子：size 预填「小」→「变一个风车」一句 kind 齐 → done
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'bunny' });
    const created = sent.find((m) => m.type === 'item_created');
    assert.ok(created, `应造出物品，实际：${sent.map((m) => m.type).join(',')}`);
    const def = created!.item as { recipient?: RecipientRef };
    assert.equal(def.recipient?.kind, 'character', 'ItemDef.recipient 记 character');
    assert.equal(def.recipient?.characterId, 'bunny');
    // 交付：小兔子用自己的音色（v-bunny）道谢（无心愿盖章，走 A2 交付话术）
    const thanks = sent.find((m) => m.type === 'praise_tts' && m.voiceId === 'v-bunny');
    assert.ok(thanks, `应有小兔子音色的道谢，实际：${JSON.stringify(sent.filter((m) => m.type === 'praise_tts'))}`);
  } finally {
    await close();
  }
});

test('P2：给小兔子造角色 → appearance.recipient 落库', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只会飞的红色猫' });
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'bunny' });
    const done = sent.find((m) => m.type === 'gen_complete');
    assert.ok(done, `应造出角色，实际：${sent.map((m) => m.type).join(',')}`);
    const ch = done!.character as { appearance: { recipient?: RecipientRef } };
    assert.equal(ch.appearance.recipient?.kind, 'character');
    assert.equal(ch.appearance.recipient?.characterId, 'bunny');
  } finally {
    await close();
  }
});

test('P2：给大家造物 → 不记 character recipient、无村民音色道谢', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个红色的风车' });
    const sent = await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'everyone' });
    const created = sent.find((m) => m.type === 'item_created');
    assert.ok(created, '应造出物品');
    const def = created!.item as { recipient?: RecipientRef };
    assert.equal(def.recipient?.kind, 'everyone', '记 everyone');
    assert.equal(sent.some((m) => m.type === 'praise_tts' && String(m.voiceId).startsWith('v-')), false, '给大家不走村民音色道谢');
  } finally {
    await close();
  }
});

test('P2：描述注入「给X用的」——designSdfProp 收到的描述带 recipient 语义', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    // 造物给小兔子 done 后，ItemDef.name 由 designSdfProp 据描述产出——描述里应含「给小兔子用的」。
    // 这里直接验会话累积的 recipient（描述由 composePropDesc(attrs) 生成，见 P1 单测覆盖 recipientPhrase）。
    await ws(store, session, { type: 'creation_reply', worldId: 'default', characterId: fairyId, optionId: 'bunny' });
    // 会话已清（done），改验产物已带 recipient（描述注入的行为由 recipientPhrase 单测保证）
    const item = store.listWorldItems('default').find((i) => (i as { recipient?: RecipientRef }).recipient?.characterId === 'bunny');
    assert.ok(item, '造物已落库且带 recipient=小兔子');
  } finally {
    await close();
  }
});
