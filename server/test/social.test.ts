import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { projectCharacterFor } from '../src/server.ts';
import {
  coerceRelationship,
  deriveFamiliarity,
  deriveSocialType,
  familiarityFor,
  freshRelationship,
} from '../src/social.ts';
import type { Character } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string, greetingStyle?: string, isFairy = false): Character {
  const c: Character = {
    id,
    worldId,
    isFairy,
    name: id,
    personality: '',
    voiceId: 'v1',
    ...(greetingStyle ? { greetingStyle } : {}),
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

// ── 性格类型：从招呼风格派生 ────────────────────────────────────────────

test('deriveSocialType: warm/playful → 外向，shy/gentle → 内向', () => {
  assert.equal(deriveSocialType({ id: 'a', greetingStyle: 'warm' }), 'extrovert');
  assert.equal(deriveSocialType({ id: 'a', greetingStyle: 'playful' }), 'extrovert');
  assert.equal(deriveSocialType({ id: 'a', greetingStyle: 'shy' }), 'introvert');
  assert.equal(deriveSocialType({ id: 'a', greetingStyle: 'gentle' }), 'introvert');
});

test('deriveSocialType: 缺省招呼风格按 id 稳定哈希兜底（同 id 每次一致）', () => {
  const t1 = deriveSocialType({ id: 'npc-stable-42' });
  const t2 = deriveSocialType({ id: 'npc-stable-42' });
  assert.equal(t1, t2, '同一 id 必须稳定');
  assert.ok(t1 === 'extrovert' || t1 === 'introvert');
});

// ── 熟识度：实质互动才算熟 ──────────────────────────────────────────────

test('deriveFamiliarity: 无互动→陌生，聊过→点头之交，完成心愿→朋友', () => {
  assert.equal(deriveFamiliarity(freshRelationship()), 'stranger');
  assert.equal(deriveFamiliarity({ chats: 3, wishesDone: 0, gifted: false, lastSeen: 0 }), 'acquaintance');
  assert.equal(deriveFamiliarity({ chats: 5, wishesDone: 1, gifted: false, lastSeen: 0 }), 'friend');
});

test('deriveFamiliarity: 只被送过花不升级（挥手/收花不算实质互动）', () => {
  assert.equal(deriveFamiliarity({ chats: 0, wishesDone: 0, gifted: true, lastSeen: 0 }), 'stranger');
});

test('coerceRelationship: 老档 {}/字符串/缺失一律归一为新关系，不崩', () => {
  assert.deepEqual(coerceRelationship({}), freshRelationship());
  assert.deepEqual(coerceRelationship('旧string值'), freshRelationship());
  assert.deepEqual(coerceRelationship(undefined), freshRelationship());
  assert.deepEqual(coerceRelationship(null), freshRelationship());
  // 部分字段：数值容错，缺的补 0
  assert.deepEqual(coerceRelationship({ chats: 2 }), { chats: 2, wishesDone: 0, gifted: false, lastSeen: 0 });
});

// ── recordVillagerBond：打点 + 持久化 round-trip ────────────────────────

test('recordVillagerBond: 聊天累进→点头之交，落库后 getCharacter 读得回', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'npc1', 'shy');
  const r = store.recordVillagerBond('w1', 'npc1', 'p1', 'chat');
  assert.equal(r.familiarity, 'acquaintance');
  assert.equal(r.changed, true, '陌生→点头之交是一次跨级升级');
  // round-trip：从 DB 重新读，relationships 真落盘了
  const reloaded = store.getCharacter('w1', 'npc1')!;
  assert.equal(deriveFamiliarity(reloaded.relationships['p1']), 'acquaintance');
  assert.equal(reloaded.relationships['p1'].chats, 1);
});

test('recordVillagerBond: 完成心愿→朋友；再聊不改变已达朋友（不降级、changed=false）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'npc1', 'warm');
  const wish = store.recordVillagerBond('w1', 'npc1', 'p1', 'wish');
  assert.equal(wish.familiarity, 'friend');
  assert.equal(wish.changed, true);
  const chat = store.recordVillagerBond('w1', 'npc1', 'p1', 'chat');
  assert.equal(chat.familiarity, 'friend', '已是朋友，聊天不降级');
  assert.equal(chat.changed, false, '没有跨级变化');
});

test('recordVillagerBond: 熟识度按 (村民,玩家) 分，不串味', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'npc1', 'warm');
  store.recordVillagerBond('w1', 'npc1', 'p1', 'wish');
  const c = store.getCharacter('w1', 'npc1')!;
  assert.equal(deriveFamiliarity(c.relationships['p1']), 'friend');
  assert.equal(deriveFamiliarity(c.relationships['p2']), 'stranger', 'p2 从没互动，仍是陌生人');
});

test('recordVillagerBond: 仙子/空 playerId no-op', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'fairy', 'gentle', true);
  const r = store.recordVillagerBond('w1', 'fairy', 'p1', 'chat');
  assert.equal(r.changed, false);
  assert.deepEqual(store.getCharacter('w1', 'fairy')!.relationships, {}, '仙子不记关系');
  const empty = store.recordVillagerBond('w1', 'fairy', '', 'chat');
  assert.equal(empty.changed, false);
});

// ── projectCharacterFor：下发投影 ───────────────────────────────────────

test('projectCharacterFor: 附加 socialType + 该玩家视角的 familiarity', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const c = seedChar(store, 'w1', 'npc1', 'warm');
  store.recordVillagerBond('w1', 'npc1', 'p1', 'chat');
  const fresh = store.getCharacter('w1', 'npc1')!;
  const forP1 = projectCharacterFor(fresh, 'p1');
  assert.equal(forP1.socialType, 'extrovert');
  assert.equal(forP1.familiarity, 'acquaintance');
  // 另一个玩家眼里同一个村民还是陌生人
  const forP2 = projectCharacterFor(fresh, 'p2');
  assert.equal(forP2.familiarity, 'stranger');
  // 原始对象没被污染（socialType/familiarity 是下发时现算，不落 Character 本体）
  assert.equal((c as Character & { socialType?: string }).socialType, undefined);
});

test('projectCharacterFor: 空 viewer → 熟识度恒 stranger（新角色广播场景）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const c = seedChar(store, 'w1', 'npc1', 'playful');
  store.recordVillagerBond('w1', 'npc1', 'p1', 'wish'); // 即便有人已是朋友
  const view = projectCharacterFor(store.getCharacter('w1', 'npc1')!, '');
  assert.equal(view.familiarity, 'stranger');
  assert.equal(view.socialType, 'extrovert');
});

test('projectCharacterFor: 仙子原样返回（不附社交字段）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'fairy', 'gentle', true);
  const view = projectCharacterFor(store.getCharacter('w1', 'fairy')!, 'p1');
  assert.equal((view as Character & { socialType?: string }).socialType, undefined);
});

test('familiarityFor: 直接读村民 relationships（等价 deriveFamiliarity）', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'npc1', 'warm');
  store.recordVillagerBond('w1', 'npc1', 'p1', 'wish');
  assert.equal(familiarityFor(store.getCharacter('w1', 'npc1')!, 'p1'), 'friend');
  assert.equal(familiarityFor(store.getCharacter('w1', 'npc1')!, 'pX'), 'stranger');
});
