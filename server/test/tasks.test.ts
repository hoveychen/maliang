// 奖赏系统任务链路：模板池候选生成、offerTask 发起、四类完成事件判定发奖、
// give 转赠记账与 gift 委托顺带完成、world_info 回 world_state 同步。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { respondToTranscript } from '../src/voice.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { pickTaskCandidate, completeTaskOnEvent, describeTask } from '../src/tasks.ts';
import type { ActiveTask, Character, IntentContext, IntentResult } from '../src/types.ts';

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

test('pickTaskCandidate：按世界现状挑可行类型，字段齐全', () => {
  const store = seedWorld();
  for (let i = 0; i < 20; i++) {
    const t = pickTaskCandidate('w1', 'green', store)!;
    assert.ok(t, '有村民有地点应能出候选');
    assert.equal(t.npcId, 'green');
    assert.equal(t.npcName, '小绿');
    assert.ok(t.rewardId.length > 0);
    assert.ok(['deliver', 'bring', 'visit'].includes(t.type), '空背包不该出 gift');
    if (t.type === 'deliver') assert.ok(t.targetName === '小蓝' && t.message!.length > 0, '带话对象只能是其他村民');
    if (t.type === 'bring') assert.equal(t.targetName, '小蓝');
    if (t.type === 'visit') assert.ok(['池塘', '大山'].includes(t.locationName!));
    assert.ok(describeTask(t).length > 0);
  }
  // 有贴纸后 gift 进入候选池
  store.addSticker('w1', 'flower');
  const types = new Set<string>();
  for (let i = 0; i < 60; i++) types.add(pickTaskCandidate('w1', 'green', store)!.type);
  assert.ok(types.has('gift'), '有贴纸应可能出 gift 委托');
});

test('pickTaskCandidate：有进行中委托/委托人是小神仙/世界空 → 不出候选', () => {
  const store = seedWorld();
  assert.equal(pickTaskCandidate('w1', 'fairy', store), null, '小神仙不发委托');
  store.setActiveTask('w1', pickTaskCandidate('w1', 'green', store));
  assert.equal(pickTaskCandidate('w1', 'green', store), null, '已有进行中委托不再出候选');
  const empty = new WorldStore();
  empty.createWorld('w2');
  seedChar(empty, 'w2', 'solo', '独苗');
  assert.equal(pickTaskCandidate('w2', 'solo', empty), null, '没有其他村民/地点/贴纸出不了任何类型');
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
  const r = await respondToTranscript('w1', 'green', '有什么要帮忙的吗', adapters, store);
  assert.ok(r.task, '回应应带新委托');
  assert.equal(store.getActiveTask('w1')!.id, r.task!.id, '委托应设为进行中');
  // 已有委托后：候选不再给，回应继续携带进行中委托
  const r2 = await respondToTranscript('w1', 'green', '你好', createMockAdapters(), store);
  assert.equal(r2.task!.id, r.task!.id);
});

test('completeTaskOnEvent：四类事件正确匹配，错事件/错参数不动状态', () => {
  const store = seedWorld();
  const mk = (over: Partial<ActiveTask>): ActiveTask => ({
    id: 't', type: 'deliver', npcId: 'green', npcName: '小绿', rewardId: 'star', ...over,
  });
  // deliver：目标名模糊匹配
  store.setActiveTask('w1', mk({ type: 'deliver', targetName: '小蓝', message: 'hi' }));
  assert.equal(completeTaskOnEvent('w1', { kind: 'visit_done', locationName: '池塘' }, store), null, '错类型不完成');
  assert.equal(completeTaskOnEvent('w1', { kind: 'deliver_done', targetName: '小黄' }, store), null, '错对象不完成');
  assert.ok(completeTaskOnEvent('w1', { kind: 'deliver_done', targetName: '小蓝呀' }, store), '模糊名应匹配');
  assert.deepEqual(store.getInventory('w1'), { star: 1 }, '完成发奖励贴纸');
  assert.equal(store.getActiveTask('w1'), null, '完成清委托');
  // bring
  store.setActiveTask('w1', mk({ type: 'bring', targetName: '小蓝' }));
  assert.ok(completeTaskOnEvent('w1', { kind: 'bring_done', targetName: '小蓝' }, store));
  // visit
  store.setActiveTask('w1', mk({ type: 'visit', locationName: '池塘' }));
  assert.ok(completeTaskOnEvent('w1', { kind: 'visit_done', locationName: '池塘' }, store));
  // gift：要对上委托人和贴纸
  store.setActiveTask('w1', mk({ type: 'gift', itemId: 'flower' }));
  assert.equal(completeTaskOnEvent('w1', { kind: 'gift_done', npcId: 'blue', itemId: 'flower' }, store), null, '送错人不完成');
  assert.ok(completeTaskOnEvent('w1', { kind: 'gift_done', npcId: 'green', itemId: 'flower' }, store));
  assert.deepEqual(store.getInventory('w1'), { star: 4 }, '四次完成各得一个 star');
});

test('WS task_event/give_item/world_info：发奖下发、转赠记账写记忆、状态同步', async () => {
  const store = seedWorld();
  store.addSticker('w1', 'flower', 2);
  const sent: Record<string, unknown>[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'c1', newVoiceSession()] as const;

  // world_info → world_state 同步背包
  await handleWsMessage(socket, JSON.stringify({ type: 'world_info', worldId: 'w1', locations: ['池塘'] }), ...rest);
  const ws = sent.find((m) => m['type'] === 'world_state')!;
  assert.deepEqual(ws['inventory'], { flower: 2 });

  // give_item：扣背包+写对方记忆
  await handleWsMessage(socket, JSON.stringify({ type: 'give_item', worldId: 'w1', toCharacterId: 'blue', itemId: 'flower' }), ...rest);
  const gr = sent.find((m) => m['type'] === 'give_result')!;
  assert.equal(gr['ok'], true);
  assert.deepEqual(gr['inventory'], { flower: 1 });
  assert.ok(store.getCharacter('w1', 'blue')!.memory.some((m) => m.includes('🌸')), '受赠 NPC 应记住');
  // 背包不够：ok=false 不动账
  await handleWsMessage(socket, JSON.stringify({ type: 'give_item', worldId: 'w1', toCharacterId: 'blue', itemId: 'gem' }), ...rest);
  assert.equal((sent.filter((m) => m['type'] === 'give_result').at(-1))!['ok'], false);

  // task_event：deliver 委托完成 → task_complete 带奖励与最新背包
  store.setActiveTask('w1', {
    id: 't1', type: 'deliver', npcId: 'green', npcName: '小绿', targetName: '小蓝', message: 'hi', rewardId: 'gem',
  });
  await handleWsMessage(socket, JSON.stringify({ type: 'task_event', worldId: 'w1', kind: 'deliver_done', targetName: '小蓝' }), ...rest);
  const tc = sent.find((m) => m['type'] === 'task_complete')!;
  assert.equal(tc['rewardId'], 'gem');
  assert.equal(tc['rewardGlyph'], '💎');
  assert.deepEqual(tc['inventory'], { flower: 1, gem: 1 });
  assert.equal(store.getActiveTask('w1'), null);

  // gift 委托经 give_item 顺带完成
  store.setActiveTask('w1', {
    id: 't2', type: 'gift', npcId: 'blue', npcName: '小蓝', itemId: 'flower', rewardId: 'candy',
  });
  await handleWsMessage(socket, JSON.stringify({ type: 'give_item', worldId: 'w1', toCharacterId: 'blue', itemId: 'flower' }), ...rest);
  const tc2 = sent.filter((m) => m['type'] === 'task_complete').at(-1)!;
  assert.equal(tc2['rewardId'], 'candy');
  assert.equal(store.getActiveTask('w1'), null);
});

test('mock routeIntent：送贴纸→give 指令、问帮忙→offerTask', async () => {
  const { llm } = createMockAdapters();
  const ctx: IntentContext = {
    characterName: '小绿',
    personality: '温柔',
    abilities: [],
    worldCharacters: [{ id: 'blue', name: '小蓝' }],
    inventory: { flower: 1 },
    taskCandidate: {
      id: 'c1', type: 'visit', npcId: 'green', npcName: '小绿', locationName: '池塘', rewardId: 'star',
    },
  };
  const give = await llm.routeIntent('把花送给小蓝', ctx);
  assert.equal(give.behaviorScript!.commands[0]!.type, 'give');
  assert.deepEqual(give.behaviorScript!.commands[0]!.params, { character_name: '小蓝', item: 'flower' });
  const offer = await llm.routeIntent('有什么要帮忙的吗', ctx);
  assert.equal(offer.offerTask, true);
});
