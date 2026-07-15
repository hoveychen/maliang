import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { respondToTranscript } from '../src/voice.ts';
import { pickTaskCandidate } from '../src/tasks.ts';
import type { Character, ActiveTask, IntentContext } from '../src/types.ts';

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

const deliverTask: ActiveTask = {
  id: 't1',
  npcId: 'c1',
  npcName: '小兔',
  stampStyle: 'star',
  type: 'deliver',
  targetName: '小蓝',
  message: '一起来玩吧',
};

// ── mock routeIntent：放弃判定 + guard ──────────────────────────────────

test('mock routeIntent：有进行中委托 + 反悔词 → abandonTask', async () => {
  const { llm } = createMockAdapters();
  const ctx: IntentContext = { characterName: '小兔', personality: '活泼', abilities: ['move_to'], activeTask: deliverTask };
  const r = await llm.routeIntent('这个我不想做了', ctx);
  assert.equal(r.abandonTask, true, '有委托又反悔，该置 abandonTask');
  assert.equal(r.kind, 'chat');
});

test('mock routeIntent：没有进行中委托时，反悔词不误触发放弃（guard）', async () => {
  const { llm } = createMockAdapters();
  const ctx: IntentContext = { characterName: '小兔', personality: '活泼', abilities: ['move_to'] };
  const r = await llm.routeIntent('算了不做了', ctx);
  assert.notEqual(r.abandonTask, true, '没活可放弃，不该置 abandonTask');
});

// ── 集成：respondToTranscript 消费 abandonTask ──────────────────────────

test('respondToTranscript：说「不想做了」→ 清进行中委托 + 置 taskCleared，不回带 task', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1', '小兔');
  store.setActiveTask('w1', 'p1', deliverTask);

  const r = await respondToTranscript('w1', 'c1', 'p1', '我不想做了', createMockAdapters(), store);
  assert.equal(r.taskCleared, true, '放弃后要通知客户端撤提示 chip');
  assert.equal(r.task, undefined, '放弃这一轮不该再把委托回带下去');
  assert.equal(store.getActiveTask('w1', 'p1'), null, '进行中委托应被清掉');
});

test('respondToTranscript：普通闲聊不误清进行中委托（委托照常回带，无 taskCleared）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1', '小兔');
  store.setActiveTask('w1', 'p1', deliverTask);

  const r = await respondToTranscript('w1', 'c1', 'p1', '你今天开心吗', createMockAdapters(), store);
  assert.notEqual(r.taskCleared, true, '闲聊不该清委托');
  assert.ok(r.task, '进行中委托该随回应带下去（断线重连补提示）');
  assert.ok(store.getActiveTask('w1', 'p1'), '闲聊后委托仍在');
});

test('respondToTranscript：放弃优先于「回带进行中委托」——两者不该同时出现', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1', '小兔');
  const task = pickTaskCandidate('w1', 'c1', 'p1', store)!;
  store.setActiveTask('w1', 'p1', task);

  const r = await respondToTranscript('w1', 'c1', 'p1', '不帮他了', createMockAdapters(), store);
  assert.equal(r.taskCleared, true);
  assert.equal(r.task, undefined, 'taskCleared 与 task 互斥');
});
