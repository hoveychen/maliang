// 角色实例层 base+overlay（char-instance-overlay 路线 A，见 docs/char-instance-overlay-design.md §9）：
// listCharacters/getCharacter 读时合成 template base 花名册 ⊕ 世界 overlay。
// 核心：新模板角色【立即】出现在存量世界（无需 bump/additive/重进）；sceneId 追平 base；世界可变态保留；
// 世界独有角色（孩子造物）+ 点点照常。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import type { Character } from '../src/types.ts';

function char(worldId: string, id: string, over: Partial<Character> = {}): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: 'd', spriteAsset: 'h', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [{ type: 'wander', params: { radius: 3, duration: 8 } }], loop: true },
    position: { tileX: 20, tileY: 15 }, sceneId: 'village_forest', abilities: [], relationships: {},
    ...over,
  };
}

/** template + 一个已克隆的玩家世界。template 里放两个 village_forest 角色。 */
function templateWithKid(): { s: WorldStore; kid: string } {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  s.saveCharacter(char(TEMPLATE_WORLD_ID, 'pig', { name: '猪大哥', position: { tileX: 20, tileY: 15 } }));
  s.saveCharacter(char(TEMPLATE_WORLD_ID, 'hood', { name: '小红帽', position: { tileX: 25, tileY: 18 } }));
  const kid = s.getOrCreateMyWorld('kid'); // 克隆 → kid 有 pig/hood
  return { s, kid };
}

// ── §9.7 验收 1：新模板角色立即出现在存量世界（无 bump / 无 additive / 无重进）──────────

test('路线A 存在传播：作者往 template 加新角色 → 存量世界 listCharacters 立即含它（不 bump 不重进）', () => {
  const { s, kid } = templateWithKid();
  assert.equal(s.getCharacter(kid, 'wolf'), undefined, '加之前 kid 没有大灰狼');

  // 只往 template 加，一次都不碰 kid、不 bumpTemplateVersion、不 getOrCreateMyWorld
  s.saveCharacter(char(TEMPLATE_WORLD_ID, 'wolf', { name: '大灰狼', sceneId: 'village_forest' }));

  assert.ok(s.getCharacter(kid, 'wolf'), '读时合成：新模板角色立即在存量世界出现');
  assert.equal(s.getCharacter(kid, 'wolf')!.name, '大灰狼', '身份来自共享定义');
  assert.ok(s.listCharacters(kid).some((c) => c.id === 'wolf'), 'listCharacters 也含新角色');
  assert.ok(s.listCharacters(kid, 'village_forest').some((c) => c.id === 'wolf'), '按场景查也含（sceneId 合成正确）');
});

test('路线A 存在传播：多个存量世界共享同一 base，加一次全体现', () => {
  const { s } = templateWithKid();
  const a = s.getOrCreateMyWorld('a');
  const b = s.getOrCreateMyWorld('b');
  s.saveCharacter(char(TEMPLATE_WORLD_ID, 'newbird', { name: '唱唱鸟' }));
  assert.ok(s.getCharacter(a, 'newbird'), 'a 立即有');
  assert.ok(s.getCharacter(b, 'newbird'), 'b 立即有');
});

// ── §9.7 验收 2：sceneId 追平 base（修 village→village_forest）─────────────────────

test('路线A sceneId 追平：世界行 sceneId 陈旧（village），读时取 base 的（village_forest）', () => {
  const { s, kid } = templateWithKid();
  // 模拟旧世界：kid 的 pig 卡在旧 village 场景（直接写世界行）
  const stalePig = s.getCharacter(kid, 'pig')!;
  stalePig.sceneId = 'village';
  s.saveCharacter(stalePig);

  // getCharacter 合成：sceneId 取 base（village_forest），不是世界行的 village
  assert.equal(s.getCharacter(kid, 'pig')!.sceneId, 'village_forest', 'sceneId 追平 template base');
  // listCharacters(village_forest) 含 pig（追平后归入主场景），listCharacters(village) 不含
  assert.ok(s.listCharacters(kid, 'village_forest').some((c) => c.id === 'pig'), '主场景查得到（已追平）');
  assert.ok(!s.listCharacters(kid, 'village').some((c) => c.id === 'pig'), '旧 village 场景不再有 pig');
});

test('路线A sceneId 追平：作者在 template 改角色场景 → 存量世界读到新场景', () => {
  const { s, kid } = templateWithKid();
  const tpig = s.getCharacter(TEMPLATE_WORLD_ID, 'pig')!;
  tpig.sceneId = 'oz';
  s.saveCharacter(tpig); // 作者把 pig 挪到 oz 场景
  assert.equal(s.getCharacter(kid, 'pig')!.sceneId, 'oz', '存量世界读到 base 的新场景');
});

// ── §9.7 验收 3：世界可变态保留（不被 base 冲掉）──────────────────────────────────

test('路线A 可变态保留：孩子的 memory/relationships/入住/位置读合成后仍在，只 sceneId 走 base', () => {
  const { s, kid } = templateWithKid();
  const pig = s.getCharacter(kid, 'pig')!;
  pig.memory = [{ text: '见过小明', ts: 1 } as never];
  pig.relationships = { kid1: { chats: 3, wishesDone: 1, gifted: false, lastSeen: 0 } };
  pig.storyRole = { bookId: 'three_pigs', castId: 'pig_big', resident: true }; // 孩子把它留下（入住）
  pig.position = { tileX: 40, tileY: 40 }; // wander 漂移后的 live 位置
  s.saveCharacter(pig);

  // 作者同时在 template 改了 pig 的位置/场景（authored）
  const tpig = s.getCharacter(TEMPLATE_WORLD_ID, 'pig')!;
  tpig.position = { tileX: 5, tileY: 5 };
  s.saveCharacter(tpig);

  const got = s.getCharacter(kid, 'pig')!;
  assert.deepEqual(got.memory, [{ text: '见过小明', ts: 1 }], '记忆保留');
  assert.equal(got.relationships.kid1!.chats, 3, '关系保留');
  assert.equal(got.storyRole!.resident, true, '入住态保留（孩子 agency）');
  assert.deepEqual(got.position, { tileX: 40, tileY: 40 }, 'live 位置保留（不被 base authored 位冲掉）');
});

// ── §9.7 验收 4：世界独有角色（孩子造物）+ 点点照常 ─────────────────────────────────

test('路线A 世界独有：孩子造物（不在 template）照常存在、身份正确', () => {
  const { s, kid } = templateWithKid();
  s.saveCharacter(char(kid, 'kid_creation_1', { name: '会飞的鲸鱼', sceneId: 'village_forest' }));
  const got = s.getCharacter(kid, 'kid_creation_1');
  assert.ok(got, '世界独有角色存在');
  assert.equal(got!.name, '会飞的鲸鱼');
  assert.ok(s.listCharacters(kid).some((c) => c.id === 'kid_creation_1'), 'listCharacters 含世界独有角色');
  // template 里没有它
  assert.equal(s.getCharacter(TEMPLATE_WORLD_ID, 'kid_creation_1'), undefined, 'template 无孩子造物');
});

test('路线A 点点（与 template 同 id）：合成后唯一、isFairy 正确，不重复', () => {
  const s = new WorldStore();
  s.createWorld(TEMPLATE_WORLD_ID);
  s.saveCharacter(char(TEMPLATE_WORLD_ID, 'fairy_dot', { isFairy: true, name: '点点', sceneId: 'village' }));
  s.saveCharacter(char(TEMPLATE_WORLD_ID, 'pig', { name: '猪大哥' }));
  const kid = s.getOrCreateMyWorld('kid'); // 克隆带上点点（同 id）
  const fairies = s.listCharacters(kid).filter((c) => c.isFairy);
  assert.equal(fairies.length, 1, '点点唯一不重复');
  assert.equal(fairies[0]!.id, 'fairy_dot');
  // 点点跨场景恒在：按任意场景查都带上她
  assert.ok(s.listCharacters(kid, 'oz').some((c) => c.isFairy), '点点在任意场景查询都在');
});

// ── template 世界本身不合成（它就是 base）──────────────────────────────────────────

test('路线A template 世界读自己的行（不自我合成）', () => {
  const { s } = templateWithKid();
  const names = s.listCharacters(TEMPLATE_WORLD_ID).map((c) => c.id).sort();
  assert.deepEqual(names, ['hood', 'pig'], 'template 返回自己的角色，无重复无凭空多出');
});
