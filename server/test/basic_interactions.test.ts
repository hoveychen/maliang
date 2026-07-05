// 基础交互（跟随/做动作/找人聊天/点名指派）的服务端测试：
// 意图 prompt 喂花名册与新能力、performer 解析、脚本挂到执行者身上。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { OpenRouterLLMAdapter } from '../src/adapters/openrouter_llm.ts';
import type { OpenRouterClient, ChatMessage } from '../src/adapters/openrouter_client.ts';
import { WorldStore } from '../src/persistence.ts';
import { respondToTranscript } from '../src/voice.ts';
import type { Character, IntentContext, IntentResult } from '../src/types.ts';

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
    abilities: ['move_to', 'deliver_message'], // 存量角色只有旧两项，prompt 应取并集
    relationships: {},
  };
  store.addCharacter(c);
  return c;
}

/** 假 OpenRouter 客户端：记录 messages，返回固定 JSON。 */
function fakeClient(reply: string, captured: ChatMessage[][]): OpenRouterClient {
  return {
    async chatText(_model: string, messages: ChatMessage[]) {
      captured.push(messages);
      return reply;
    },
  } as unknown as OpenRouterClient;
}

const CTX: IntentContext = {
  characterName: '小绿',
  personality: '温柔',
  abilities: ['move_to', 'deliver_message'],
  worldCharacters: [
    { id: 'blue', name: '小蓝' },
    { id: 'yellow', name: '小黄' },
  ],
};

test('routeIntent prompt：喂花名册 + 基础能力并集（存量角色只存旧两项也能用新能力）', async () => {
  const captured: ChatMessage[][] = [];
  const llm = new OpenRouterLLMAdapter(fakeClient('{"kind":"chat","replyText":"你好呀"}', captured), 'm');
  await llm.routeIntent('你好', CTX);
  const system = captured[0]![0]!.content;
  assert.ok(system.includes('小蓝') && system.includes('小黄'), '花名册应进 prompt');
  for (const a of ['follow', 'stop_follow', 'do_action', 'chat_with', 'move_to', 'deliver_message']) {
    assert.ok(system.includes(a), `能力 ${a} 应进 prompt`);
  }
});

test('routeIntent：解析 performer（点名让别的角色执行）', async () => {
  const reply = '{"kind":"command","replyText":"我帮你叫小蓝啦！","emotion":"happy","performer":"小蓝",'
    + '"behaviorScript":{"commands":[{"type":"follow","params":{"target_name":"玩家"}}],"loop":false}}';
  const llm = new OpenRouterLLMAdapter(fakeClient(reply, []), 'm');
  const r = await llm.routeIntent('小蓝跟我来', CTX);
  assert.equal(r.kind, 'command');
  assert.equal(r.performerName, '小蓝');
  assert.equal(r.behaviorScript!.commands[0]!.type, 'follow');
});

test('routeIntent：performer 是自己或缺省 → 不设 performerName', async () => {
  const self = '{"kind":"command","replyText":"好！","emotion":"happy","performer":"小绿",'
    + '"behaviorScript":{"commands":[{"type":"do_action","params":{"action":"wave"}}],"loop":false}}';
  const llm = new OpenRouterLLMAdapter(fakeClient(self, []), 'm');
  const r = await llm.routeIntent('挥挥手', CTX);
  assert.equal(r.performerName, undefined, '自己执行不应设 performerName');
});

test('respondToTranscript：花名册进意图上下文（排除自己和小神仙）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿');
  seedChar(store, 'w1', 'blue', '小蓝');
  seedChar(store, 'w1', 'fairy', '小神仙', true);
  const base = createMockAdapters();
  const ctxs: IntentContext[] = [];
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(t: string, ctx: IntentContext) {
        ctxs.push(ctx);
        return base.llm.routeIntent(t, ctx);
      },
    },
  };
  await respondToTranscript('w1', 'green', '你好呀', adapters, store);
  const roster = ctxs[0]!.worldCharacters!;
  assert.deepEqual(roster.map((c) => c.id), ['blue'], '花名册=其他村民，不含自己/小神仙');
});

test('respondToTranscript：点名指派 → performerId 下发、脚本挂执行者而非说话者', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿');
  seedChar(store, 'w1', 'blue', '小蓝');
  const base = createMockAdapters();
  const script = { commands: [{ type: 'follow', params: { target_name: '玩家' } }], loop: false };
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(): Promise<IntentResult> {
        return { kind: 'command', replyText: '我帮你叫小蓝！', emotion: 'happy', performerName: '小蓝', behaviorScript: script };
      },
    },
  };
  const r = await respondToTranscript('w1', 'green', '小蓝跟我来', adapters, store);
  assert.equal(r.performerId, 'blue');
  assert.equal(store.getCharacter('w1', 'blue')!.behaviorScript.commands[0]!.type, 'follow', '脚本应挂到小蓝');
  assert.equal(store.getCharacter('w1', 'green')!.behaviorScript.commands.length, 0, '说话者脚本不应被改');
});

test('respondToTranscript：performer 名字带语气词也能对上（模糊匹配）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿');
  seedChar(store, 'w1', 'blue', '小蓝');
  const base = createMockAdapters();
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(): Promise<IntentResult> {
        return {
          kind: 'command',
          replyText: '好！',
          emotion: 'happy',
          performerName: '小蓝呀',
          behaviorScript: { commands: [{ type: 'do_action', params: { action: 'jump' } }], loop: false },
        };
      },
    },
  };
  const r = await respondToTranscript('w1', 'green', '小蓝呀跳一下', adapters, store);
  assert.equal(r.performerId, 'blue', '「小蓝呀」应模糊对上「小蓝」');
});

test('respondToTranscript：performer 对不上花名册 → 回落说话者执行', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿');
  const base = createMockAdapters();
  const script = { commands: [{ type: 'do_action', params: { action: 'wave' } }], loop: false };
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(): Promise<IntentResult> {
        return { kind: 'command', replyText: '好！', emotion: 'happy', performerName: '不存在的角色', behaviorScript: script };
      },
    },
  };
  const r = await respondToTranscript('w1', 'green', '让谁谁挥手', adapters, store);
  assert.equal(r.performerId, undefined);
  assert.equal(store.getCharacter('w1', 'green')!.behaviorScript.commands[0]!.type, 'do_action', '回落挂说话者');
});

test('mock routeIntent：跟随/停跟/动作/找人聊天启发式（离线开发路径）', async () => {
  const { llm } = createMockAdapters();
  const ctx: IntentContext = { ...CTX };
  const follow = await llm.routeIntent('跟我来', ctx);
  assert.equal(follow.behaviorScript!.commands[0]!.type, 'follow');
  assert.equal(follow.performerName, undefined);
  const named = await llm.routeIntent('小蓝跟我来', ctx);
  assert.equal(named.performerName, '小蓝');
  const stop = await llm.routeIntent('不用跟着我啦', ctx);
  assert.equal(stop.behaviorScript!.commands[0]!.type, 'stop_follow');
  const act = await llm.routeIntent('挥挥手吧', ctx);
  assert.equal(act.behaviorScript!.commands[0]!.type, 'do_action');
  assert.equal(act.behaviorScript!.commands[0]!.params['action'], 'wave');
  const chat = await llm.routeIntent('去找小黄聊天', ctx);
  assert.equal(chat.behaviorScript!.commands[0]!.type, 'chat_with');
  assert.equal(chat.behaviorScript!.commands[0]!.params['character_name'], '小黄');
});
