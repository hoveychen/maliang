// 奖赏系统任务链路：模板池候选生成、offerTask 发起、三类完成事件判定盖章、
// 完成升花口播、world_info 回 world_state 同步钱包、造物/造角色消费门槛（扣费/拦截/退还）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { respondToTranscript } from '../src/voice.ts';
import { handleWsMessage, newVoiceSession, createPropAsync, createCharacterAsync } from '../src/server.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { pickTaskCandidate, completeTaskOnEvent, describeTask, praiseLine, flowerDeniedLine } from '../src/tasks.ts';
import { ANON_PLAYER, INITIAL_FLOWERS, type ActiveTask, type Character, type IntentContext, type IntentResult } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string, name: string, isFairy = false): Character {
  const c: Character = {
    id,
    worldId,
    isFairy,
    name,
    personality: '活泼开朗',
    voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 },
    abilities: ['move_to', 'deliver_message'],
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function seedWorld(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿');
  seedChar(store, 'w1', 'blue', '小蓝');
  seedChar(store, 'w1', 'fairy', '小神仙', true);
  store.setLocations('w1', ['池塘', '大山']);
  return store;
}

test('pickTaskCandidate：按世界现状挑可行类型，字段齐全（无 gift，带盖章款式）', () => {
  const store = seedWorld();
  const types = new Set<string>();
  for (let i = 0; i < 60; i++) {
    const t = pickTaskCandidate('w1', 'green', ANON_PLAYER, store)!;
    assert.ok(t, '有村民有地点应能出候选');
    assert.equal(t.npcId, 'green');
    assert.equal(t.npcName, '小绿');
    assert.ok(t.stampStyle.length > 0, '应带盖章款式');
    assert.ok(['deliver', 'bring', 'visit'].includes(t.type), '只出 deliver/bring/visit');
    if (t.type === 'deliver') assert.ok(t.targetName === '小蓝' && t.message!.length > 0, '带话对象只能是其他村民');
    if (t.type === 'bring') assert.equal(t.targetName, '小蓝');
    if (t.type === 'visit') assert.ok(['池塘', '大山'].includes(t.locationName!));
    assert.ok(describeTask(t).length > 0);
    types.add(t.type);
  }
  assert.ok(!types.has('gift'), 'gift 委托类型已删除');
});

test('pickTaskCandidate：有进行中委托/委托人是小神仙/世界空 → 不出候选', () => {
  const store = seedWorld();
  assert.equal(pickTaskCandidate('w1', 'fairy', ANON_PLAYER, store), null, '小神仙不发委托');
  store.setActiveTask('w1', ANON_PLAYER, pickTaskCandidate('w1', 'green', ANON_PLAYER, store));
  assert.equal(pickTaskCandidate('w1', 'green', ANON_PLAYER, store), null, '已有进行中委托不再出候选');
  const empty = new WorldStore();
  empty.createWorld('w2');
  seedChar(empty, 'w2', 'solo', '独苗');
  assert.equal(pickTaskCandidate('w2', 'solo', ANON_PLAYER, empty), null, '没有其他村民/地点出不了任何类型');
});

test('respondToTranscript：LLM offerTask → 委托设为进行中并随回应下发', async () => {
  const store = seedWorld();
  const base = createMockAdapters();
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(_t: string, ctx: IntentContext): Promise<IntentResult> {
        assert.ok(ctx.taskCandidate, '无进行中委托时应有候选');
        return { kind: 'chat', replyText: '帮我个忙好不好？', emotion: 'happy', offerTask: true };
      },
    },
  };
  const r = await respondToTranscript('w1', 'green', '', '有什么要帮忙的吗', adapters, store);
  assert.ok(r.task, '回应应带新委托');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER)!.id, r.task!.id, '委托应设为进行中');
  const r2 = await respondToTranscript('w1', 'green', '', '你好', createMockAdapters(), store);
  assert.equal(r2.task!.id, r.task!.id);
});

test('completeTaskOnEvent：三类事件匹配盖章，错事件/错参数不动状态，满 3 升花', () => {
  const store = seedWorld();
  const mk = (over: Partial<ActiveTask>): ActiveTask => ({
    id: 't', type: 'deliver', npcId: 'green', npcName: '小绿', stampStyle: 'star', ...over,
  });
  // deliver：目标名模糊匹配 → 盖第 1 章（未升花）
  store.setActiveTask('w1', ANON_PLAYER, mk({ type: 'deliver', targetName: '小蓝', message: 'hi' }));
  assert.equal(completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'visit_done', locationName: '池塘' }, store), null, '错类型不完成');
  assert.equal(completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'deliver_done', targetName: '小黄' }, store), null, '错对象不完成');
  const r1 = completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'deliver_done', targetName: '小蓝呀' }, store)!;
  assert.ok(r1, '模糊名应匹配');
  assert.equal(r1.flowerGained, false);
  assert.equal(r1.wallet.stampProgress, 1, '盖第 1 章');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null, '完成清委托');
  // bring → 第 2 章
  store.setActiveTask('w1', ANON_PLAYER, mk({ type: 'bring', targetName: '小蓝' }));
  const r2 = completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'bring_done', targetName: '小蓝' }, store)!;
  assert.equal(r2.wallet.stampProgress, 2);
  // visit → 第 3 章 → 升 1 花
  store.setActiveTask('w1', ANON_PLAYER, mk({ type: 'visit', locationName: '池塘' }));
  const r3 = completeTaskOnEvent('w1', ANON_PLAYER, { kind: 'visit_done', locationName: '池塘' }, store)!;
  assert.equal(r3.flowerGained, true, '满 3 章升花');
  assert.equal(r3.wallet.flowers, INITIAL_FLOWERS + 1);
  assert.equal(r3.wallet.stampProgress, 0);
  assert.equal(r3.wallet.stampsTotal, 3);
});

test('praiseLine：升花报喜 / 未升花报进度 / 满仓夸奖（纯中文不含 emoji）', () => {
  const task: ActiveTask = { id: 't', type: 'deliver', npcId: 'g', npcName: '小绿', targetName: '小蓝', stampStyle: 'star' };
  const gained = praiseLine(task, { flowerGained: true, wallet: { flowers: 1, stampProgress: 0, stampsTotal: 3 } });
  assert.ok(gained.includes('小红花'), '升花应报喜');
  const progress = praiseLine(task, { flowerGained: false, wallet: { flowers: 0, stampProgress: 1, stampsTotal: 1 } });
  assert.ok(progress.includes('2'), '未升花应说还差 2 个');
  const full = praiseLine(task, { flowerGained: false, wallet: { flowers: 9, stampProgress: 3, stampsTotal: 30 } });
  assert.ok(full.includes('满'), '满仓应夸满');
  for (const line of [gained, progress, full]) {
    assert.ok(!/[\u{1F300}-\u{1FAFF}⭐]/u.test(line), 'TTS 台词不应含 emoji');
  }
});

test('WS world_info/task_event：world_state 同步钱包，完成盖章 → task_complete 带钱包 + praise_tts', async () => {
  const store = seedWorld();
  store.addStamp('w1', ANON_PLAYER);
  store.addStamp('w1', ANON_PLAYER); // stampProgress=2，下一次完成即升花
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession()] as const;

  // world_info → world_state 同步钱包
  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', locations: ['池塘'] }), ...rest);
  const ws = sent.find((m) => m['type'] === 'world_state')!;
  assert.deepEqual(ws['wallet'], { flowers: INITIAL_FLOWERS, stampProgress: 2, stampsTotal: 2 });

  // task_event：deliver 完成 → task_complete 带盖章款式/升花/最新钱包
  store.setActiveTask('w1', ANON_PLAYER, {
    id: 't1', type: 'deliver', npcId: 'green', npcName: '小绿', targetName: '小蓝', message: 'hi', stampStyle: 'medal',
  });
  await handleWsMessage(socket, JSON.stringify({ type: 'task_event', worldId: 'w1', kind: 'deliver_done', targetName: '小蓝' }), ...rest);
  await new Promise((r) => setTimeout(r, 10)); // praise 后台合成
  const tc = sent.find((m) => m['type'] === 'task_complete')!;
  assert.equal(tc['stampStyle'], 'medal');
  assert.equal(tc['flowerGained'], true, '第 3 章升花');
  assert.deepEqual(tc['wallet'], { flowers: INITIAL_FLOWERS + 1, stampProgress: 0, stampsTotal: 3 });
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null);
  const praise = sent.filter((m) => m['type'] === 'praise_tts');
  assert.equal(praise.length, 1, '完成应推一条表扬语音');
  assert.ok(store.getAsset(String(praise[0]!['ttsAsset'])), '表扬音频应入资产库');
});

test('消费门槛：造物扣 1 花、0 花拦截 prop_denied、造失败退还', async () => {
  const store = seedWorld(); // 初始 3 花
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };

  // 有花：造物成功，扣 1 花，prop_created 带最新钱包
  await createPropAsync(socket, 'w1', ANON_PLAYER, '一棵小树', createMockAdapters(), store);
  const created = sent.find((m) => m['type'] === 'prop_created')!;
  assert.ok(created, '应造出物件');
  assert.equal((created['wallet'] as { flowers: number }).flowers, INITIAL_FLOWERS - 1, '造物扣 1 花');
  assert.equal(store.getWallet('w1', ANON_PLAYER).flowers, INITIAL_FLOWERS - 1);

  // 造失败（审核挡）：退还，账不变
  const blocked = { ...createMockAdapters(), moderation: { async moderateText() { return { allowed: false, reason: 'x' }; } } };
  const before = store.getWallet('w1', ANON_PLAYER).flowers;
  await createPropAsync(socket, 'w1', ANON_PLAYER, '坏东西', blocked as unknown as ReturnType<typeof createMockAdapters>, store);
  assert.ok(sent.some((m) => m['type'] === 'prop_failed'), '应推 prop_failed');
  assert.equal(store.getWallet('w1', ANON_PLAYER).flowers, before, '造失败退还，账不变');

  // 花光后造物：prop_denied，不动账
  store.spendFlower('w1', ANON_PLAYER, before);
  sent.length = 0;
  await createPropAsync(socket, 'w1', ANON_PLAYER, '再来一个', createMockAdapters(), store);
  const denied = sent.find((m) => m['type'] === 'prop_denied')!;
  assert.ok(denied, '0 花应拦截');
  assert.equal(denied['reason'], 'no_flowers');
  assert.equal(denied['message'], flowerDeniedLine());
  assert.equal(store.getWallet('w1', ANON_PLAYER).flowers, 0, '拦截不动账');
});

test('消费门槛：造角色 0 花拦截 gen_denied', async () => {
  const store = seedWorld();
  store.spendFlower('w1', ANON_PLAYER, INITIAL_FLOWERS); // 花光
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  await createCharacterAsync(socket, 'w1', ANON_PLAYER, '一只小猫', createMockAdapters(), store);
  const denied = sent.find((m) => m['type'] === 'gen_denied')!;
  assert.ok(denied, '0 花应拦造角色');
  assert.equal(denied['reason'], 'no_flowers');
  assert.ok(!sent.some((m) => m['type'] === 'gen_complete'), '不应造出角色');
});

test('mock routeIntent：问帮忙→offerTask（give 玩法已删）', async () => {
  const { llm } = createMockAdapters();
  const ctx: IntentContext = {
    characterName: '小绿',
    personality: '温柔',
    abilities: [],
    worldCharacters: [{ id: 'blue', name: '小蓝' }],
    taskCandidate: {
      id: 'c1', type: 'visit', npcId: 'green', npcName: '小绿', locationName: '池塘', stampStyle: 'star',
    },
  };
  const offer = await llm.routeIntent('有什么要帮忙的吗', ctx);
  assert.equal(offer.offerTask, true);
});
