import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { GREETING_STYLES } from '../src/greetings.ts';
import type { Character } from '../src/types.ts';
import type { AudioBlob, TTSStreamCallbacks, TTSAdapter } from '../src/adapters/types.ts';

function seedChar(store: WorldStore, id: string, voiceId: string, greetingStyle?: string): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy: false, name: '小兔', personality: '活泼', voiceId, greetingStyle,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

/** 流式 mock TTS：记录被合成的 voiceId，回两分片 + 完整音频。 */
function streamingTts(captured: { text: string; voice: string }[]): TTSAdapter {
  return {
    async synthesize(): Promise<AudioBlob> {
      return { bytes: new Uint8Array([1, 2, 3, 4]), mime: 'audio/L16;rate=24000' };
    },
    async synthesizeStream(text: string, voice: string, cb: TTSStreamCallbacks): Promise<AudioBlob> {
      captured.push({ text, voice });
      cb.onStart('audio/L16;rate=24000');
      cb.onChunk(new Uint8Array([1, 2]));
      cb.onChunk(new Uint8Array([3, 4]));
      return { bytes: new Uint8Array([1, 2, 3, 4]), mime: 'audio/L16;rate=24000' };
    },
  };
}

test('voice_greeting 流式：character_response→tts_chunk×2→tts_end，招呼词来自该角色风格库，用其 voiceId', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceX', 'playful');
  const cap: { text: string; voice: string }[] = [];
  const adapters = { ...createMockAdapters(), tts: streamingTts(cap) };
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_greeting', worldId: 'w1', characterId: 'c1' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['character_response', 'tts_chunk', 'tts_chunk', 'tts_end']);
  assert.equal(sent[0].transcript, '', '主动招呼 transcript 为空');
  assert.equal(sent[0].greeting, true, '标记 greeting=true 让客户端跳过「没听清」提示');
  assert.ok(GREETING_STYLES.playful.includes(sent[0].replyText), '招呼词应出自 playful 风格库');
  assert.equal(cap.length, 1);
  assert.equal(cap[0].voice, 'voiceX', '用该角色自己的 voiceId 合成');
  assert.ok(GREETING_STYLES.playful.includes(cap[0].text));
});

test('voice_greeting 非流式 provider（mock）：单条 character_response 带 ttsAsset，无 tts_chunk', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'v1', 'gentle');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_greeting', worldId: 'w1', characterId: 'c1' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['character_response']);
  assert.ok(GREETING_STYLES.gentle.includes(sent[0].replyText));
  assert.ok(sent[0].ttsAsset);
  assert.equal(sent[0].ttsStreaming, undefined);
});

test('voice_greeting 角色不存在：静默跳过，不打断进对话（无 voice_failed / 无回包）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_greeting', worldId: 'w1', characterId: 'nope' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.equal(sent.length, 0, '招呼失败应静默：不发 voice_failed，不打断玩家开口');
});

test('villager_hail（主动打招呼 P3）：回 villager_hail_tts 带招呼词+村民音色，clientTts 路径不占服务端合成', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceX', 'warm');
  const cap: { text: string; voice: string }[] = [];
  const adapters = { ...createMockAdapters(), tts: streamingTts(cap) };
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'villager_hail', worldId: 'w1', villagerId: 'c1' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['villager_hail_tts'], '只回一条招呼文本，不走 character_response/tts_chunk');
  assert.equal(sent[0].villagerId, 'c1');
  assert.equal(sent[0].voiceId, 'voiceX', '用村民自己的音色');
  assert.ok(GREETING_STYLES.warm.includes(sent[0].text), '招呼词出自 warm 风格库');
  assert.equal(cap.length, 0, 'clientTts 路径：服务端不合成（客户端 3D 定位音自合成）');
});

test('villager_hail 村民不存在：静默跳过，无回包', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'villager_hail', worldId: 'w1', villagerId: 'ghost' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.equal(sent.length, 0, '找不到村民就静默，不发任何东西');
});

test('villager_hail 不开对话会话/不算对话轮（session.visit 保持为空）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'v1', 'shy');
  const session = newVoiceSession();
  const socket = { send: (_s: string) => {} };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'villager_hail', worldId: 'w1', villagerId: 'c1' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session,
  );
  assert.equal(session.visit, null, '主动招呼不该开 Visit / 记对话轮');
});

test('不同风格角色出不同库：warm 与 shy 各自命中自己的招呼词库', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'warmChar', 'v1', 'warm');
  seedChar(store, 'shyChar', 'v2', 'shy');
  for (const [id, style] of [['warmChar', 'warm'], ['shyChar', 'shy']] as const) {
    const sent: any[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    await handleWsMessage(
      socket,
      JSON.stringify({ type: 'voice_greeting', worldId: 'w1', characterId: id }),
      createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
    );
    assert.ok(GREETING_STYLES[style].includes(sent[0].replyText), `${id} 应出 ${style} 库`);
  }
});
