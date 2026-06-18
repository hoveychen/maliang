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

test('handleVoice：把近 N 轮历史 + 长期记忆喂给 routeIntent（角色有上下文）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const c = seedChar(store, 'w1', 'c1');
  c.chatHistory.push({ role: 'child', text: '我叫朵朵', ts: 0 });
  c.chatHistory.push({ role: 'npc', text: '你好朵朵！', ts: 0 });
  c.memory.push('小朋友叫朵朵');
  store.saveCharacter(c);

  const base = createMockAdapters();
  let captured = null;
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(t, ctx) {
        captured = ctx;
        return base.llm.routeIntent(t, ctx);
      },
    },
  };
  await handleVoice(
    { worldId: 'w1', characterId: 'c1', audio: { bytes: new Uint8Array([1]), mime: 'audio/wav' } },
    adapters,
    store,
  );
  assert.ok(captured, 'routeIntent 应被调用');
  assert.deepEqual(captured.memory, ['小朋友叫朵朵'], '长期记忆应进入上下文');
  assert.equal(captured.recentHistory.length, 2, '近 N 轮历史应进入上下文');
  assert.equal(captured.recentHistory[0].text, '我叫朵朵');
});
