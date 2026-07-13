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

test('voice_transcript：端侧转写直送 → character_response（唯一语音入口）', async () => {
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

// 服务端 ASR 已整条退役（2026-07-13）。旧客户端（或重放的老流量）仍可能发来音频会话消息，
// 服务端必须静默忽略：不崩、不回包、不留半开会话——绝不能因为不认识的消息类型抛异常断连。
test('退役协议：voice_input/voice_start/voice_chunk/voice_end/voice_cancel 静默忽略不崩', async () => {
  const { sent, socket, rest } = setup();
  const b64 = Buffer.alloc(640).toString('base64');
  for (const msg of [
    { type: 'voice_input', worldId: 'w1', characterId: 'c1', audio: b64, format: 'audio/wav' },
    { type: 'voice_start', worldId: 'w1', characterId: 'c1' },
    { type: 'voice_chunk', audio: b64 },
    { type: 'voice_end' },
    { type: 'voice_cancel' },
  ]) {
    await handleWsMessage(socket, JSON.stringify(msg), ...rest);
  }
  assert.equal(sent.length, 0, '退役的音频消息应被静默忽略：不产生任何回包');
  // 忽略之后，正常的端侧转写仍能走通（没被前面的老消息弄坏会话状态）
  await handleWsMessage(socket, JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好' }), ...rest);
  assert.ok(sent.some((m) => m.type === 'character_response'), '老消息之后端侧转写应正常工作');
});
