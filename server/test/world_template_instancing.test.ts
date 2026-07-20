// 世界模板架构 v2 P1b（docs/world-template-instancing-design.md §1/§5/§8）：
// getCharacter 读实例合并共享定义、saveCharacter 拆写、迁移存量行成 def+实例。
// 核心断言：跨世界共享 def——两世界放同 defId 实例，改 def 一次两世界都变；改实例态互相隔离。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  WorldStore,
  characterInstanceFromCharacter,
  characterFromDefInstance,
  characterDefFromCharacter,
} from '../src/persistence.ts';
import type { Character, CharacterDef, CharacterInstanceRecord } from '../src/types.ts';

function pig(over: Partial<Character> = {}): Character {
  return {
    id: 'story_three_pigs_pig_big',
    worldId: 'w1',
    isFairy: false,
    name: '猪大哥',
    personality: '稳重可靠',
    voiceId: 'v-pig',
    greetingStyle: 'gentle',
    appearance: { visualDescription: '戴草帽的猪', spriteAsset: 'hash123', scale: 1.2 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 29, tileY: 49 },
    sceneId: 'village',
    abilities: ['start_story'],
    relationships: {},
    storyRole: { bookId: 'three_pigs', castId: 'pig_big', resident: false },
    ...over,
  };
}

function villager(over: Partial<Character> = {}): Character {
  return {
    id: 'rabbit1',
    worldId: 'w1',
    isFairy: false,
    name: '舞舞兔',
    personality: '爱跳',
    voiceId: 'v-r',
    appearance: { visualDescription: '兔', spriteAsset: 'h', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 },
    abilities: [],
    relationships: {},
    ...over,
  };
}

function fresh(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  return s;
}

// ── 契约保持：拆写/合并读对上层透明（getCharacter 返回的 Character 不变）──────────────────

test('P1b 契约：saveCharacter→getCharacter 往返完整 Character 不变（故事角色）', () => {
  const s = fresh();
  const c = pig({
    memory: ['见过小明'],
    chatHistory: [{ role: 'user', text: '你好', ts: 1 } as never],
    relationships: { kid1: { chats: 3, wishesDone: 1, gifted: false, lastSeen: 0 } },
    attachments: [{ slot: 'headTop', itemId: 'hat1' }],
    taskChain: { steps: [], cursor: 0 } as never,
    storyRole: { bookId: 'three_pigs', castId: 'pig_big', resident: true },
  });
  s.saveCharacter(c);
  assert.deepEqual(s.getCharacter('w1', c.id), c, '合并回来应与存进去的完整对象逐字段一致');
});

test('P1b 契约：普通村民（无 storyRole）往返不变、不凭空长出 storyRole', () => {
  const s = fresh();
  const c = villager({ relationships: { kid1: { chats: 2, wishesDone: 0, gifted: true, lastSeen: 0 } } });
  s.saveCharacter(c);
  const got = s.getCharacter('w1', c.id)!;
  assert.deepEqual(got, c);
  assert.equal(got.storyRole, undefined);
});

test('P1b 拆写：saveCharacter 落定义进 character_defs（改这里全世界生效的地基）', () => {
  const s = fresh();
  s.saveCharacter(pig());
  const def = s.getCharacterDef('story_three_pigs_pig_big');
  assert.ok(def, '定义层应有这份角色定义');
  assert.equal(def!.name, '猪大哥');
  assert.equal(def!.appearance.spriteAsset, 'hash123');
  // resident 绝不进 def（每世界实例态）
  assert.equal((def as unknown as Record<string, unknown>).resident, undefined);
  assert.equal((def!.storyArchetype as unknown as Record<string, unknown>).resident, undefined);
});

// ── 核心：跨世界共享定义（证明整个模型）────────────────────────────────────────────

test('P1b 核心：两世界放同 defId 实例，改 def 一次→两世界 getCharacter 都变', () => {
  const s = new WorldStore();
  s.createWorld('wA');
  s.createWorld('wB');
  // 一份共享定义
  const def: CharacterDef = {
    defId: 'shared_pig',
    isFairy: false,
    name: '猪大哥',
    personality: '稳重',
    voiceId: 'v-pig',
    greetingStyle: 'gentle',
    appearance: { visualDescription: '草帽猪', spriteAsset: 'sprA', scale: 1.2 },
    abilities: ['start_story'],
    storyArchetype: { bookId: 'three_pigs', castId: 'pig_big' },
  };
  s.upsertCharacterDef(def);
  // 两世界各放一个引用它的实例（实例 id 不同——characters.id 是全局主键；共享的是 defId）
  const instA: CharacterInstanceRecord = {
    id: 'pig_a', worldId: 'wA', defId: 'shared_pig',
    position: { tileX: 5, tileY: 5 }, sceneId: 'village', state: 'idle',
    behaviorScript: { commands: [], loop: false }, memory: [], chatHistory: [],
    relationships: {}, resident: false,
  };
  const instB: CharacterInstanceRecord = { ...instA, id: 'pig_b', worldId: 'wB', position: { tileX: 9, tileY: 9 } };
  s.putCharacterInstance(instA);
  s.putCharacterInstance(instB);

  // 初始：两世界都读到共享定义的身份
  assert.equal(s.getCharacter('wA', 'pig_a')!.name, '猪大哥');
  assert.equal(s.getCharacter('wB', 'pig_b')!.name, '猪大哥');
  assert.equal(s.getCharacter('wA', 'pig_a')!.appearance.spriteAsset, 'sprA');

  // 改一次共享定义 → 两世界当场都变（v2 最大收益：模板更新自动下发）
  s.upsertCharacterDef({ ...def, name: '猪二哥', appearance: { ...def.appearance, spriteAsset: 'sprZ' } });
  assert.equal(s.getCharacter('wA', 'pig_a')!.name, '猪二哥', 'A 世界随共享定义更新');
  assert.equal(s.getCharacter('wB', 'pig_b')!.name, '猪二哥', 'B 世界随同一份定义更新');
  assert.equal(s.getCharacter('wA', 'pig_a')!.appearance.spriteAsset, 'sprZ');
  assert.equal(s.getCharacter('wB', 'pig_b')!.appearance.spriteAsset, 'sprZ');

  // 但各自的实例态相互隔离（位置本就不同，读回也不同）
  assert.deepEqual(s.getCharacter('wA', 'pig_a')!.position, { tileX: 5, tileY: 5 });
  assert.deepEqual(s.getCharacter('wB', 'pig_b')!.position, { tileX: 9, tileY: 9 });
});

test('P1b 核心：改实例态只翻自己那份，另一世界隔离；且不脱离共享 defId', () => {
  const s = new WorldStore();
  s.createWorld('wA');
  s.createWorld('wB');
  s.upsertCharacterDef({
    defId: 'shared_pig', isFairy: false, name: '猪大哥', personality: '稳重', voiceId: 'v-pig',
    appearance: { visualDescription: '草帽猪', spriteAsset: 'sprA', scale: 1 }, abilities: [],
    storyArchetype: { bookId: 'three_pigs', castId: 'pig_big' },
  });
  const base: CharacterInstanceRecord = {
    id: 'pig_a', worldId: 'wA', defId: 'shared_pig', position: { tileX: 5, tileY: 5 },
    sceneId: 'village', state: 'idle', behaviorScript: { commands: [], loop: false },
    memory: [], chatHistory: [], relationships: {}, resident: false,
  };
  s.putCharacterInstance(base);
  s.putCharacterInstance({ ...base, id: 'pig_b', worldId: 'wB' });

  // A 世界的小猪入住 + 移动（走 getCharacter→改→saveCharacter，即实际热路径）
  const a = s.getCharacter('wA', 'pig_a')!;
  a.storyRole = { ...a.storyRole!, resident: true };
  a.position = { tileX: 20, tileY: 20 };
  s.saveCharacter(a);

  // A 变了，B 没被牵连（入住是每世界的）
  assert.equal(s.getCharacter('wA', 'pig_a')!.storyRole!.resident, true);
  assert.equal(s.getCharacter('wB', 'pig_b')!.storyRole!.resident, false, 'B 世界的小猪仍未入住');
  assert.deepEqual(s.getCharacter('wB', 'pig_b')!.position, { tileX: 5, tileY: 5 }, 'B 的位置不受 A 的移动影响');

  // 关键：saveCharacter 后 A 的实例仍指向共享 defId，之后改定义仍能下发到 A（没被改指回自身 id）
  s.upsertCharacterDef({
    defId: 'shared_pig', isFairy: false, name: '换名了', personality: '稳重', voiceId: 'v-pig',
    appearance: { visualDescription: '草帽猪', spriteAsset: 'sprA', scale: 1 }, abilities: [],
    storyArchetype: { bookId: 'three_pigs', castId: 'pig_big' },
  });
  assert.equal(s.getCharacter('wA', 'pig_a')!.name, '换名了', 'saveCharacter 沿用共享 defId，定义更新仍下发');
  assert.equal(s.getCharacter('wB', 'pig_b')!.name, '换名了');
  // A 的每世界状态（入住/位置）不被这次定义更新覆盖
  assert.equal(s.getCharacter('wA', 'pig_a')!.storyRole!.resident, true);
  assert.deepEqual(s.getCharacter('wA', 'pig_a')!.position, { tileX: 20, tileY: 20 });
});

// ── 纯函数：拆/合往返 ───────────────────────────────────────────────────────────

test('P1b 纯函数：characterInstanceFromCharacter 只带实例态 + defId，无 def 字段', () => {
  const inst = characterInstanceFromCharacter(pig({ storyRole: { bookId: 'three_pigs', castId: 'pig_big', resident: true } }));
  const bag = inst as unknown as Record<string, unknown>;
  assert.equal(inst.defId, 'story_three_pigs_pig_big');
  assert.equal(inst.resident, true, 'resident 落实例');
  assert.equal(bag.name, undefined, 'name 是 def 字段，不进实例');
  assert.equal(bag.personality, undefined);
  assert.equal(bag.appearance, undefined);
  assert.equal(bag.abilities, undefined);
  assert.equal(bag.storyRole, undefined, 'storyRole 拆成 def.storyArchetype + inst.resident');
});

test('P1b 纯函数：def+inst 合并还原 = 原 Character', () => {
  const c = pig({ storyRole: { bookId: 'three_pigs', castId: 'pig_big', resident: true } });
  const def = characterDefFromCharacter(c);
  const inst = characterInstanceFromCharacter(c);
  assert.deepEqual(characterFromDefInstance(def, inst), c);
});

// ── 迁移：存量 worlds.json 全量 blob → 拆成 def + 实例（生产升级路径）──────────────────

test('P1b 迁移：旧 worlds.json 全量角色行开库时拆成定义+实例', () => {
  const root = mkdtempSync(join(tmpdir(), 'maliang-wti-'));
  try {
    const dir = join(root, 'data');
    mkdirSync(dir, { recursive: true });
    // 手写一份旧库文件：worlds.json 里角色是全量 Character（迁移前的形态）
    const legacyPig = pig({ worldId: 'default', memory: [] });
    const legacyRabbit = villager({ worldId: 'default' });
    writeFileSync(
      join(dir, 'worlds.json'),
      JSON.stringify({ worlds: [{ id: 'default', characters: [legacyPig, legacyRabbit] }] }),
    );

    const s = new WorldStore(dir); // 开库触发 json 迁移 + 拆定义/实例
    // 定义层已被填充
    assert.ok(s.getCharacterDef('story_three_pigs_pig_big'), '存量小猪的定义被抽出');
    assert.ok(s.getCharacterDef('rabbit1'));
    // getCharacter 仍返回完整 Character（身份来自定义，位置来自实例）
    const got = s.getCharacter('default', 'story_three_pigs_pig_big')!;
    assert.equal(got.name, '猪大哥');
    assert.deepEqual(got.position, { tileX: 29, tileY: 49 });
    assert.equal(got.storyRole!.resident, false);

    // 证明 getCharacter 真的从定义层取身份（而非残留 blob）：改定义 → 读到新值
    const d = s.getCharacterDef('story_three_pigs_pig_big')!;
    s.upsertCharacterDef({ ...d, name: '迁移后改名' });
    assert.equal(s.getCharacter('default', 'story_three_pigs_pig_big')!.name, '迁移后改名');

    // 幂等：重开一次不重复迁移、不损坏
    const s2 = new WorldStore(dir);
    assert.equal(s2.getCharacter('default', 'rabbit1')!.name, '舞舞兔');
    assert.equal(s2.listCharacterDefs().filter((x) => x.defId === 'rabbit1').length, 1, '同 defId 不重复建行');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
