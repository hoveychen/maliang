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
import { effectiveAbilities } from '../src/types.ts';

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

// 能力并集（基础集 ∪ 角色自带）已从适配器上移到 voice.ts 的 effectiveAbilities——因为仙子要在
// 那一层减去走动类能力，适配器若再并回 BASE_ABILITIES 就把减掉的又塞了回去。「存量角色只存旧两项
// 也能用新能力」这条保证改由 respondToTranscript 层的用例端到端守（见文件末尾的村民用例）。
test('routeIntent prompt：喂花名册 + 逐条渲染调用方给的能力', async () => {
  const captured: ChatMessage[][] = [];
  const llm = new OpenRouterLLMAdapter(fakeClient('{"kind":"chat","replyText":"你好呀"}', captured), 'm');
  await llm.routeIntent('你好', { ...CTX, abilities: effectiveAbilities({ abilities: CTX.abilities, isFairy: false }) });
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
  await respondToTranscript('w1', 'green', '','你好呀', adapters, store);
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
  const r = await respondToTranscript('w1', 'green', '','小蓝跟我来', adapters, store);
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
  const r = await respondToTranscript('w1', 'green', '','小蓝呀跳一下', adapters, store);
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
  const r = await respondToTranscript('w1', 'green', '','让谁谁挥手', adapters, store);
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
  // 新动作词：长词在前不被同前缀短词误吞（翻跟头≠翻面）
  for (const [say, want] of [['翻个跟头', 'flip'], ['翻面看看', 'paperflip'], ['躺平吧', 'lie_down'], ['把自己拍扁', 'squish']] as const) {
    const a = await llm.routeIntent(say, ctx);
    assert.equal(a.behaviorScript!.commands[0]!.params['action'], want, say);
  }
  const chat = await llm.routeIntent('去找小黄聊天', ctx);
  assert.equal(chat.behaviorScript!.commands[0]!.type, 'chat_with');
  assert.equal(chat.behaviorScript!.commands[0]!.params['character_name'], '小黄');
});

test('world_info：客户端上报地点名 → 存 store → 进意图 prompt', async () => {
  const { handleWsMessage, newVoiceSession } = await import('../src/server.ts');
  const { RateLimiter } = await import('../src/ratelimit.ts');
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿');
  const socket = { send() {} };
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'world_info', worldId: 'w1', locations: ['池塘', '大山', '', 42, '风车'] }),
    createMockAdapters(),
    store,
    new RateLimiter(100, 100),
    'conn1',
    newVoiceSession(),
  );
  assert.deepEqual(store.getLocations('w1'), ['池塘', '大山', '风车'], '非法项应被过滤');

  // 地点名应进 routeIntent 上下文与 prompt
  const ctxs: IntentContext[] = [];
  const base = createMockAdapters();
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
  await respondToTranscript('w1', 'green', '','你好', adapters, store);
  assert.deepEqual(ctxs[0]!.locations, ['池塘', '大山', '风车']);

  const captured: ChatMessage[][] = [];
  const llm = new OpenRouterLLMAdapter(fakeClient('{"kind":"chat","replyText":"好"}', captured), 'm');
  await llm.routeIntent('去池塘', { ...CTX, locations: ['池塘', '大山'] });
  assert.ok(captured[0]![0]!.content.includes('池塘'), '地点名应进 prompt');
});

test('routeIntent prompt：点名指派必须带指令 + 带话用 deliver_message（真机联调修复回归锚）', async () => {
  const captured: ChatMessage[][] = [];
  const llm = new OpenRouterLLMAdapter(fakeClient('{"kind":"chat","replyText":"好"}', captured), 'm');
  await llm.routeIntent('你好', CTX);
  const system = captured[0]![0]!.content;
  assert.ok(system.includes('指令绝不能省'), '点名指派需明示 behaviorScript 照常输出');
  assert.ok(system.includes('不要用 move_to——光走过去话就丢了'), '带话需明示用 deliver_message');
});

// ── 小仙子的能力集：她是贴身随从，不会走动 ────────────────────────────────
// 客户端 _run_behavior 对 is_fairy 早返回，一切移动脚本原地丢弃。所以凡是「要走过去才能做的事」
// 落到她身上都无法兑现：孩子听见「好呀」，人却纹丝不动。根治在源头——这些能力压根不进她的意图 prompt。

test('respondToTranscript：小仙子的意图上下文不含任何需要走动的能力', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const fairy = seedChar(store, 'w1', 'fairy', '小神仙', true);
  fairy.abilities = ['move_to', 'deliver_message', 'create_character', 'create_prop'];
  store.saveCharacter(fairy);
  seedChar(store, 'w1', 'blue', '小蓝');

  const base = createMockAdapters();
  const ctxs: IntentContext[] = [];
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(t: string, ctx: IntentContext): Promise<IntentResult> {
        ctxs.push(ctx);
        return base.llm.routeIntent(t, ctx);
      },
    },
  };
  await respondToTranscript('w1', 'fairy', '', '你好呀', adapters, store);

  const got = ctxs[0]!.abilities;
  for (const a of ['move_to', 'follow', 'stop_follow', 'chat_with', 'deliver_message']) {
    assert.ok(!got.includes(a), `小仙子不该有需要走动的能力 ${a}，实得 [${got.join(', ')}]`);
  }
  // 就地能做的 + 她的看家本领要留着
  for (const a of ['do_action', 'create_character', 'create_prop']) {
    assert.ok(got.includes(a), `小仙子应保留 ${a}`);
  }
});

test('respondToTranscript：普通村民仍拿到基础能力并集（存量角色免迁移）', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'green', '小绿'); // abilities 只存了旧两项

  const base = createMockAdapters();
  const ctxs: IntentContext[] = [];
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async routeIntent(t: string, ctx: IntentContext): Promise<IntentResult> {
        ctxs.push(ctx);
        return base.llm.routeIntent(t, ctx);
      },
    },
  };
  await respondToTranscript('w1', 'green', '', '你好呀', adapters, store);

  const got = ctxs[0]!.abilities;
  for (const a of ['move_to', 'follow', 'stop_follow', 'do_action', 'chat_with', 'deliver_message']) {
    assert.ok(got.includes(a), `村民应拿到基础能力 ${a}`);
  }
});

test('routeIntent prompt：能力清单直接取自 ctx.abilities，不再擅自补回基础集', async () => {
  const captured: ChatMessage[][] = [];
  const llm = new OpenRouterLLMAdapter(fakeClient('{"kind":"chat","replyText":"好"}', captured), 'm');
  // 仙子的能力集（已剔除走动类）进来，prompt 里就不该再冒出 move_to/follow
  await llm.routeIntent('去风车那儿', { ...CTX, abilities: ['do_action', 'create_character', 'create_prop'] });
  const system = captured[0]![0]!.content;
  for (const a of ['move_to=', 'follow=', 'chat_with=', 'deliver_message=']) {
    assert.ok(!system.includes(a), `prompt 不该出现走动能力说明 ${a}`);
  }
  assert.ok(system.includes('do_action='), 'do_action 应在 prompt 里');
});
