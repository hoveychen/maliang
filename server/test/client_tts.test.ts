import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { seedFairyWorld } from './helpers/world_seed.ts';
import { respondToTranscript, greetCharacter } from '../src/voice.ts';
import type { Character } from '../src/types.ts';
import type { AudioBlob, TTSStreamCallbacks, TTSAdapter, ServiceAdapters } from '../src/adapters/types.ts';

function seedChar(store: WorldStore, id: string, voiceId: string, isFairy = false): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy, name: isFairy ? '小神仙' : '小兔', personality: '活泼', voiceId,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

/** 记录合成调用的 TTS mock：clientTts 路径下不应有任何调用。 */
function spyTts(calls: { text: string; voice: string; stream: boolean }[]): TTSAdapter {
  return {
    async synthesize(text: string, voice: string): Promise<AudioBlob> {
      calls.push({ text, voice, stream: false });
      return { bytes: new Uint8Array([1, 2, 3, 4]), mime: 'audio/L16;rate=24000' };
    },
    async synthesizeStream(text: string, voice: string, cb: TTSStreamCallbacks): Promise<AudioBlob> {
      calls.push({ text, voice, stream: true });
      cb.onStart('audio/L16;rate=24000');
      cb.onChunk(new Uint8Array([1, 2]));
      return { bytes: new Uint8Array([1, 2]), mime: 'audio/L16;rate=24000' };
    },
  };
}

function spiedAdapters(calls: { text: string; voice: string; stream: boolean }[]): ServiceAdapters {
  return { ...createMockAdapters(), tts: spyTts(calls) };
}

function clientTtsSession() {
  const s = newVoiceSession();
  s.clientTts = true;
  return s;
}

test('respondToTranscript clientTts：不合成、voiceId 下发、对话轮照记', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceX');
  const calls: { text: string; voice: string; stream: boolean }[] = [];
  const r = await respondToTranscript('w1', 'c1', 'p1', '你好', spiedAdapters(calls), store, undefined, true);
  assert.equal(calls.length, 0, 'clientTts 不得触发任何服务端合成');
  assert.equal(r.voiceId, 'voiceX');
  assert.equal(r.ttsAsset, '');
  assert.equal(r.ttsStreaming, undefined);
  assert.ok(r.replyText);
  assert.equal(store.getRecentTurns('c1', 'p1', 5).length > 0, true, 'finishTurn 仍要落对话轮');
});

test('greetCharacter clientTts：不合成、voiceId 下发、greeting 标记保留', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceY');
  const calls: { text: string; voice: string; stream: boolean }[] = [];
  const r = await greetCharacter('w1', 'c1', spiedAdapters(calls), store, undefined, Math.random, true);
  assert.equal(calls.length, 0);
  assert.equal(r.voiceId, 'voiceY');
  assert.equal(r.ttsAsset, '');
  assert.equal(r.greeting, true);
});

test('voice_transcript + clientTts 会话：单条 character_response 带 voiceId，无 tts_chunk/tts_end', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceZ');
  const calls: { text: string; voice: string; stream: boolean }[] = [];
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好呀' }),
    spiedAdapters(calls), store, new RateLimiter(100, 100), 'conn1', clientTtsSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['character_response']);
  assert.equal(sent[0].voiceId, 'voiceZ');
  assert.equal(calls.length, 0);
});

test('voice_greeting + clientTts 会话：character_response 带招呼文本与 voiceId，不合成', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceG');
  const calls: { text: string; voice: string; stream: boolean }[] = [];
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_greeting', worldId: 'w1', characterId: 'c1' }),
    spiedAdapters(calls), store, new RateLimiter(100, 100), 'conn1', clientTtsSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['character_response']);
  assert.equal(sent[0].voiceId, 'voiceG');
  assert.ok(sent[0].replyText);
  assert.equal(calls.length, 0);
});

test('老客户端（clientTts=false）不回归：voice_transcript 仍走流式 tts_chunk', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'c1', 'voiceOld');
  const calls: { text: string; voice: string; stream: boolean }[] = [];
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好呀' }),
    spiedAdapters(calls), store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['character_response', 'tts_chunk', 'tts_end']);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].stream, true);
});

test('tts_request：回 tts_start(带mime)+tts_chunk+tts_end，空文本静默忽略', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const calls: { text: string; voice: string; stream: boolean }[] = [];
  const adapters = spiedAdapters(calls);
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = clientTtsSession();
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'tts_request', text: '小兔子你好', voiceId: 'voiceF' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', session,
  );
  assert.deepEqual(sent.map((m) => m.type), ['tts_start', 'tts_chunk', 'tts_end']);
  assert.equal(sent[0].ttsMime, 'audio/L16;rate=24000');
  assert.deepEqual(calls, [{ text: '小兔子你好', voice: 'voiceF', stream: true }]);

  sent.length = 0;
  calls.length = 0;
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'tts_request', text: '   ' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', session,
  );
  assert.equal(sent.length, 0, '空文本不回包不合成');
  assert.equal(calls.length, 0);
});

test('tts_request 合成失败：回 tts_failed，不炸连接', async () => {
  const store = new WorldStore();
  const adapters: ServiceAdapters = {
    ...createMockAdapters(),
    tts: {
      async synthesize(): Promise<AudioBlob> { throw new Error('boom'); },
      async synthesizeStream(): Promise<AudioBlob> { throw new Error('boom'); },
    },
  };
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'tts_request', text: '你好', voiceId: 'v' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', clientTtsSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['tts_failed']);
});

test('造角色引导 + clientTts：creation_prompt 带 voiceId、ttsAsset 空、不合成', async () => {
  const store = new WorldStore();
  const { buildServer } = await import('../src/server.ts');
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    seedFairyWorld(store);
    const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
    const calls: { text: string; voice: string; stream: boolean }[] = [];
    const sent: any[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    await handleWsMessage(
      socket,
      JSON.stringify({ type: 'voice_transcript', worldId: 'default', characterId: fairy.id, transcript: '我想要一只小动物' }),
      spiedAdapters(calls), store, new RateLimiter(100, 100), 'conn1', clientTtsSession(),
    );
    const prompt: any = sent.find((m) => m.type === 'creation_prompt');
    assert.ok(prompt, `应有 creation_prompt（收到：${sent.map((m) => m.type).join(',')}）`);
    assert.equal(prompt.ttsAsset, '');
    assert.equal(prompt.voiceId, fairy.voiceId);
    assert.equal(calls.length, 0, 'clientTts 不得触发仙子问句合成');
  } finally {
    await app.close();
  }
});
