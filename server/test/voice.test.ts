import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { handleVoice, respondToTranscript, accumulateMemory } from '../src/voice.ts';
import type { Character, ExtractedMemory, IntentContext } from '../src/types.ts';

function seedChar(store: WorldStore, worldId: string, id: string): Character {
  const c: Character = {
    id,
    worldId,
    isFairy: false,
    name: '小兔',
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

test('routeIntent mock：闲聊 vs 去某地指令', async () => {
  const { llm } = createMockAdapters();
  const ctx = { characterName: '小兔', personality: '活泼', abilities: ['move_to'] };
  const chat = await llm.routeIntent('你今天开心吗', ctx);
  assert.equal(chat.kind, 'chat');
  const cmd = await llm.routeIntent('去河边玩', ctx);
  assert.equal(cmd.kind, 'command');
  assert.ok(cmd.behaviorScript, '指令应带行为脚本');
});

test('handleVoice 闭环(mock)：转写→意图→TTS→更新对话历史', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', playerId: '', audio: { bytes: new Uint8Array([1, 2, 3]), mime: 'audio/wav' } },
    createMockAdapters(),
    store,
  );
  assert.ok(r.transcript.length > 0);
  assert.ok(r.replyText.length > 0);
  assert.ok(r.ttsAsset.length > 0);
  assert.ok(store.getAsset(r.ttsAsset), 'TTS 音频应落地为资源');
  assert.ok(r.emotion.length > 0);
  assert.equal(store.getCharacter('w1', 'c1')!.chatHistory.length, 2); // child + npc
});

test('handleVoice 不再对回复做文字审核（去掉以改善体验/降一次 LLM 调用）', async () => {
  // 即使审核器一律拦截，语音回复也应原样返回（不再被改写成兜底句）。
  const base = createMockAdapters();
  const adapters = {
    ...base,
    moderation: {
      async moderateText() {
        return { allowed: false, reason: 'always block' };
      },
    },
  };
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', playerId: '', audio: { bytes: new Uint8Array([1]), mime: 'audio/wav' } },
    adapters,
    store,
  );
  assert.notEqual(r.replyText, '我们聊点别的好不好？', '回复不应被文字审核改写');
});

test('handleVoice 指令：去某地 → 带 behaviorScript 且即时生效', async () => {
  const base = createMockAdapters();
  const adapters = {
    ...base,
    asr: {
      async transcribe() {
        return '去河边';
      },
      openStream() {
        return { feed() {}, async finish() { return '去河边'; } };
      },
    },
  };
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', playerId: '', audio: { bytes: new Uint8Array([1]), mime: 'audio/wav' } },
    adapters,
    store,
  );
  assert.ok(r.behaviorScript, '去某地应带行为脚本');
  assert.equal(store.getCharacter('w1', 'c1')!.behaviorScript.commands[0]?.type, 'move_to');
});

test('respondToTranscript：按当前玩家取该 NPC 记忆喂给 routeIntent（跨玩家不串）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const c = seedChar(store, 'w1', 'c1');
  c.chatHistory.push({ role: 'child', text: '我叫朵朵', ts: 0 });
  c.chatHistory.push({ role: 'npc', text: '你好朵朵！', ts: 0 });
  store.saveCharacter(c);
  // 该 NPC 对 p1 与 p2 各有记忆，另有一条未绑定玩家的历史记忆（aboutPlayer=''）。
  store.addMemory('c1', { text: '小朋友叫朵朵', kind: 'identity', aboutPlayer: 'p1', ts: 0 });
  store.addMemory('c1', { text: '小明怕黑', kind: 'preference', aboutPlayer: 'p2', ts: 0 });
  store.addMemory('c1', { text: '大家一起玩过', kind: 'event', aboutPlayer: '', ts: 0 });

  const base = createMockAdapters();
  const calls: IntentContext[] = [];
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(t: string, ctx: IntentContext) {
        calls.push(ctx);
        return base.llm.routeIntent(t, ctx);
      },
    },
  };
  await respondToTranscript('w1', 'c1', 'p1', '你好呀', adapters, store);
  assert.equal(calls.length, 1, 'routeIntent 应被调用一次');
  const ctx = calls[0]!;
  // 只见 p1 的记忆 + 未绑定历史，绝不见 p2 的。
  assert.deepEqual(ctx.memory, ['小朋友叫朵朵', '大家一起玩过'], '应只注入当前玩家的记忆 + 未绑定历史');
  assert.equal(ctx.recentHistory!.length, 2, '近 N 轮历史应进入上下文');
  assert.equal(ctx.recentHistory![0]!.text, '我叫朵朵');
});

test('handleVoice：记忆抽取失败/卡住不阻断角色回复（记忆移出回复关键路径）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const base = createMockAdapters();
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async extractMemory(): Promise<ExtractedMemory[]> {
        throw new Error('LLM down');
      },
    },
  };
  const r = await handleVoice(
    { worldId: 'w1', characterId: 'c1', playerId: '', audio: { bytes: new Uint8Array([1]), mime: 'audio/wav' } },
    adapters,
    store,
  );
  assert.ok(r.replyText.length > 0, '即使记忆抽取失败，角色也应正常回复（不卡在思考中）');
});

test('accumulateMemory：结构化落 memories 表(带 kind) + 去重（后台任务，不在回复路径）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const adapters = createMockAdapters();
  await accumulateMemory('w1', 'c1', 'p1', '我叫朵朵，我喜欢恐龙', '你好呀', adapters, store);
  const mem = store.getMemories('c1', 'p1');
  const byText = new Map(mem.map((m) => [m.text, m]));
  assert.ok(byText.has('小朋友叫朵朵'), '应记住名字');
  assert.equal(byText.get('小朋友叫朵朵')!.kind, 'identity', '名字应归类 identity');
  assert.ok(byText.has('小朋友喜欢恐龙'), '应记住喜好');
  assert.equal(byText.get('小朋友喜欢恐龙')!.kind, 'preference', '喜好应归类 preference');
  // 再来一次同样内容 → 不重复记
  await accumulateMemory('w1', 'c1', 'p1', '我叫朵朵，我喜欢恐龙', '你好呀', adapters, store);
  const mem2 = store.getMemories('c1', 'p1');
  assert.equal(mem2.filter((m) => m.text === '小朋友叫朵朵').length, 1, '同一条记忆不应重复');
});

test('accumulateMemory：记忆按玩家维度隔离（同一 NPC 对不同玩家各记各的）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const adapters = createMockAdapters();
  await accumulateMemory('w1', 'c1', 'p1', '我叫朵朵', '你好呀', adapters, store);
  await accumulateMemory('w1', 'c1', 'p2', '我叫小明', '你好呀', adapters, store);
  // p1 只见自己的名字，见不到 p2 的（反之亦然）。
  assert.deepEqual(store.getMemories('c1', 'p1').map((m) => m.text), ['小朋友叫朵朵']);
  assert.deepEqual(store.getMemories('c1', 'p2').map((m) => m.text), ['小朋友叫小明']);
});
