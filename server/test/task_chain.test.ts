// 角色专属委托链（M1 断环修复，docs/m1-wish-supply-design.md §2.1）的地基：
// 生成落库 / LLM 挂了回退模板（确定性）/ 懒生成幂等（含链走完不重生成）/ 产物校验拦脏数据。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { ensureTaskChain, templateChainFor, validateChainSteps, TEMPLATE_CHAINS } from '../src/task_chain.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { createCharacterAsync } from '../src/server.ts';
import { ANON_PLAYER, type ChainStep, type Character } from '../src/types.ts';
import type { LLMAdapter } from '../src/adapters/types.ts';

function seedChar(
  store: WorldStore,
  id: string,
  name: string,
  opts: { isFairy?: boolean; greetingStyle?: string } = {},
): Character {
  const c: Character = {
    id, worldId: 'w1', isFairy: opts.isFairy ?? false, name, personality: '爱笑爱热闹', voiceId: 'v-' + id,
    greetingStyle: opts.greetingStyle,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function freshStore(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  return store;
}

/** 一套合格的 LLM 产物（3 步，围绕「小聚会」主题）。 */
const GOOD_STEPS: ChainStep[] = [
  { type: 'visit', leak: '我想找个办小聚会的好地方…可我还没去看过呢。', ask: '帮我去那个地方看一看好不好？', thanks: '你去看过啦，太好啦！' },
  { type: 'deliver', leak: '聚会的消息还没人知道呢…', ask: '帮我把这句话带过去好不好？', thanks: '消息带到啦，谢谢你！' },
  { type: 'wish', wishAbility: 'create_prop', desire: '一张聚会用的小桌子', leak: '聚会还缺一张小桌子…我自己变不出来呀。', ask: '小桌子的事儿…只有小仙子的魔法帮得上啦。', thanks: '小桌子有啦！聚会成啦！' },
];

/** 只带 designTaskChain 的假 LLM（计数器可查调用次数）。 */
function llmWith(steps: unknown, calls?: { n: number }): LLMAdapter {
  return {
    designTaskChain: async () => {
      if (calls) calls.n++;
      return steps as ChainStep[];
    },
  } as unknown as LLMAdapter;
}

function llmThrows(calls?: { n: number }): LLMAdapter {
  return {
    designTaskChain: async () => {
      if (calls) calls.n++;
      throw new Error('LLM 挂了');
    },
  } as unknown as LLMAdapter;
}

// ── 生成落库 ─────────────────────────────────────────────────────────────

test('生成落库：LLM 产物合格 → taskChain 持久化，nextIndex 从 0 起步', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔');
  const chain = await ensureTaskChain('w1', 'npc1', llmWith(GOOD_STEPS), store);
  assert.ok(chain);
  assert.equal(chain.nextIndex, 0);
  assert.deepEqual(chain.steps, GOOD_STEPS);
  // 重读落库的角色：链真的持久化了（不是只挂在内存对象上）
  const reread = store.getCharacter('w1', 'npc1');
  assert.deepEqual(reread?.taskChain, { steps: GOOD_STEPS, nextIndex: 0 });
});

test('仙子不长链：她是兑现心愿的人，不是许愿的人', async () => {
  const store = freshStore();
  seedChar(store, 'fairy', '点点', { isFairy: true });
  const chain = await ensureTaskChain('w1', 'fairy', llmWith(GOOD_STEPS), store);
  assert.equal(chain, null);
  assert.equal(store.getCharacter('w1', 'fairy')?.taskChain, undefined);
});

// ── 回退确定性 ───────────────────────────────────────────────────────────

test('LLM 挂了回退模板链：按 greetingStyle 落到对应主题，同一角色永远同一套', async () => {
  const storeA = freshStore();
  seedChar(storeA, 'npc1', '小兔', { greetingStyle: 'shy' });
  const a = await ensureTaskChain('w1', 'npc1', llmThrows(), storeA);
  assert.ok(a);
  assert.deepEqual(a.steps, TEMPLATE_CHAINS.shy);

  // 另一个世界、同样设置 → 同一套模板（确定性，不掷骰子）
  const storeB = freshStore();
  seedChar(storeB, 'npc1', '小兔', { greetingStyle: 'shy' });
  const b = await ensureTaskChain('w1', 'npc1', llmThrows(), storeB);
  assert.deepEqual(b?.steps, a.steps);
});

test('LLM 产物不合格（校验不过）→ 同样回退模板链，绝不让角色无链', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔', { greetingStyle: 'warm' });
  const chain = await ensureTaskChain('w1', 'npc1', llmWith([{ type: '???' }]), store);
  assert.deepEqual(chain?.steps, TEMPLATE_CHAINS.warm);
});

test('未显式设 greetingStyle 的角色也稳定落到一套模板（按 id 哈希，两次一致）', () => {
  const c = { id: 'some-legacy-npc', greetingStyle: undefined };
  const a = templateChainFor(c);
  const b = templateChainFor(c);
  assert.deepEqual(a, b);
  assert.ok(a.length >= 3);
});

test('templateChainFor 返回副本：改产物不脏共享模板', () => {
  const c = { id: 'npc-x', greetingStyle: 'gentle' };
  const a = templateChainFor(c);
  a[0]!.leak = '被改了';
  assert.notEqual(TEMPLATE_CHAINS.gentle[0]!.leak, '被改了');
});

test('全部模板链自身必须过校验（自言自语纪律/步数/wish 带 ability）', () => {
  for (const [style, steps] of Object.entries(TEMPLATE_CHAINS)) {
    assert.ok(validateChainSteps(steps), `模板链 ${style} 没过自己的校验`);
  }
});

// ── 懒生成幂等 ───────────────────────────────────────────────────────────

test('懒生成幂等：已有链不重生成，LLM 只调一次', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔');
  const calls = { n: 0 };
  const llm = llmWith(GOOD_STEPS, calls);
  const first = await ensureTaskChain('w1', 'npc1', llm, store);
  const second = await ensureTaskChain('w1', 'npc1', llm, store);
  assert.equal(calls.n, 1);
  assert.deepEqual(second, first);
});

test('链走完（nextIndex 越界）不重生成：链是「见面礼」，不是永动机', async () => {
  const store = freshStore();
  seedChar(store, 'npc1', '小兔');
  await ensureTaskChain('w1', 'npc1', llmWith(GOOD_STEPS), store);
  // 把链走到头
  const c = store.getCharacter('w1', 'npc1')!;
  c.taskChain!.nextIndex = c.taskChain!.steps.length;
  store.saveCharacter(c);
  // 再要供给：不重开一条新链
  const calls = { n: 0 };
  const chain = await ensureTaskChain('w1', 'npc1', llmWith(GOOD_STEPS, calls), store);
  assert.equal(calls.n, 0);
  assert.equal(chain?.nextIndex, chain?.steps.length);
});

// ── 产物校验 ─────────────────────────────────────────────────────────────

test('校验：步数不足 3 → 整链拒绝', () => {
  assert.equal(validateChainSteps(GOOD_STEPS.slice(0, 2)), null);
  assert.equal(validateChainSteps([]), null);
  assert.equal(validateChainSteps('不是数组'), null);
});

test('校验：未知 type / 缺话术 → 整链拒绝', () => {
  const bad = [...GOOD_STEPS.slice(0, 2), { ...GOOD_STEPS[2], type: 'teleport' }];
  assert.equal(validateChainSteps(bad), null);
  const noLeak = [...GOOD_STEPS.slice(0, 2), { ...GOOD_STEPS[2], leak: '' }];
  assert.equal(validateChainSteps(noLeak), null);
});

test('校验：wish 步缺 wishAbility 或 ability 不在心愿库 → 整链拒绝', () => {
  const noAbility = GOOD_STEPS.map((s) => (s.type === 'wish' ? { ...s, wishAbility: undefined } : s));
  assert.equal(validateChainSteps(noAbility), null);
  const badAbility = GOOD_STEPS.map((s) => (s.type === 'wish' ? { ...s, wishAbility: 'fly_to_moon' } : s));
  assert.equal(validateChainSteps(badAbility), null);
});

test('校验：漏话违反自言自语纪律（出现「你可以/要不要/告诉我」）→ 整链拒绝', () => {
  for (const ad of ['你可以帮我找找', '要不要来我家玩', '告诉我你想要什么']) {
    const bad = GOOD_STEPS.map((s, i) => (i === 0 ? { ...s, leak: ad } : s));
    assert.equal(validateChainSteps(bad), null, `广告词漏话没被拦：${ad}`);
  }
});

test('校验：超过 5 步裁到 5；非 wish 步剥掉误带的 wishAbility', () => {
  const seven = [...GOOD_STEPS, ...GOOD_STEPS, GOOD_STEPS[0]];
  const clamped = validateChainSteps(seven);
  assert.equal(clamped?.length, 5);
  const noisy = GOOD_STEPS.map((s) => (s.type === 'visit' ? { ...s, wishAbility: 'create_prop' } : s));
  const cleaned = validateChainSteps(noisy);
  assert.equal(cleaned?.find((s) => s.type === 'visit')?.wishAbility, undefined);
});

// ── createCharacterAsync 接线 ────────────────────────────────────────────

test('造角色落地后自动长链（异步）：新角色自带「见面礼」', async () => {
  const store = freshStore();
  const socket = { send: () => {} };
  await createCharacterAsync(socket, 'w1', ANON_PLAYER, '一只小猫', createMockAdapters(), store);
  const created = store.listCharacters('w1').find((c) => !c.isFairy);
  assert.ok(created, '角色没造出来');
  // 链生成是 fire-and-forget：给事件循环几拍让它落库
  let chain = null;
  for (let i = 0; i < 50 && !chain; i++) {
    await new Promise((r) => setImmediate(r));
    chain = store.getCharacter('w1', created.id)?.taskChain ?? null;
  }
  assert.ok(chain, '造角色后没长出委托链');
  assert.equal(chain.nextIndex, 0);
  assert.ok(chain.steps.length >= 3);
});
