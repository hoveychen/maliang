// 世界模板架构 v2 P2（docs/world-template-instancing-design.md §4/§8）：
// template 世界（P6 后：空建，内容直接 seed 进 template）+ cloneWorldInstances（只复制实例放置，def 引用不变）+
// get-or-create-my-world。核心证明：复合 PK (world_id,id) 让两玩家世界各持同一 story 角色 id
// 一份实例；改共享定义一次两世界都变；改实例态互相隔离；template 不接客。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer } from '../src/server.ts';
import type { Character } from '../src/types.ts';

// story 角色：instance id = defId = storyCharacterId（story_director.ts 直接按此 id getCharacter）。
function storyPig(worldId: string, over: Partial<Character> = {}): Character {
  return {
    id: 'story_three_pigs_pig_big',
    worldId,
    isFairy: false,
    name: '猪大哥',
    personality: '稳重可靠',
    voiceId: 'v-pig',
    appearance: { visualDescription: '戴草帽的猪', spriteAsset: 'hashPIG', scale: 1.2 },
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

function villager(worldId: string, over: Partial<Character> = {}): Character {
  return {
    id: 'rabbit1',
    worldId,
    isFairy: false,
    name: '舞舞兔',
    personality: '爱跳',
    voiceId: 'v-r',
    appearance: { visualDescription: '兔', spriteAsset: 'hashRAB', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 },
    sceneId: 'village',
    abilities: [],
    relationships: {},
    ...over,
  };
}

/**
 * 给 template 种最小内容（一个 story 角色 + 一个村民）。P6 后 template 是唯一权威母版——
 * 内容直接 seed 进 template（不再经 default 提升），getOrCreateMyWorld 从 template 克隆。
 */
function seedTemplate(): WorldStore {
  const s = new WorldStore();
  s.ensureTemplateWorld(); // P6 后：空建 template
  s.saveCharacter(storyPig(TEMPLATE_WORLD_ID));
  s.saveCharacter(villager(TEMPLATE_WORLD_ID));
  return s;
}

// ── cloneWorldInstances：只复制实例放置，定义永不复制 ─────────────────────────────

test('P2 cloneWorldInstances：复制实例放置到目标世界（id/defId/位置/状态原样，只换 worldId）', () => {
  const s = seedTemplate();
  s.cloneWorldInstances(TEMPLATE_WORLD_ID, 'dst');
  const pig = s.getCharacter('dst', 'story_three_pigs_pig_big')!;
  assert.ok(pig, '目标世界应有克隆过来的小猪实例');
  assert.equal(pig.worldId, 'dst', 'worldId 换成目标世界');
  assert.equal(pig.name, '猪大哥', '身份来自共享定义（克隆不复制定义，引用不变）');
  assert.deepEqual(pig.position, { tileX: 29, tileY: 49 }, '放置原样复制');
  assert.equal(s.getCharacter('dst', 'rabbit1')!.name, '舞舞兔');
  // 定义层没有因克隆多出 world 维度的副本——仍是同一份共享定义
  assert.equal(s.listCharacterDefs().filter((d) => d.defId === 'story_three_pigs_pig_big').length, 1, 'def 不被复制');
});

test('P2 cloneWorldInstances：目标世界不存在时自动建；源为空则复制 0 行不炸', () => {
  const s = new WorldStore();
  s.createWorld('src'); // 空源
  s.cloneWorldInstances('src', 'brandNew');
  assert.ok(s.worldExists('brandNew'), '目标世界被自动创建');
  assert.equal(s.listCharacters('brandNew').length, 0);
});

// ── ensureTemplateWorld：P6 后只空建 template，不再从 default 提升 ──────────────────

test('P6 ensureTemplateWorld：只空建 template，绝不从 default 提升内容（default 已退役）', () => {
  const s = new WorldStore();
  // default 里即便有内容，也【不】被提升进 template——内容改由作者直接 seed 进 template。
  s.createWorld('default');
  s.saveCharacter(storyPig('default'));
  s.saveCharacter(villager('default'));

  s.ensureTemplateWorld();
  assert.ok(s.worldExists('template'), 'template 被建出');
  assert.equal(s.listCharacters('template').length, 0, 'template 空建，不克隆 default 的实例');

  // 幂等：已存在直接返回，不覆盖作者对模板的编辑
  s.saveCharacter(villager('template'));
  s.ensureTemplateWorld();
  assert.equal(s.listCharacters('template').length, 1, '幂等：已存在不重建、不清空作者内容');
});

// ── get-or-create-my-world：每人一世界，从 template 复制放置 ────────────────────────

test('P2 ① getOrCreateMyWorld：新玩家得到独立世界，含 template 的实例（同 defId、放置复制）', () => {
  const s = seedTemplate();
  const wid = s.getOrCreateMyWorld('alice');
  assert.equal(wid, 'w_alice');
  assert.ok(s.worldExists('w_alice'));
  const pig = s.getCharacter('w_alice', 'story_three_pigs_pig_big')!;
  assert.equal(pig.name, '猪大哥', '身份来自共享定义');
  assert.deepEqual(pig.position, { tileX: 29, tileY: 49 }, '放置从 template 复制');
  assert.equal(pig.storyRole!.resident, false, '入住态从模板的 false 起');
});

test('P2 getOrCreateMyWorld：已存在则返回同一世界、不重新克隆覆盖孩子改动', () => {
  const s = seedTemplate();
  const wid = s.getOrCreateMyWorld('bob');
  // 孩子在自己世界里挪了小猪 + 入住
  const pig = s.getCharacter(wid, 'story_three_pigs_pig_big')!;
  pig.position = { tileX: 3, tileY: 3 };
  pig.storyRole = { ...pig.storyRole!, resident: true };
  s.saveCharacter(pig);
  // 再次 get-or-create 不应把它冲回模板初值
  const wid2 = s.getOrCreateMyWorld('bob');
  assert.equal(wid2, wid);
  assert.deepEqual(s.getCharacter(wid, 'story_three_pigs_pig_big')!.position, { tileX: 3, tileY: 3 }, '不重新克隆覆盖');
  assert.equal(s.getCharacter(wid, 'story_three_pigs_pig_big')!.storyRole!.resident, true);
});

test('P2 getOrCreateMyWorld：template 无点点时用注入的 makeFairy 补种；有则不重复种', () => {
  const s = seedTemplate(); // 模板无仙子
  let calls = 0;
  const makeFairy = (worldId: string): Character => {
    calls++;
    return {
      id: `fairy_${worldId}`, worldId, isFairy: true, name: '点点', personality: '笔灵', voiceId: 'v-f',
      appearance: { visualDescription: '一点墨', spriteAsset: '', scale: 1.2 },
      memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: true },
      position: { tileX: 30, tileY: 50 }, sceneId: 'village', abilities: ['create_character'], relationships: {},
    };
  };
  const wid = s.getOrCreateMyWorld('carol', makeFairy);
  assert.equal(calls, 1, '模板无点点，补种一次');
  assert.ok(s.listCharacters(wid).some((c) => c.isFairy), '世界里有点点');
  // 已存在世界再调不再补种
  s.getOrCreateMyWorld('carol', makeFairy);
  assert.equal(calls, 1, '已存在世界不重复补种');
});

// ── ② 复合 PK：两玩家世界各持同一 story 角色一份，实例态隔离 ───────────────────────

test('P2 ② 两玩家世界各持同一 story 角色 id 一份（复合 PK 生效）；改 A 实例态不动 B', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  const wb = s.getOrCreateMyWorld('bob');
  // 同一 id 在两世界各一份（全局 PK 装不下——这就是复合 PK 的证明）
  const a = s.getCharacter(wa, 'story_three_pigs_pig_big')!;
  const b = s.getCharacter(wb, 'story_three_pigs_pig_big')!;
  assert.ok(a && b, '两世界都能按同一 id 查到自己那份');
  assert.equal(a.worldId, wa);
  assert.equal(b.worldId, wb);

  // 改 A 世界那份的实例态（入住 + 位移）
  a.storyRole = { ...a.storyRole!, resident: true };
  a.position = { tileX: 10, tileY: 10 };
  s.saveCharacter(a);

  assert.equal(s.getCharacter(wa, 'story_three_pigs_pig_big')!.storyRole!.resident, true, 'A 世界入住');
  assert.equal(s.getCharacter(wb, 'story_three_pigs_pig_big')!.storyRole!.resident, false, 'B 世界那份不受影响');
  assert.deepEqual(s.getCharacter(wb, 'story_three_pigs_pig_big')!.position, { tileX: 29, tileY: 49 }, 'B 位置不动');
});

// ── ③ 共享定义更新自动下发到所有克隆出的真实世界 ────────────────────────────────

test('P2 ③ 改共享定义一次→两玩家世界 getCharacter 都变（经 clone 建的真实世界）', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  const wb = s.getOrCreateMyWorld('bob');
  const def = s.getCharacterDef('story_three_pigs_pig_big')!;
  s.upsertCharacterDef({ ...def, name: '猪二哥', appearance: { ...def.appearance, spriteAsset: 'hashNEW' } });
  assert.equal(s.getCharacter(wa, 'story_three_pigs_pig_big')!.name, '猪二哥');
  assert.equal(s.getCharacter(wb, 'story_three_pigs_pig_big')!.name, '猪二哥');
  assert.equal(s.getCharacter(wa, 'story_three_pigs_pig_big')!.appearance.spriteAsset, 'hashNEW');
  assert.equal(s.getCharacter(wb, 'story_three_pigs_pig_big')!.appearance.spriteAsset, 'hashNEW');
});

// ── ④ 任何世界都不接客：GET /worlds/:id 不再自动建（P6 退役 default 的特殊分支）────────

test('P2 ④ template 不接客：GET /worlds/template 不自动创建（404）', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const res = await app.inject({ method: 'GET', url: '/worlds/template' });
    assert.equal(res.statusCode, 404, 'template 不是 default，不自动建');
    assert.equal(store.worldExists('template'), false, '不应凭空建出 template');
  } finally {
    await app.close();
  }
});

test('P6 ④ default 已退役：GET /worlds/default 不再自动创建（404），不凭空造 default 世界', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const res = await app.inject({ method: 'GET', url: '/worlds/default' });
    assert.equal(res.statusCode, 404, 'P6 后 default 不再是特殊世界，不存在即 404');
    assert.equal(store.worldExists('default'), false, '不应凭空建出 default 世界');
    assert.equal(store.listCharacters('default').length, 0, '不应种入点点');
  } finally {
    await app.close();
  }
});

test('P2 GET /worlds/mine：按 playerId 解析/建每人一世界并返回其 id', async () => {
  const store = new WorldStore();
  store.ensureTemplateWorld();
  store.saveCharacter(storyPig(TEMPLATE_WORLD_ID));
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const res = await app.inject({ method: 'GET', url: '/worlds/mine?playerId=dave' });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { id: string; characters: unknown[] };
    assert.equal(body.id, 'w_dave');
    assert.ok(store.worldExists('w_dave'));
    // 世界内容可拉到（含克隆的小猪 + 补种的点点）
    assert.ok(Array.isArray(body.characters) && body.characters.length >= 1);
    assert.ok(store.listCharacters('w_dave').some((c) => c.isFairy), 'get-or-create 保证有点点');
  } finally {
    await app.close();
  }
});

test('P2 GET /worlds/mine：缺 playerId 返回 400', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    const res = await app.inject({ method: 'GET', url: '/worlds/mine' });
    assert.equal(res.statusCode, 400);
  } finally {
    await app.close();
  }
});

// ── ⑤ 复合 PK 迁移幂等：持久库重开不炸，老库角色存活，两世界可同 id ──────────────

test('P2 ⑤ 复合 PK 迁移幂等：持久库重开不炸、老库角色存活、克隆后两世界同 id 各一份', () => {
  const root = mkdtempSync(join(tmpdir(), 'maliang-wtc-'));
  try {
    const dir = join(root, 'data');
    mkdirSync(dir, { recursive: true });
    // 首开：seed 进 template + 种角色（走真实读写路径，落进复合 PK 的库）
    {
      const s = new WorldStore(dir);
      s.ensureTemplateWorld();
      s.saveCharacter(storyPig(TEMPLATE_WORLD_ID));
      // 建两个玩家世界（从 template 克隆，同 story id 各一份，复合 PK 才装得下）
      const wa = s.getOrCreateMyWorld('alice');
      const wb = s.getOrCreateMyWorld('bob');
      assert.ok(s.getCharacter(wa, 'story_three_pigs_pig_big'));
      assert.ok(s.getCharacter(wb, 'story_three_pigs_pig_big'));
    }
    // 重开：复合 PK 迁移必须幂等，不炸、数据完整
    {
      const s2 = new WorldStore(dir);
      assert.equal(s2.getCharacter('w_alice', 'story_three_pigs_pig_big')!.name, '猪大哥', '重开后 alice 世界角色存活');
      assert.equal(s2.getCharacter('w_bob', 'story_three_pigs_pig_big')!.name, '猪大哥', '重开后 bob 世界角色存活');
      // 定义仍只有一份（未随克隆/重开翻倍）
      assert.equal(s2.listCharacterDefs().filter((d) => d.defId === 'story_three_pigs_pig_big').length, 1);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
