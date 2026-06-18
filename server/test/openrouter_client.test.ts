import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OpenRouterClient } from '../src/adapters/openrouter_client.ts';

// kimi-k2.6 默认开启 reasoning（实测 chatText 8.1s vs 关闭后 1.8s）。
// chatText 必须在请求体里禁用 reasoning，否则语音链路两次 LLM 调用会慢到十几秒。
test('chatText 禁用 reasoning（避免 kimi 默认思考拖慢语音链路）', async () => {
  let captured: any = null;
  const orig = globalThis.fetch;
  globalThis.fetch = (async (_url: any, init: any) => {
    captured = JSON.parse(init.body);
    return {
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: 'ok' } }] }),
    } as any;
  }) as any;
  try {
    const client = new OpenRouterClient('test-key');
    await client.chatText('moonshotai/kimi-k2.6', [{ role: 'user', content: 'hi' }]);
  } finally {
    globalThis.fetch = orig;
  }
  assert.ok(captured, '应发出请求');
  assert.deepEqual(captured.reasoning, { enabled: false }, 'chatText 请求体须禁用 reasoning');
});
