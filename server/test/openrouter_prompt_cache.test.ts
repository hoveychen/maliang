import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OpenRouterLLMAdapter } from '../src/adapters/openrouter_llm.ts';
import type { OpenRouterClient, ChatMessage } from '../src/adapters/openrouter_client.ts';

/** 捕获 chatText 入参的假 client（只实现 routeIntent/extractMemory 用到的 chatText）。 */
class FakeClient {
  calls: { messages: ChatMessage[]; opts: Record<string, unknown> }[] = [];
  reply = '{"kind":"chat","replyText":"好呀","emotion":"happy"}';
  async chatText(_model: string, messages: ChatMessage[], opts: Record<string, unknown>): Promise<string> {
    this.calls.push({ messages, opts });
    return this.reply;
  }
}

function makeAdapter(): { adapter: OpenRouterLLMAdapter; fake: FakeClient } {
  const fake = new FakeClient();
  const adapter = new OpenRouterLLMAdapter(fake as unknown as OpenRouterClient, 'test-model');
  return { adapter, fake };
}

test('routeIntent prompt：静态在前/动态在后（缓存前缀稳定）+ 记忆按 kind 分组 + cache/session 透传', async () => {
  const { adapter, fake } = makeAdapter();
  await adapter.routeIntent('你好', {
    characterName: '小兔',
    personality: '活泼',
    abilities: ['move_to'],
    memory: [
      { text: '小朋友叫朵朵', kind: 'identity' },
      { text: '小朋友喜欢恐龙', kind: 'preference' },
      { text: '约好明天搭积木', kind: 'promise' },
    ],
    worldCharacters: [{ id: 'bubble', name: '泡泡' }], // 用静态规则示例里没有的名字，避免 indexOf 命中静态段
    cacheKey: 'w1:c1:p1',
  });
  const sys = fake.calls[0]!.messages.find((m) => m.role === 'system')!.content;
  const boundary = sys.indexOf('当前情况');
  assert.ok(boundary > 0, '应有静/动态边界 marker');
  // 静态内容（输出格式 JSON、角色卡）在边界之前
  assert.ok(sys.indexOf('严格只输出 JSON') < boundary, 'JSON 格式规范应在边界前（静态前缀）');
  assert.ok(sys.indexOf('你是幼儿游戏角色') < boundary, '角色卡应在静态前缀');
  // 动态内容（花名册、记忆）在边界之后
  assert.ok(sys.indexOf('泡泡') > boundary, '花名册应在边界后（动态）');
  assert.ok(sys.indexOf('小朋友叫朵朵') > boundary, '记忆应在边界后（动态）');
  // 记忆按 kind 分组：带中文小标题
  assert.ok(sys.includes('关于这个小朋友：小朋友叫朵朵'), 'identity 应分组');
  assert.ok(sys.includes('小朋友的喜好：小朋友喜欢恐龙'), 'preference 应分组');
  assert.ok(sys.includes('你们的约定：约好明天搭积木'), 'promise 应分组');
  // cache 与 sticky routing 透传
  assert.equal(fake.calls[0]!.opts.cache, true, '应开启 cache_control');
  assert.equal(fake.calls[0]!.opts.sessionId, 'w1:c1:p1', 'session_id 应为稳定缓存键');
});

test('extractMemory prompt：动态内容(对话/已知记忆)在 user 而非 system，system 保持静态 + cache/session 透传', async () => {
  const { adapter, fake } = makeAdapter();
  fake.reply = '{"memories":[]}';
  await adapter.extractMemory({
    characterName: '小兔',
    personality: '活泼',
    turns: [{ child: '我叫朵朵', npc: '你好' }],
    existingMemory: ['小朋友以前说过的事'],
    cacheKey: 'w1:c1:p1',
  });
  const sys = fake.calls[0]!.messages.find((m) => m.role === 'system')!.content;
  const user = fake.calls[0]!.messages.find((m) => m.role === 'user')!.content;
  // 动态内容不得进 system（否则污染缓存前缀）
  assert.ok(!sys.includes('我叫朵朵'), '对话内容不应在 system');
  assert.ok(!sys.includes('小朋友以前说过的事'), '已知记忆不应在 system');
  // 动态内容在 user
  assert.ok(user.includes('我叫朵朵'), '对话应在 user');
  assert.ok(user.includes('小朋友以前说过的事'), '已知记忆应在 user');
  assert.equal(fake.calls[0]!.opts.cache, true);
  assert.equal(fake.calls[0]!.opts.sessionId, 'w1:c1:p1');
});
