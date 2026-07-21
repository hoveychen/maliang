import { test } from 'node:test';
import assert from 'node:assert/strict';
import { VOICE_CATALOG, FAIRY_VOICE, isKnownVoice, fallbackVoice, voicePromptLines, backfillVoices } from '../src/voice_catalog.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import type { Character } from '../src/types.ts';

test('目录完整性：id 唯一、全 zh 前缀、仙子音色在目录且在主力池', () => {
  const ids = VOICE_CATALOG.map((v) => v.id);
  assert.equal(new Set(ids).size, ids.length, 'id 必须唯一');
  // 主力池（会被 fallbackVoice 稳定哈希 / LLM 随机分配）必须全中文——普通角色绝不会被分到外语音色。
  // 非主力池可含专用外语音色（如《绿野仙踪》桃乐丝 en-US-AnaNeural），只让说英文的远方角色显式点用。
  assert.ok(VOICE_CATALOG.filter((v) => v.main).every((v) => v.id.startsWith('zh-')), '主力池全部是中文系音色');
  assert.ok(VOICE_CATALOG.filter((v) => !v.id.startsWith('zh-')).every((v) => !v.main), '非中文音色不得进主力池（不参与随机分配）');
  assert.ok(isKnownVoice(FAIRY_VOICE));
  assert.ok(VOICE_CATALOG.find((v) => v.id === FAIRY_VOICE)?.main, '仙子音色应在主力池');
  assert.ok(VOICE_CATALOG.filter((v) => v.main).length >= 3, '主力池至少 3 个保证多样性');
  for (const v of VOICE_CATALOG) {
    assert.ok(v.desc.length >= 6, `${v.id} 缺气质描述`);
    assert.ok(v.tags.length >= 1, `${v.id} 缺适用标签`);
  }
});

test('fallbackVoice：稳定（同 id 同声）且只落主力池', () => {
  const pool = new Set(VOICE_CATALOG.filter((v) => v.main).map((v) => v.id));
  const seen = new Set<string>();
  for (const id of ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
    const v = fallbackVoice(id);
    assert.equal(v, fallbackVoice(id), '同 id 必须同声');
    assert.ok(pool.has(v), '只能落主力池');
    seen.add(v);
  }
  assert.ok(seen.size >= 2, '不同 id 应散布到多个音色');
});

test('voicePromptLines：每个音色一行，含 id 与描述', () => {
  const lines = voicePromptLines().split('\n');
  assert.equal(lines.length, VOICE_CATALOG.length);
  for (const v of VOICE_CATALOG) {
    assert.ok(lines.some((l) => l.includes(v.id) && l.includes(v.desc)), `${v.id} 应在 prompt 里`);
  }
});

test('mock designCharacter：voiceId 落目录内（确定性）', async () => {
  const { llm } = createMockAdapters();
  const s1 = await llm.designCharacter('我想要一只小猫', true);
  const s2 = await llm.designCharacter('我想要一只小猫', true);
  assert.ok(isKnownVoice(s1.voiceId), `mock 产出的 voiceId 应在目录内：${s1.voiceId}`);
  assert.equal(s1.voiceId, s2.voiceId, '同输入同声');
});

function seedChar(store: WorldStore, id: string, voiceId: string, isFairy = false): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy, name: '测试', personality: 'x', voiceId,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

test('backfillVoices：legacy 改写、目录内保留、仙子固定、幂等', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'legacy1', 'cn-child-default');
  seedChar(store, 'legacy2', 'mock-voice-cn-child');
  seedChar(store, 'kokoro1', 'zf_001');
  seedChar(store, 'keep1', 'zh-CN-YunjianNeural');
  seedChar(store, 'fairy1', 'mock-voice-cn-fairy', true);

  const n = backfillVoices(store);
  assert.equal(n, 4, '4 个 legacy 被改写（keep1 不动）');
  const byId = (id: string) => store.getCharacter('w1', id)!;
  assert.ok(isKnownVoice(byId('legacy1').voiceId));
  assert.equal(byId('legacy1').voiceId, fallbackVoice('legacy1'), '按 characterId 稳定哈希');
  assert.ok(isKnownVoice(byId('kokoro1').voiceId));
  assert.equal(byId('keep1').voiceId, 'zh-CN-YunjianNeural', '目录内的不动');
  assert.equal(byId('fairy1').voiceId, FAIRY_VOICE, '仙子固定');
  assert.equal(backfillVoices(store), 0, '幂等：第二遍零改写');
});
