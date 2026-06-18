import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { handleVoice } from '../src/voice.ts';
import type { Character } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string): Character {
  const c: Character = {
    id,
    worldId,
    isFairy: false,
    name: '小兔',
    personality: '活泼开朗',
    voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 },
    abilities: ['move_to', 'deliver_message'],
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

test('routeIntent mock：闲聊 vs 去某地指令', async () => {
  const { llm } = createMockAdapters();
  const ctx = { characterName: '小兔', personality: '活泼', abilities: ['move_to'] };
  const chat = await llm.routeIntent('你今天开心吗', ctx);
  assert.equal(chat.kind, 'chat');
  const cmd = await llm.routeIntent('去河边玩', ctx);
  assert.equal(cmd.kind, 'command');
  assert.ok(cmd.behaviorScript, '指令应带行为脚本');
});

test('handleVoice 闭环(mock)：转写→意图→TTS→更新对话历史', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', audio: { bytes: new Uint8Array([1, 2, 3]), mime: 'audio/wav' } },
    createMockAdapters(),
    store,
  );
  assert.ok(r.transcript.length > 0);
  assert.ok(r.replyText.length > 0);
  assert.ok(r.ttsAsset.length > 0);
  assert.ok(store.getAsset(r.ttsAsset), 'TTS 音频应落地为资源');
  assert.ok(r.emotion.length > 0);
  assert.equal(store.getCharacter('w1', 'c1')!.chatHistory.length, 2); // child + npc
});

test('handleVoice 不再对回复做文字审核（去掉以改善体验/降一次 LLM 调用）', async () => {
  // 即使审核器一律拦截，语音回复也应原样返回（不再被改写成兜底句）。
  const base = createMockAdapters();
  const adapters = {
    ...base,
    moderation: {
      async moderateText() {
        return { allowed: false, reason: 'always block' };
      },
    },
  };
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', audio: { bytes: new Uint8Array([1]), mime: 'audio/wav' } },
    adapters,
    store,
  );
  assert.notEqual(r.replyText, '我们聊点别的好不好？', '回复不应被文字审核改写');
});

test('handleVoice 指令：去某地 → 带 behaviorScript 且即时生效', async () => {
  const base = createMockAdapters();
  const adapters = {
    ...base,
    asr: {
      async transcribe() {
        return '去河边';
      },
    },
  };
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', audio: { bytes: new Uint8Array([1]), mime: 'audio/wav' } },
    adapters,
    store,
  );
  assert.ok(r.behaviorScript, '去某地应带行为脚本');
  assert.equal(store.getCharacter('w1', 'c1')!.behaviorScript.commands[0]?.type, 'move_to');
});
