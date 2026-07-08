import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OpenRouterClient } from '../src/adapters/openrouter_client.ts';
import {
  OpenRouterOrientationAdapter,
  parseFacing,
} from '../src/adapters/openrouter_orientation.ts';

// 朝向解析：模型偶尔啰嗦（"The character is facing LEFT."），按整词匹配容错。
test('parseFacing 整词匹配，容忍大小写与解释文字', () => {
  assert.equal(parseFacing('LEFT'), 'left');
  assert.equal(parseFacing('right'), 'right');
  assert.equal(parseFacing('The character is facing LEFT.'), 'left');
  assert.equal(parseFacing('FRONT (facing the viewer)'), 'front');
  assert.equal(parseFacing('完全看不懂'), 'unknown');
  // "upright" 不能误配成 right——必须整词
  assert.equal(parseFacing('the pose is upright'), 'unknown');
});

// chatVision 请求体：图以 data URL 内联在 image_url part 里，禁 reasoning。
test('chatVision 请求体带图且禁用 reasoning', async () => {
  let captured: any = null;
  const orig = globalThis.fetch;
  globalThis.fetch = (async (_url: any, init: any) => {
    captured = JSON.parse(init.body);
    return {
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: 'RIGHT' } }] }),
    } as any;
  }) as any;
  try {
    const client = new OpenRouterClient('test-key');
    const answer = await client.chatVision('google/gemini-3.1-flash', 'which way?', {
      bytes: Uint8Array.from([1, 2, 3]),
      mime: 'image/png',
    });
    assert.equal(answer, 'RIGHT');
  } finally {
    globalThis.fetch = orig;
  }
  assert.ok(captured, '应发出请求');
  assert.deepEqual(captured.reasoning, { enabled: false });
  const parts = captured.messages[0].content;
  assert.equal(parts[0].type, 'text');
  assert.equal(parts[1].type, 'image_url');
  assert.ok(String(parts[1].image_url.url).startsWith('data:image/png;base64,'));
});

// 保险丝坏了不能拦主管线：网络失败 → 'unknown' 放行，不抛。
test('detectFacing 网络失败返回 unknown（不阻塞生成）', async () => {
  const orig = globalThis.fetch;
  globalThis.fetch = (async () => {
    throw new Error('boom');
  }) as any;
  try {
    const adapter = new OpenRouterOrientationAdapter(new OpenRouterClient('k'), 'm');
    const facing = await adapter.detectFacing({ bytes: Uint8Array.from([1]), mime: 'image/png' });
    assert.equal(facing, 'unknown');
  } finally {
    globalThis.fetch = orig;
  }
});
