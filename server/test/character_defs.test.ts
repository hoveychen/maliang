// 世界模板架构 v2 P1a（docs/world-template-instancing-design.md §1/§8）：
// 角色【定义层】character_defs 表 + 读写 + 从 Character 抽取定义（纯函数）。
// P1a 只落定义层地基（全局共享、按 defId、无 world_id、resident 不进 def），尚未接入 getCharacter/saveCharacter。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore, characterDefFromCharacter } from '../src/persistence.ts';
import type { Character, CharacterDef } from '../src/types.ts';

function fresh(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  return s;
}

function sampleDef(over: Partial<CharacterDef> = {}): CharacterDef {
  return {
    defId: 'story_three_pigs_pig_big',
    isFairy: false,
    name: '猪大哥',
    personality: '稳重可靠',
    voiceId: 'v-pig',
    greetingStyle: 'gentle',
    appearance: { visualDescription: '戴草帽的猪', spriteAsset: 'hash123', scale: 1.2 },
    abilities: ['start_story'],
    storyArchetype: { bookId: 'three_pigs', castId: 'pig_big' },
    ...over,
  };
}

test('character_defs：upsert → get 往返一致', () => {
  const s = fresh();
  const def = sampleDef();
  s.upsertCharacterDef(def);
  assert.deepEqual(s.getCharacterDef('story_three_pigs_pig_big'), def);
});

test('character_defs：不存在返回 undefined', () => {
  assert.equal(fresh().getCharacterDef('nope'), undefined);
});

test('character_defs：upsert 覆盖同 defId（改定义全世界引用者自动生效的地基）', () => {
  const s = fresh();
  s.upsertCharacterDef(sampleDef({ name: '猪大哥' }));
  s.upsertCharacterDef(sampleDef({ name: '猪大哥（新造型）', appearance: { visualDescription: '新', spriteAsset: 'hash999', scale: 1.5 } }));
  const got = s.getCharacterDef('story_three_pigs_pig_big')!;
  assert.equal(got.name, '猪大哥（新造型）');
  assert.equal(got.appearance.spriteAsset, 'hash999');
  assert.equal(s.listCharacterDefs().length, 1, '同 defId 覆盖不新增行');
});

test('character_defs：全局共享——无 world_id，不随世界隔离', () => {
  const s = fresh();
  s.createWorld('w2');
  s.upsertCharacterDef(sampleDef());
  // 定义层不吃 worldId：任何世界上下文都读到同一份（引用而非复制的地基）
  assert.ok(s.getCharacterDef('story_three_pigs_pig_big'));
  assert.deepEqual(s.listCharacterDefs().map((d) => d.defId), ['story_three_pigs_pig_big']);
});

test('character_defs：损坏/缺关键字段的定义被拒绝', () => {
  const s = fresh();
  assert.throws(() => s.upsertCharacterDef({ ...sampleDef(), defId: '' }), /invalid character def/);
  assert.throws(() => s.upsertCharacterDef({ ...sampleDef(), name: '' }), /invalid character def/);
});

test('characterDefFromCharacter：只抽定义字段，resident/位置/关系不进 def', () => {
  const c: Character = {
    id: 'story_three_pigs_pig_big',
    worldId: 'w1',
    isFairy: false,
    name: '猪大哥',
    personality: '稳重可靠',
    voiceId: 'v-pig',
    greetingStyle: 'gentle',
    appearance: { visualDescription: '戴草帽的猪', spriteAsset: 'hash123', scale: 1.2 },
    memory: ['记忆1'],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 29, tileY: 49 },
    sceneId: 'village',
    abilities: ['start_story'],
    relationships: { kid1: { chats: 3, gifted: false } as never },
    attachments: [{ slot: 'headTop', itemId: 'hat1' }],
    storyRole: { bookId: 'three_pigs', castId: 'pig_big', resident: true },
  };
  const def = characterDefFromCharacter(c);
  // 定义字段进来了
  assert.equal(def.defId, 'story_three_pigs_pig_big');
  assert.equal(def.name, '猪大哥');
  assert.deepEqual(def.appearance, c.appearance);
  assert.deepEqual(def.storyArchetype, { bookId: 'three_pigs', castId: 'pig_big' });
  // 实例状态没混进 def
  const bag = def as unknown as Record<string, unknown>;
  assert.equal(bag.resident, undefined, 'resident 是实例态,不进 def');
  assert.equal(bag.position, undefined);
  assert.equal(bag.relationships, undefined);
  assert.equal(bag.attachments, undefined);
  assert.equal((def.storyArchetype as unknown as Record<string, unknown>).resident, undefined, 'storyArchetype 不含 resident');
});

test('characterDefFromCharacter：无 storyRole 的普通村民不带 storyArchetype', () => {
  const c: Character = {
    id: 'rabbit1', worldId: 'w1', isFairy: false, name: '舞舞兔', personality: '爱跳',
    voiceId: 'v-r', appearance: { visualDescription: '兔', spriteAsset: 'h', scale: 1 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
  };
  assert.equal(characterDefFromCharacter(c).storyArchetype, undefined);
});
