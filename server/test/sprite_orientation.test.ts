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
  assert.equal(parseFacing('BAD - multiple characters'), 'bad');
  assert.equal(parseFacing('完全看不懂'), 'unknown');
  // "upright" 不能误配成 right——必须整词
  assert.equal(parseFacing('the pose is upright'), 'unknown');
  // 强制 reasoning 的模型会 leak 出下划线粘连词（线上实测遇到），\b 边界会漏配
  assert.equal(parseFacing('RIGHT_of_thought'), 'right');
});

// chatVision 请求体：图以 data URL 内联在 image_url part 里。
// 不得带 reasoning 字段——gemini-3.5-flash 强制 reasoning，{enabled:false} 会 400（实测）。
test('chatVision 请求体带图且不带 reasoning 字段', async () => {
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
    const answer = await client.chatVision('google/gemini-3.5-flash', 'which way?', {
      bytes: Uint8Array.from([1, 2, 3]),
      mime: 'image/png',
    });
    assert.equal(answer, 'RIGHT');
  } finally {
    globalThis.fetch = orig;
  }
  assert.ok(captured, '应发出请求');
  assert.equal('reasoning' in captured, false, '带 reasoning 字段会被强制 reasoning 的模型 400');
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

// ---------- 管线保险丝（cutout 后检测朝向：左→翻转，正面→重试一次） ----------

import { PNG } from 'pngjs';
import { flipHorizontal } from '../src/adapters/chroma_cutout.ts';
import { generateSprite } from '../src/orchestrator.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import type { ImageBlob, SpriteFacing } from '../src/adapters/types.ts';

/** 2x1 测试图：左像素红、右像素蓝（不透明）。 */
function redBluePng(): ImageBlob {
  const png = new PNG({ width: 2, height: 1 });
  png.data = Buffer.from([255, 0, 0, 255, 0, 0, 255, 255]);
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

function leftPixel(blob: ImageBlob): [number, number, number] {
  const png = PNG.sync.read(Buffer.from(blob.bytes));
  return [png.data[0]!, png.data[1]!, png.data[2]!];
}

test('flipHorizontal 左右像素互换', () => {
  const flipped = flipHorizontal(redBluePng());
  assert.deepEqual(leftPixel(flipped), [0, 0, 255], '翻转后左像素应为蓝');
  const twice = flipHorizontal(flipped);
  assert.deepEqual(leftPixel(twice), [255, 0, 0], '翻两次还原');
});

/** 注入可控 orientation/image 的 mock 组合。 */
function adaptersWithFacing(facings: SpriteFacing[], onImageCall?: () => void) {
  const adapters = createMockAdapters();
  adapters.image = {
    async generateSprite(_desc: string) {
      onImageCall?.();
      return redBluePng();
    },
    async generateIcon(_desc: string) {
      onImageCall?.();
      return redBluePng();
    },
  };
  let i = 0;
  adapters.orientation = {
    async detectFacing(_img: ImageBlob) {
      return facings[Math.min(i++, facings.length - 1)]!;
    },
  };
  return adapters;
}

test('管线：检测到朝左 → 存盘的是水平翻转后的图', async () => {
  const store = new WorldStore();
  const { hash } = await generateSprite(adaptersWithFacing(['left']), 'a cat', store);
  const asset = store.getAsset(hash)!;
  assert.deepEqual(leftPixel(asset), [0, 0, 255], '朝左立绘应被镜像成朝右（左像素变蓝）');
});

test('管线：朝右/unknown 原样放行，只生图一次', async () => {
  for (const f of ['right', 'unknown'] as SpriteFacing[]) {
    let calls = 0;
    const store = new WorldStore();
    const { hash } = await generateSprite(adaptersWithFacing([f], () => calls++), 'a cat', store);
    assert.deepEqual(leftPixel(store.getAsset(hash)!), [255, 0, 0], `${f} 不应翻转`);
    assert.equal(calls, 1, `${f} 不应重试生图`);
  }
});

test('管线：正面 → 重试一次生图；第二张朝左则翻转后采用', async () => {
  let calls = 0;
  const store = new WorldStore();
  const { hash } = await generateSprite(adaptersWithFacing(['front', 'left'], () => calls++), 'a cat', store);
  assert.equal(calls, 2, '正面应触发一次重试');
  assert.deepEqual(leftPixel(store.getAsset(hash)!), [0, 0, 255], '重试图朝左应翻转');
});

test('管线：正面重试仍正面 → 放行不再重试', async () => {
  let calls = 0;
  const store = new WorldStore();
  const { hash } = await generateSprite(adaptersWithFacing(['front', 'front'], () => calls++), 'a cat', store);
  assert.equal(calls, 2, '只重试一次');
  assert.ok(store.getAsset(hash), '仍应产出资产');
});

test('管线：bad（三视图/残图）→ 重试一次；重试合格则采用', async () => {
  let calls = 0;
  const store = new WorldStore();
  const { hash } = await generateSprite(adaptersWithFacing(['bad', 'right'], () => calls++), 'a cat', store);
  assert.equal(calls, 2, 'bad 应触发一次重试');
  assert.deepEqual(leftPixel(store.getAsset(hash)!), [255, 0, 0], '重试图合格原样采用');
});

test('管线：bad 重试仍 front → 优先没被判 bad 的重试图', async () => {
  let calls = 0;
  const store = new WorldStore();
  const { hash } = await generateSprite(adaptersWithFacing(['bad', 'front'], () => calls++), 'a cat', store);
  assert.equal(calls, 2, '只重试一次');
  assert.ok(store.getAsset(hash), '仍应产出资产');
});
