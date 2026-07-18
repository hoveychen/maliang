// 拉力层（M1 P3，docs/m1-wish-supply-design.md §2.3）：心愿池空后漏话不再干涸——
// 三选一混合（链步 leak → 小概率通用跑腿引子 ERRAND_LEAKS → 纯氛围 IDLE_DOING），
// 按 characterId+日期哈希稳定轮换；pushWishes entry 扩 ability/source。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { ERRAND_LEAKS, IDLE_DOING, WISH_ABILITIES, WISHES, leakPoolFor, wishFor } from '../src/wishes.ts';
import { pendingChainStep } from '../src/task_chain.ts';
import { ANON_PLAYER, type ChainStep, type Character, type TaskChain } from '../src/types.ts';

const ALL = [...WISH_ABILITIES];

function chainOf(steps: ChainStep[], nextIndex = 0): TaskChain {
  return { steps, nextIndex };
}

const CHAIN_STEPS: ChainStep[] = [
  { type: 'visit', leak: '我想找个好地方…还没去看过呢。', ask: 'a1', thanks: 't1' },
  { type: 'wish', wishAbility: 'create_prop', desire: '一张小桌子', leak: '要是有张小桌子就好啦…', ask: 'a2', thanks: 't2' },
  { type: 'deliver', leak: '消息还没人知道呢…', ask: 'a3', thanks: 't3' },
];

// ── 词库纪律 ────────────────────────────────────────────────────────────

test('ERRAND_LEAKS 词库过自言自语纪律：不出现「你可以/要不要/告诉我」', () => {
  assert.ok(ERRAND_LEAKS.length >= 4, '跑腿引子至少 4 条，别太单调');
  for (const line of ERRAND_LEAKS) {
    assert.ok(!/你可以|要不要|告诉我/.test(line), `广告腔漏话：${line}`);
  }
});

// ── 三选一混合 ──────────────────────────────────────────────────────────

test('一级不动：玩法没发现完时照旧漏心愿（source=wish 带 ability）', () => {
  const pool = leakPoolFor('npc-abc', [], true, null, '2026-07-18');
  const wish = wishFor('npc-abc', [])!;
  assert.deepEqual(pool.lines, wish.leaks);
  assert.equal(pool.source, 'wish');
  assert.equal(pool.ability, wish.ability);
});

test('池空+有待发链步 → 漏该步的 leak（source=chain；wish 步带 ability）', () => {
  const step = pendingChainStep(chainOf(CHAIN_STEPS), true)!;
  const pool = leakPoolFor('npc-abc', ALL, true, step, '2026-07-18');
  assert.deepEqual(pool.lines, [CHAIN_STEPS[0]!.leak]);
  assert.equal(pool.source, 'chain');
  assert.equal(pool.ability, undefined, 'visit 链步没有 ability');

  const wishStep = pendingChainStep(chainOf(CHAIN_STEPS, 1), true)!;
  const pool2 = leakPoolFor('npc-abc', ALL, true, wishStep, '2026-07-18');
  assert.deepEqual(pool2.lines, ['要是有张小桌子就好啦…']);
  assert.equal(pool2.ability, 'create_prop');
});

test('pendingChainStep：买不起时跳过要花的 wish 步；链尽/无链返回 null', () => {
  const broke = pendingChainStep(chainOf(CHAIN_STEPS, 1), false);
  assert.equal(broke?.type, 'deliver', '没花该跳过 create_prop 步，落到 deliver');
  assert.equal(pendingChainStep(chainOf(CHAIN_STEPS, 3), true), null);
  assert.equal(pendingChainStep(undefined, true), null);
});

test('池空无链步 → errand:idle 稳定混合：同一天同一村民不换台，两类都出现', () => {
  const date = '2026-07-18';
  let errand = 0;
  let idle = 0;
  for (let i = 0; i < 300; i++) {
    const pool = leakPoolFor(`npc-${i}`, ALL, true, null, date);
    const again = leakPoolFor(`npc-${i}`, ALL, true, null, date);
    assert.deepEqual(again, pool, '同一天同一村民该稳定拿同一池');
    assert.ok(pool.lines.length > 0, '池空不哑');
    if (pool.source === 'errand') {
      assert.deepEqual(pool.lines, ERRAND_LEAKS);
      errand++;
    } else {
      assert.equal(pool.source, undefined, '纯氛围不算供给信号，不带 source');
      assert.deepEqual(pool.lines, IDLE_DOING);
      idle++;
    }
  }
  // 配比 ≈ 1:2（设计拍的初值）：给宽容带，防哈希分布轻微不均
  assert.ok(errand > 300 * 0.15 && errand < 300 * 0.55, `errand 占比失衡：${errand}/300`);
  assert.ok(idle > 0);
});

test('换一天可以换台：日期进哈希（轮换的是天，不是每次请求）', () => {
  // 300 个村民里至少有一个在两天之间换了台——全都不换说明日期没进哈希
  let changed = false;
  for (let i = 0; i < 300 && !changed; i++) {
    const a = leakPoolFor(`npc-${i}`, ALL, true, null, '2026-07-18');
    const b = leakPoolFor(`npc-${i}`, ALL, true, null, '2026-07-19');
    if (a.source !== b.source) changed = true;
  }
  assert.ok(changed);
});

// ── pushWishes 报文形状 ─────────────────────────────────────────────────

interface WishPush { characterId: string; voiceId: string; lines: string[]; source?: string; ability?: string }

function seedChar(store: WorldStore, id: string, opts: { isFairy?: boolean; taskChain?: TaskChain } = {}): void {
  const c: Character = {
    id, worldId: 'w1', isFairy: opts.isFairy ?? false, name: id, personality: 'p', voiceId: 'v-' + id,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
    taskChain: opts.taskChain,
  };
  store.addCharacter(c);
}

test('npc_wishes 报文：三级供给各带 source/ability，纯氛围不带（客户端清单据此筛卡）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'npc-chain', { taskChain: chainOf(CHAIN_STEPS, 1) }); // 池空后该漏 wish 链步
  seedChar(store, 'npc-plain'); // 池空无链：errand 或 idle
  for (const a of WISH_ABILITIES) store.addDiscovered('w1', ANON_PLAYER, a);

  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession(),
  );
  const msg = sent.filter((m) => m['type'] === 'npc_wishes').at(-1);
  assert.ok(msg, '该下发 npc_wishes');
  const wishes = msg['wishes'] as WishPush[];

  const chainEntry = wishes.find((w) => w.characterId === 'npc-chain')!;
  assert.equal(chainEntry.source, 'chain');
  assert.equal(chainEntry.ability, 'create_prop');
  assert.deepEqual(chainEntry.lines, ['要是有张小桌子就好啦…']);

  const plainEntry = wishes.find((w) => w.characterId === 'npc-plain')!;
  assert.ok(plainEntry.lines.length > 0, '池空不哑');
  if (plainEntry.source === 'errand') assert.deepEqual(plainEntry.lines, ERRAND_LEAKS);
  else {
    assert.equal(plainEntry.source, undefined);
    assert.deepEqual(plainEntry.lines, IDLE_DOING);
  }
});

test('npc_wishes 报文：没发现完时 entry 带 source=wish + ability（A4 清单的数据源）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'npc1');
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: ANON_PLAYER }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession(),
  );
  const wishes = (sent.filter((m) => m['type'] === 'npc_wishes').at(-1)!['wishes']) as WishPush[];
  const entry = wishes.find((w) => w.characterId === 'npc1')!;
  const wish = wishFor('npc1', [])!;
  assert.equal(entry.source, 'wish');
  assert.equal(entry.ability, wish.ability);
  assert.ok(WISHES[entry.ability!], 'ability 必须是心愿库真实键');
});

test('跑腿链步完成（task_event）→ 重发 npc_wishes：清单卡与盖章同拍换下一步', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.setLocations('w1', ['池塘']);
  seedChar(store, 'npc-chain', { taskChain: chainOf(CHAIN_STEPS, 0) }); // 第 0 步是 visit
  for (const a of WISH_ABILITIES) store.addDiscovered('w1', ANON_PLAYER, a);
  // 物化第 0 步为进行中委托（与 pickTaskCandidate 同形状，直接安上省 LLM 环节）
  store.setActiveTask('w1', ANON_PLAYER, {
    id: 't1', type: 'visit', npcId: 'npc-chain', npcName: 'npc-chain', stampStyle: 'star',
    locationName: '池塘', chainNpcId: 'npc-chain', chainIndex: 0, chainStep: CHAIN_STEPS[0],
  });

  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'task_event', worldId: 'w1', kind: 'visit_done', locationName: '池塘' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession(),
  );
  assert.ok(sent.some((m) => m['type'] === 'task_complete'), '该先发 task_complete（盖章）');
  const push = sent.filter((m) => m['type'] === 'npc_wishes').at(-1);
  assert.ok(push, '完成后该重发 npc_wishes');
  const entry = (push['wishes'] as WishPush[]).find((w) => w.characterId === 'npc-chain')!;
  assert.deepEqual(entry.lines, ['要是有张小桌子就好啦…'], '漏话该已换到链的下一步（wish 步）');
  assert.equal(entry.ability, 'create_prop');
});
