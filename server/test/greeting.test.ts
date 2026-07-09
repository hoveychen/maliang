import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { greetCharacter } from '../src/voice.ts';
import { GREETING_STYLES, styleForCharacter, pickGreeting } from '../src/greetings.ts';
import type { Character } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string, greetingStyle?: string): Character {
  const c: Character = {
    id,
    worldId,
    isFairy: false,
    name: '小兔',
    personality: '活泼开朗',
    voiceId: 'v1',
    greetingStyle,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 },
    abilities: [],
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

test('styleForCharacter：显式 greetingStyle 优先，缺省按 id 稳定哈希', () => {
  assert.equal(styleForCharacter({ id: 'x', greetingStyle: 'shy' }), 'shy');
  // 未知风格值忽略，回落哈希
  const fallback = styleForCharacter({ id: 'abc', greetingStyle: 'bogus' });
  assert.ok(fallback in GREETING_STYLES);
  // 同 id 稳定
  assert.equal(styleForCharacter({ id: 'abc' }), styleForCharacter({ id: 'abc' }));
});

test('pickGreeting：注入 rng 确定性，选中的是该角色风格库里的句子', () => {
  const c = { id: 'c1', greetingStyle: 'warm' };
  const first = pickGreeting(c, () => 0); // 取第 0 条
  assert.equal(first, GREETING_STYLES.warm[0]);
  const last = pickGreeting(c, () => 0.999); // 取最后一条
  assert.equal(last, GREETING_STYLES.warm[GREETING_STYLES.warm.length - 1]);
});

test('不同角色（不同 id）分到的风格可不同——覆盖到多种风格', () => {
  const seen = new Set<string>();
  for (const id of ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l']) {
    seen.add(styleForCharacter({ id }));
  }
  assert.ok(seen.size >= 2, `12 个角色应至少落到 2 种风格，实得 ${seen.size}`);
});

test('greetCharacter：出招呼文本 + TTS 资产，不算对话轮（不写 chat_turns）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1', 'gentle');
  const r = await greetCharacter('w1', 'c1', createMockAdapters(), store, undefined, () => 0);
  assert.equal(r.characterId, 'c1');
  assert.equal(r.transcript, '', '主动招呼 transcript 应为空');
  assert.equal(r.replyText, GREETING_STYLES.gentle[0]);
  assert.ok(r.ttsAsset.length > 0, '招呼应合成 TTS 落地资产');
  assert.ok(store.getAsset(r.ttsAsset), 'TTS 音频应落地');
  assert.equal(store.getRecentTurns('c1', '', 10).length, 0, '招呼不写对话历史/记忆');
});
