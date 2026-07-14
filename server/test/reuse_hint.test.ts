// B3 复用提示（reuse-name，docs/kids-thinking-reuse-name.md §3.1 / §5）：纯函数 reuseHint。
// 背包旧物 kind ∩ 眼前活跃需求 kind 命中才响；不命中/无对应背包物品/本会话已提过 → null。零 LLM、确定性。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { reuseHint } from '../src/wishes.ts';
import type { Character, ItemDef } from '../src/types.ts';
import { ANON_PLAYER } from '../src/types.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { RateLimiter } from '../src/ratelimit.ts';

/** 最小 ItemDef；mount:'edge' = 贴纸，缺省 = 造物（prop）。 */
function item(id: string, opts: Partial<ItemDef> = {}): ItemDef {
  return {
    id, worldId: 'w', name: opts.name ?? id, renderRef: 'sdf_inline',
    footprintW: 1, footprintH: 1, blocking: true, pathOk: true, wander: 0,
    ...opts,
  };
}

test('命中：需求 create_prop + 背包有造物旧物 → 返回该旧物', () => {
  const bag = [item('ladder-1', { name: '梯子' })];
  const h = reuseHint(['create_prop'], bag, new Set());
  assert.deepEqual(h, { itemId: 'ladder-1', itemName: '梯子', ability: 'create_prop' });
});

test('命中：需求 create_sticker + 背包有贴纸(mount:edge) → 返回', () => {
  const bag = [item('star-1', { name: '星星', mount: 'edge' })];
  const h = reuseHint(['create_sticker'], bag, new Set());
  assert.equal(h?.itemId, 'star-1');
  assert.equal(h?.ability, 'create_sticker');
});

test('不命中：kind 不对——需求造物但背包只有贴纸 → null', () => {
  const bag = [item('star-1', { mount: 'edge' })];
  assert.equal(reuseHint(['create_prop'], bag, new Set()), null);
});

test('不命中：需求 create_character / play_game / guide_to 无背包物品 → null', () => {
  const bag = [item('ladder-1'), item('star-1', { mount: 'edge' })];
  assert.equal(reuseHint(['create_character'], bag, new Set()), null);
  assert.equal(reuseHint(['play_game'], bag, new Set()), null);
  assert.equal(reuseHint(['guide_to'], bag, new Set()), null);
});

test('不命中：空背包 / 无活跃需求 → null', () => {
  assert.equal(reuseHint(['create_prop'], [], new Set()), null);
  assert.equal(reuseHint([], [item('ladder-1')], new Set()), null);
});

test('本会话已提过该「旧物×需求」配对 → 不重复', () => {
  const bag = [item('ladder-1', { name: '梯子' })];
  const seen = new Set(['ladder-1:create_prop']);
  assert.equal(reuseHint(['create_prop'], bag, seen), null);
});

test('去重 key 含 ability：同一旧物对不同需求可各提一次', () => {
  // 一件既是造物又…（构造上不会同时，但验 key 粒度）：贴纸对 create_sticker 提过，
  // 换成另一件造物对 create_prop 仍能提。
  const bag = [item('star-1', { mount: 'edge' }), item('ladder-1')];
  const seen = new Set(['star-1:create_sticker']);
  const h = reuseHint(['create_sticker', 'create_prop'], bag, seen);
  assert.equal(h?.itemId, 'ladder-1', 'star 那条被去重，落到 ladder 的 create_prop');
  assert.equal(h?.ability, 'create_prop');
});

test('itemName 优先孩子起的 nameText，回落 LLM 文本名 name', () => {
  const named = reuseHint(['create_prop'], [item('l', { name: '会开花的树', nameText: '花花' })], new Set());
  assert.equal(named?.itemName, '花花', '有 nameText 用它');
  const fallback = reuseHint(['create_prop'], [item('l', { name: '会开花的树' })], new Set());
  assert.equal(fallback?.itemName, '会开花的树', '无 nameText 回落 name');
});

test('多需求：按 activeAbilities 顺序取第一个命中的', () => {
  const bag = [item('star-1', { mount: 'edge' })];
  // 需求列表里 create_prop 在前但背包无造物 → 跳过；create_sticker 命中贴纸
  const h = reuseHint(['create_prop', 'create_sticker'], bag, new Set());
  assert.equal(h?.itemId, 'star-1');
});

// ── 接线：进世界(world_info) 的 npc_wishes 是否挂上 reuseHint + 本会话去重 ─────────────
function seedChar(store: WorldStore, id: string): void {
  const c: Character = {
    id, worldId: 'w1', isFairy: false, name: id, personality: 'p', voiceId: 'v-' + id,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
}

test('接线：背包旧物 × create_prop 需求 → npc_wishes 挂 reuseHint，同会话第二次进世界去重', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'npc1');
  // 背包放一件造物旧物
  store.upsertItem(item('ladder-1', { worldId: 'w1', name: '梯子' }));
  store.bagAdd('w1', ANON_PLAYER, 'ladder-1');
  // 制造一个 create_prop 的活跃需求（已认领的心愿委托）——pushWishes 会把 task.wishAbility 计入活跃需求
  store.setActiveTask('w1', ANON_PLAYER, {
    id: 't1', type: 'wish', npcId: 'npc1', npcName: 'npc1', stampStyle: 'star', wishAbility: 'create_prop',
  });

  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession()] as const;
  const lastHint = (): unknown => {
    const msgs = sent.filter((m) => m['type'] === 'npc_wishes');
    return msgs.length ? (msgs[msgs.length - 1]!['reuseHint']) : 'NO_PUSH';
  };

  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);
  assert.deepEqual(lastHint(), { itemId: 'ladder-1', itemName: '梯子' }, '首次进世界应挂复用提示');

  sent.length = 0;
  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }), ...rest);
  assert.equal(lastHint(), undefined, '同一会话再进 → 该配对已提过，reuseHint 不再挂（去重）');
});
