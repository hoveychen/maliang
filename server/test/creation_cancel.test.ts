// 引导式创造的取消路线与 goal 下发：
//   - 会话中小朋友说「算了/不要了」→ guide 判 cancelled → 清会话 + 下发 creation_cancelled（含仙子安抚语 TTS），绝不开造
//   - creation_prompt 带 goal（character/prop）→ 客户端据此立降生蛋还是魔法熔炉
//   - 正常答复不能被误判成取消
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seeded(): Promise<{ store: WorldStore; fairyId: string; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  seedFairyWorld(store);
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  return { store, fairyId: fairy.id, close: () => app.close() };
}

async function ws(store: WorldStore, session: VoiceSession, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  const limiter = new RateLimiter(100, 100);
  await handleWsMessage(sock, JSON.stringify(msg), createMockAdapters(), store, limiter, 'test', session);
  return sock.sent;
}

test('creation_prompt 带 goal：造角色=character，造物=prop（客户端据此选降生蛋/魔法熔炉）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const s1 = newVoiceSession();
    const a = await ws(store, s1, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一个新朋友' });
    const p1 = a.find((m) => m.type === 'creation_prompt');
    assert.ok(p1, '造角色应下发 creation_prompt');
    assert.equal(p1!.goal, 'character');

    const s2 = newVoiceSession();
    const b = await ws(store, s2, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    const p2 = b.find((m) => m.type === 'creation_prompt');
    assert.ok(p2, '造物应下发 creation_prompt');
    assert.equal(p2!.goal, 'prop');
  } finally {
    await close();
  }
});

test('造角色会话中说「算了，不要了」→ 清会话 + creation_cancelled（带安抚语），不追问不开造', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一个新朋友' });
    assert.equal(session.creation?.active, true, '前置：会话已开');
    const before = store.listCharacters('default').length;

    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '算了，不要了' });
    assert.equal(session.creation, null, '取消后会话应清空');
    const cancelled = sent.find((m) => m.type === 'creation_cancelled');
    assert.ok(cancelled, '应下发 creation_cancelled');
    assert.ok(String(cancelled!.replyText ?? '').length > 0, '安抚语不能为空（仙子要念出来）');
    assert.ok(String(cancelled!.voiceId ?? '').length > 0, '要带仙子音色');
    assert.equal(sent.some((m) => m.type === 'creation_prompt'), false, '取消不再追问');
    assert.equal(sent.some((m) => m.type === 'gen_progress'), false, '取消不开造');
    assert.equal(store.listCharacters('default').length, before, '取消不落任何角色');
  } finally {
    await close();
  }
});

test('造物会话中说「不造了」→ 清会话 + creation_cancelled，不开熔炉（无 prop_pending）', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '变一个风车' });
    assert.equal(session.creation?.goal, 'prop');
    const before = store.listWorldItems('default').length;

    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '不造了' });
    assert.equal(session.creation, null, '取消后会话应清空');
    assert.ok(sent.find((m) => m.type === 'creation_cancelled'), '应下发 creation_cancelled');
    assert.equal(sent.some((m) => m.type === 'prop_pending'), false, '取消不开造');
    assert.equal(store.listWorldItems('default').length, before, '取消不落任何物品');
  } finally {
    await close();
  }
});

test('正常答复不被误判成取消：说「红色」照常推进会话', async () => {
  const { store, fairyId, close } = await seeded();
  try {
    const session = newVoiceSession();
    await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '我想要一只小猫' });
    const sent = await ws(store, session, { type: 'voice_transcript', worldId: 'default', characterId: fairyId, transcript: '红色' });
    assert.equal(sent.some((m) => m.type === 'creation_cancelled'), false, '正常答复不该被判取消');
  } finally {
    await close();
  }
});
