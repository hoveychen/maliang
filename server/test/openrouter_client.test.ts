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

// 没有超时的话，LLM 卡住时 chatText 的 await 永不返回 → 整条语音回复挂起 → 客户端一直「思考中」。
test('chatText 超时拒绝（LLM 卡住时不无限挂起）', async () => {
  const orig = globalThis.fetch;
  // fake fetch：模拟卡住的连接——只在 abort 信号触发时拒绝。
  // 用一个 ref'd setTimeout 维持事件循环存活（AbortSignal.timeout 的定时器是 unref 的，
  // 真实场景由网络 socket 维持，测试里需自己撑住，否则事件循环提前 drain）。
  globalThis.fetch = ((_url: any, init: any) =>
    new Promise((_res, rej) => {
      const keep = setTimeout(() => rej(new Error('fake never completes')), 5000);
      init.signal?.addEventListener('abort', () => {
        clearTimeout(keep);
        rej(new DOMException('The operation timed out.', 'TimeoutError'));
      });
    })) as any;
  try {
    const client = new OpenRouterClient('test-key', 60); // 60ms 超时
    await assert.rejects(
      client.chatText('moonshotai/kimi-k2.6', [{ role: 'user', content: 'hi' }]),
      /timeout/i,
      'LLM 卡住时 chatText 应超时拒绝，而非永久等待',
    );
  } finally {
    globalThis.fetch = orig;
  }
});
