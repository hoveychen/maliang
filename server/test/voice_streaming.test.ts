import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import type { Character } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string): Character {
  const c: Character = {
    id, worldId, isFairy: false, name: '小兔', personality: '活泼开朗', voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: ['move_to', 'deliver_message'], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function setup() {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session] as const;
  return { sent, socket, session, rest };
}

const b64 = (n: number) => Buffer.alloc(n).toString('base64');

test('边录边传：voice_start→voice_chunk×N→voice_end 拼成完整音频走 handleVoice', async () => {
  const { sent, socket, session, rest } = setup();
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_start', worldId: 'w1', characterId: 'c1' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_chunk', audio: b64(1280) }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_chunk', audio: b64(1280) }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_end' }), ...rest);

  const resp = sent.find((m) => m.type === 'character_response');
  assert.ok(resp, '应收到 character_response');
  assert.equal(resp.transcript, '你好呀'); // mock ASR 固定转写
  assert.ok(resp.ttsAsset, '应带 TTS 资源');
  assert.equal(session.active, false, 'voice_end 后会话应重置');
});

test('voice_chunk/voice_end 在无活动会话时不崩；voice_end 回 voice_failed', async () => {
  const { sent, socket, rest } = setup();
  // 没有 voice_start 直接发 chunk + end
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_chunk', audio: b64(640) }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_end' }), ...rest);
  assert.ok(sent.some((m) => m.type === 'voice_failed'), 'voice_end 无会话应回 voice_failed');
  assert.ok(!sent.some((m) => m.type === 'character_response'), '不应产出回复');
});

test('voice_cancel：误触取消——不产出任何回包，gate 释放，随后新会话正常', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const limiter = new RateLimiter(100, 100);
  const rest = [createMockAdapters(), store, limiter, 'conn1', session] as const;
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_start', worldId: 'w1', characterId: 'c1' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_chunk', audio: b64(640) }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_cancel' }), ...rest);
  assert.equal(sent.length, 0, '取消不应产生任何回包（无 character_response/voice_failed/error）');
  assert.equal(session.active, false, '取消后会话应重置');
  assert.equal(limiter.activeCount, 0, '取消应释放 gate');
  // 取消后立刻再来一轮完整会话，应正常回复
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_start', worldId: 'w1', characterId: 'c1' }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_chunk', audio: b64(1280) }), ...rest);
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_end' }), ...rest);
  assert.ok(sent.some((m) => m.type === 'character_response'), '取消后的新会话应正常产出回复');
});

test('voice_cancel：无活动会话时静默忽略不崩', async () => {
  const { sent, socket, rest } = setup();
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_cancel' }), ...rest);
  assert.equal(sent.length, 0, '无会话时取消应静默忽略');
});

test('voice_transcript：端侧转写直送 → character_response（跳过服务端 ASR）', async () => {
  const { sent, socket, rest } = setup();
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '去公园' }), ...rest);
  const resp = sent.find((m) => m.type === 'character_response');
  assert.ok(resp, '应收到 character_response');
  assert.equal(resp.transcript, '去公园'); // 原样使用端侧转写，不再过 ASR
  assert.ok(resp.ttsAsset, '应带 TTS 资源');
});

test('voice_transcript：空文本 / 角色不存在 → voice_failed', async () => {
  const { sent, socket, rest } = setup();
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '  ' }), ...rest);
  assert.ok(sent.some((m) => m.type === 'voice_failed'), '空转写应回 voice_failed');
  sent.length = 0;
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: '不存在', transcript: '你好' }), ...rest);
  assert.ok(sent.some((m) => m.type === 'voice_failed'), '角色不存在应回 voice_failed');
  assert.ok(!sent.some((m) => m.type === 'character_response'));
});
