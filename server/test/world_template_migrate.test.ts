// 世界模板架构 v2 P5（docs/world-template-instancing-design.md §6/§8）：放置级 additive 迁移。
// 定义级改动（长相/台词/性格/能力/剧本）已由共享定义自动下发（P1/P2 已证，零迁移）；
// 只有【放置级】改动——模板加了新村民、加了新册 story——需要迁移。走「复制放置」的 additive：
// 存量世界【已存在】时按 templateVersion 比对，把 template 里该世界还没有的放置补进去（按实例 id 查重），
// 【绝不覆盖】孩子已改的实例（移动的 NPC / 入住翻转 / 造物）。挪位/改态类模板改动【不】传播（保护孩子改动）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { emptyTerrain, encodeTerrain } from '../src/terrain.ts';
import type { Character, ScenePoi } from '../src/types.ts';

// s1-hood-activate P1：主场景 village_forest 的 poi_grandma——guide_to 引路终点。
const GRANDMA_POI: ScenePoi = { tile: [66, 63], radius: 14, trigger: 'poi_grandma', name: '外婆家', aliases: ['外婆', '奶奶家', '小屋'] };

/** 往某世界登记一张场景（默认主场景 + poi_grandma + 100 格地形）。 */
function registerScene(s: WorldStore, worldId: string, sceneId = 'village_forest', pois: ScenePoi[] = [GRANDMA_POI]): void {
  s.upsertScene({ worldId, sceneId, name: '林边村庄', terrainAsset: `h_${worldId}`, gridTiles: 100, pois, portals: [], terrainVersion: 1 });
  s.setSceneTerrain(worldId, sceneId, encodeTerrain(emptyTerrain(100)), 1);
}

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

function villager(worldId: string, id: string, name: string, over: Partial<Character> = {}): Character {
  return {
    id,
    worldId,
    isFairy: false,
    name,
    personality: '爱跳',
    voiceId: 'v-r',
    appearance: { visualDescription: '小动物', spriteAsset: 'hashV', scale: 1 },
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

/** 给 template 种最小内容（一个 story 角色 + 一个村民）。P6 后内容直接 seed 进 template，getOrCreate 从其克隆。 */
function seedTemplate(): WorldStore {
  const s = new WorldStore();
  s.ensureTemplateWorld(); // P6 后：空建 template
  s.saveCharacter(storyPig(TEMPLATE_WORLD_ID));
  s.saveCharacter(villager(TEMPLATE_WORLD_ID, 'rabbit1', '舞舞兔'));
  return s;
}

// ── ① 模板加新村民 + bump 版本 → 存量世界补出该村民；孩子已改实例不被覆盖 ────────────
test('P5 ① 模板加新村民并 bump → 存量世界迁移后补出；孩子改过的实例（位置/入住）不被覆盖', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  // 孩子在自己世界里挪了小猪 + 入住
  const pig = s.getCharacter(wa, 'story_three_pigs_pig_big')!;
  pig.position = { tileX: 3, tileY: 3 };
  pig.storyRole = { ...pig.storyRole!, resident: true };
  s.saveCharacter(pig);

  // 作者往模板加了一个新村民，并 bump 模板版本
  s.saveCharacter(villager(TEMPLATE_WORLD_ID, 'newbird', '唱唱鸟', { position: { tileX: 40, tileY: 20 } }));
  const v = s.bumpTemplateVersion();
  assert.ok(v >= 1, 'bump 后模板版本至少为 1');

  // 存量玩家再次进入自己的世界 → 触发 additive 迁移
  const wa2 = s.getOrCreateMyWorld('alice');
  assert.equal(wa2, wa, '同一玩家同一世界');

  // 新村民被补进来
  const bird = s.getCharacter(wa, 'newbird');
  assert.ok(bird, '存量世界补出模板新增的村民');
  assert.equal(bird!.name, '唱唱鸟');
  assert.deepEqual(bird!.position, { tileX: 40, tileY: 20 }, '放置从模板复制');

  // 孩子改过的小猪【绝不】被覆盖回模板初值
  const pigAfter = s.getCharacter(wa, 'story_three_pigs_pig_big')!;
  assert.deepEqual(pigAfter.position, { tileX: 3, tileY: 3 }, 'additive 只加不改：孩子位移保留');
  assert.equal(pigAfter.storyRole!.resident, true, 'additive 只加不改：孩子入住态保留');

  // 世界的已迁移版本追上模板
  assert.equal(s.getTemplateVersion(wa), s.getTemplateVersion(TEMPLATE_WORLD_ID), '世界版本追上模板');
});

// ── ② 模板加一整册 story（多个新 id 角色）→ 存量世界补出该册全部角色 ─────────────────
test('P5 ② 模板加一整册 story → 存量世界补出该册全部角色', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  assert.equal(s.getCharacter(wa, 'story_wolf_grandma_wolf'), undefined, '迁移前没有新册角色');

  // 作者往模板加一整册（小红帽：大灰狼 + 外婆），bump 版本
  s.saveCharacter(villager(TEMPLATE_WORLD_ID, 'story_wolf_grandma_wolf', '大灰狼', {
    storyRole: { bookId: 'red_riding_hood', castId: 'wolf', resident: false },
  }));
  s.saveCharacter(villager(TEMPLATE_WORLD_ID, 'story_wolf_grandma_grandma', '外婆', {
    storyRole: { bookId: 'red_riding_hood', castId: 'grandma', resident: false },
  }));
  s.bumpTemplateVersion();

  s.getOrCreateMyWorld('alice'); // 触发迁移
  assert.ok(s.getCharacter(wa, 'story_wolf_grandma_wolf'), '存量世界补出大灰狼');
  assert.ok(s.getCharacter(wa, 'story_wolf_grandma_grandma'), '存量世界补出外婆');
  assert.equal(s.getCharacter(wa, 'story_wolf_grandma_wolf')!.storyRole!.bookId, 'red_riding_hood');
});

// ── ③ 幂等：同版本再迁移不重复补、不炸 ────────────────────────────────────────────
test('P5 ③ 幂等：模板版本不变时再次进入不重复补入、不炸', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  s.saveCharacter(villager(TEMPLATE_WORLD_ID, 'newbird', '唱唱鸟'));
  s.bumpTemplateVersion();
  s.getOrCreateMyWorld('alice'); // 第一次迁移
  const countAfter1 = s.listCharacters(wa).length;

  // 再进两次（版本没变）——不应重复补、数量不变
  s.getOrCreateMyWorld('alice');
  s.getOrCreateMyWorld('alice');
  assert.equal(s.listCharacters(wa).length, countAfter1, '同版本重复迁移不改变角色数');
});

// ── ④ 复合 PK + templateVersion 列迁移：持久库重开幂等，迁移仍生效 ──────────────────
test('P5 ④ 持久库：template_version 列迁移幂等，重开后仍能按版本补入且不重复', () => {
  const root = mkdtempSync(join(tmpdir(), 'maliang-wtm-'));
  try {
    const dir = join(root, 'data');
    mkdirSync(dir, { recursive: true });
    // 首开：seed 进 template + 建 alice 世界 + 模板加新村民 + bump（迁移一次）
    {
      const s = new WorldStore(dir);
      s.ensureTemplateWorld();
      s.saveCharacter(storyPig(TEMPLATE_WORLD_ID));
      const wa = s.getOrCreateMyWorld('alice');
      s.saveCharacter(villager(TEMPLATE_WORLD_ID, 'newbird', '唱唱鸟'));
      s.bumpTemplateVersion();
      s.getOrCreateMyWorld('alice');
      assert.ok(s.getCharacter(wa, 'newbird'), '首开迁移补出新村民');
    }
    // 重开：列迁移必须幂等（不炸），数据完整，版本记账存活
    {
      const s2 = new WorldStore(dir);
      assert.ok(s2.getCharacter('w_alice', 'newbird'), '重开后新村民存活');
      assert.equal(
        s2.getTemplateVersion('w_alice'),
        s2.getTemplateVersion(TEMPLATE_WORLD_ID),
        '重开后世界版本仍等于模板版本',
      );
      const before = s2.listCharacters('w_alice').length;
      s2.getOrCreateMyWorld('alice'); // 版本相同，不应重复补
      assert.equal(s2.listCharacters('w_alice').length, before, '重开后同版本再进不重复补');
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// ── ⑤ additive 只加不改：模板挪已存在 NPC 位置【不】传播到存量世界 ─────────────────
test('P5 ⑤ 模板挪动/改动已存在 NPC 的放置不传播到存量世界（保护孩子改动，只加不改）', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  const before = s.getCharacter(wa, 'rabbit1')!.position;

  // 作者在模板里把兔子挪走了，并 bump
  const tRabbit = s.getCharacter(TEMPLATE_WORLD_ID, 'rabbit1')!;
  tRabbit.position = { tileX: 60, tileY: 60 };
  s.saveCharacter(tRabbit);
  s.bumpTemplateVersion();

  s.getOrCreateMyWorld('alice'); // 触发迁移
  assert.deepEqual(
    s.getCharacter(wa, 'rabbit1')!.position,
    before,
    'additive 不覆盖已存在实例：模板挪位不传播（新世界靠 clone 才拿新位置）',
  );
});

// ── s1-hood-activate P1：场景层 additive 迁移（存量世界经 bump 拿到新主场景 + poi_grandma）──

test('s1-P1 存量世界经 bump additive 补入模板新登记的主场景（含 poi_grandma），引路才有目标', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice'); // 该世界建于「模板还没有 village_forest 场景」时
  assert.equal(s.getScene(wa, 'village_forest'), undefined, '迁移前存量世界没有主场景');

  // 作者往模板登记 village_forest 主场景并 bump
  registerScene(s, TEMPLATE_WORLD_ID);
  s.bumpTemplateVersion();

  s.getOrCreateMyWorld('alice'); // 触发 additive 迁移
  const scene = s.getScene(wa, 'village_forest');
  assert.ok(scene, '存量世界 additive 补出模板新增的主场景');
  assert.equal(scene!.pois[0]!.trigger, 'poi_grandma', 'poi_grandma 随场景补入');
  assert.ok(s.getSceneTerrain(wa, 'village_forest'), '地形 blob 也补入');
});

test('s1-P1 additive 只加不改：孩子已编辑过的同名场景【不】被模板覆盖（保住地形编辑）', () => {
  const s = seedTemplate();
  const wa = s.getOrCreateMyWorld('alice');
  // 孩子在自己世界里编辑过主场景（换了 POI 名单，模拟摆放/改地形）
  registerScene(s, wa, 'village_forest', [{ ...GRANDMA_POI, name: '孩子改过的外婆家' }]);

  // 模板登记一份不同内容的同名场景 + bump
  registerScene(s, TEMPLATE_WORLD_ID, 'village_forest', [GRANDMA_POI]);
  s.bumpTemplateVersion();

  s.getOrCreateMyWorld('alice'); // 触发迁移
  assert.equal(
    s.getScene(wa, 'village_forest')!.pois[0]!.name,
    '孩子改过的外婆家',
    'additive 不覆盖已存在场景：孩子的地形/POI 编辑保留',
  );
});

// ── ⑥ bumpTemplateVersion 自增语义 + template 世界自持版本 ─────────────────────────
test('P5 ⑥ bumpTemplateVersion 递增；新建世界克隆时版本即等于模板当前版本（不误触发迁移）', () => {
  const s = seedTemplate();
  s.ensureTemplateWorld();
  assert.equal(s.getTemplateVersion(TEMPLATE_WORLD_ID), 0, '模板初始版本 0');
  assert.equal(s.bumpTemplateVersion(), 1);
  assert.equal(s.bumpTemplateVersion(), 2);
  assert.equal(s.getTemplateVersion(TEMPLATE_WORLD_ID), 2);

  // 此后新建的世界，克隆时版本应记为模板当前版本（2），不该因 0<2 而立刻重复迁移
  const wb = s.getOrCreateMyWorld('bob');
  assert.equal(s.getTemplateVersion(wb), 2, '新世界克隆于模板当前版本');
});
