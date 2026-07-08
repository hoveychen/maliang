import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { FallbackTTSAdapter } from '../src/adapters/minimax.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { respondToTranscript } from '../src/voice.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import type { Character } from '../src/types.ts';
import type { AudioBlob, TTSStreamCallbacks, TTSAdapter } from '../src/adapters/types.ts';

function seedChar(store: WorldStore): Character {
  const c: Character = {
    id: 'c1', worldId: 'w1', isFairy: false, name: '小兔', personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: ['move_to'], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

/** 流式 mock TTS：两个分片 + 完整音频返回。 */
function streamingTts(): TTSAdapter {
  return {
    async synthesize(): Promise<AudioBlob> {
      return { bytes: new Uint8Array([1, 2, 3, 4]), mime: 'audio/L16;rate=24000' };
    },
    async synthesizeStream(_t: string, _v: string, cb: TTSStreamCallbacks): Promise<AudioBlob> {
      cb.onStart('audio/L16;rate=24000');
      cb.onChunk(new Uint8Array([1, 2]));
      cb.onChunk(new Uint8Array([3, 4]));
      return { bytes: new Uint8Array([1, 2, 3, 4]), mime: 'audio/L16;rate=24000' };
    },
  };
}

test('respondToTranscript 流式：response 先行（带 ttsStreaming/ttsMime），分片按序，onEnd 存完整资产', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store);
  const adapters = { ...createMockAdapters(), tts: streamingTts() };
  const events: string[] = [];
  let endHash = '';
  const r = await respondToTranscript('w1', 'c1', '', '你好', adapters, store, {
    onResponse: (resp) => events.push(`response:streaming=${resp.ttsStreaming}:mime=${resp.ttsMime}`),
    onChunk: (pcm) => events.push(`chunk:${pcm.length}`),
    onEnd: (hash) => { endHash = hash; events.push('end'); },
  });
  assert.deepEqual(events, ['response:streaming=true:mime=audio/L16;rate=24000', 'chunk:2', 'chunk:2', 'end']);
  assert.equal(r.ttsStreaming, true);
  assert.equal(r.ttsAsset, '', '流式时 response 不带 ttsAsset');
  const stored = store.getAsset(endHash);
  assert.deepEqual(Array.from(stored!.bytes), [1, 2, 3, 4], 'tts_end 资产是完整音频');
  assert.equal(store.getCharacter('w1', 'c1')!.chatHistory.length, 2, '对话历史只记一轮');
});

test('respondToTranscript 流式：未出声即失败 → 静默回落整段路径（response 未重复发）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store);
  const tts: TTSAdapter = {
    async synthesize(): Promise<AudioBlob> {
      return { bytes: new Uint8Array([9, 9]), mime: 'audio/L16;rate=24000' };
    },
    async synthesizeStream(): Promise<AudioBlob> {
      throw new Error('建连失败');
    },
  };
  const adapters = { ...createMockAdapters(), tts };
  let hookCalls = 0;
  const r = await respondToTranscript('w1', 'c1', '', '你好', adapters, store, {
    onResponse: () => hookCalls++,
    onChunk: () => hookCalls++,
    onEnd: () => hookCalls++,
  });
  assert.equal(hookCalls, 0, '未出声失败不应触发任何流式钩子');
  assert.equal(r.ttsStreaming, undefined);
  assert.ok(r.ttsAsset, '回落整段路径应带 ttsAsset');
});

test('handleWsMessage voice_transcript：流式 TTS 消息顺序 character_response→tts_chunk×2→tts_end', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store);
  const adapters = { ...createMockAdapters(), tts: streamingTts() };
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  const types = sent.map((m) => m.type);
  assert.deepEqual(types, ['character_response', 'tts_chunk', 'tts_chunk', 'tts_end']);
  assert.equal(sent[0].ttsStreaming, true);
  assert.equal(sent[0].ttsMime, 'audio/L16;rate=24000');
  assert.equal(Buffer.from(sent[1].audio, 'base64').length, 2);
  assert.ok(sent[3].ttsAsset);
});

test('handleWsMessage：非流式 provider（mock）保持旧 ttsAsset 路径，无 tts_chunk', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store);
  const adapters = createMockAdapters(); // mock tts 无 synthesizeStream
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好' }),
    adapters, store, new RateLimiter(100, 100), 'conn1', newVoiceSession(),
  );
  assert.deepEqual(sent.map((m) => m.type), ['character_response']);
  assert.ok(sent[0].ttsAsset);
  assert.equal(sent[0].ttsStreaming, undefined);
});

test('FallbackTTSAdapter 流式：主首片前失败→备用整段仍以流式语义交付；主出声后失败→上抛', async () => {
  const ok: AudioBlob = { bytes: new Uint8Array([7, 8]), mime: 'audio/L16;rate=16000' };
  const secondary: TTSAdapter = { synthesize: async () => ok };

  // 主没有 synthesizeStream → 直接备用整段
  const fb1 = new FallbackTTSAdapter({ synthesize: async () => { throw new Error('x'); } }, secondary);
  const ev1: string[] = [];
  const full1 = await fb1.synthesizeStream!('a', 'v', {
    onStart: (m) => ev1.push('start:' + m),
    onChunk: (p) => ev1.push('chunk:' + p.length),
  });
  assert.deepEqual(ev1, ['start:audio/L16;rate=16000', 'chunk:2']);
  assert.deepEqual(Array.from(full1.bytes), [7, 8]);

  // 主流式首片前失败 → 备用整段
  const failingPrimary: TTSAdapter = {
    synthesize: async () => { throw new Error('x'); },
    synthesizeStream: async (_t, _v, cb) => { cb.onStart('audio/L16;rate=24000'); throw new Error('boom'); },
  };
  const fb2 = new FallbackTTSAdapter(failingPrimary, secondary);
  const ev2: string[] = [];
  await fb2.synthesizeStream!('a', 'v', { onStart: (m) => ev2.push('start:' + m), onChunk: (p) => ev2.push('chunk:' + p.length) });
  assert.deepEqual(ev2, ['start:audio/L16;rate=16000', 'chunk:2'], '主 onStart 不应外泄，备用整段交付');

  // 主已出声后失败 → 上抛
  const midFail: TTSAdapter = {
    synthesize: async () => ok,
    synthesizeStream: async (_t, _v, cb) => {
      cb.onStart('audio/L16;rate=24000');
      cb.onChunk(new Uint8Array([1]));
      throw new Error('mid boom');
    },
  };
  const fb3 = new FallbackTTSAdapter(midFail, secondary);
  await assert.rejects(
    () => fb3.synthesizeStream!('a', 'v', { onStart: () => {}, onChunk: () => {} }),
    /mid boom/,
  );
});
