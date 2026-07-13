import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';

// onboarding 自我介绍：转写→LLM 提取名字/称呼→TTS 复述确认资产；提取不到名字返回空(客户端多轮重问)。
test('onboarding/intro: extract name and synthesize confirm tts', async () => {
  const dir = join(tmpdir(), 'maliang-test-ob-intro');
  rmSync(dir, { recursive: true, force: true });
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore(dir) });
  try {
    // 直送转写（端侧 ASR 路径）
    const ok = await app.inject({
      method: 'POST',
      url: '/onboarding/intro',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ transcript: '我叫朵朵' }),
    });
    assert.equal(ok.statusCode, 200);
    const r1 = ok.json() as { transcript: string; name: string; confirmTtsAsset?: string };
    assert.equal(r1.name, '朵朵');
    assert.ok(r1.confirmTtsAsset && r1.confirmTtsAsset.length > 0);
    const asset = await app.inject({ method: 'GET', url: `/assets/${r1.confirmTtsAsset}` });
    assert.equal(asset.statusCode, 200);

    // 提取不到名字：name 为空、无确认音频（客户端播预制 retry 重问）
    const miss = await app.inject({
      method: 'POST',
      url: '/onboarding/intro',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ transcript: '今天天气真好' }),
    });
    const r2 = miss.json() as { name: string; confirmTtsAsset?: string };
    assert.equal(r2.name, '');
    assert.equal(r2.confirmTtsAsset ?? '', '');

    // 空转写：直接空结果
    const empty = await app.inject({
      method: 'POST',
      url: '/onboarding/intro',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({}),
    });
    assert.equal((empty.json() as { transcript: string }).transcript, '');

    // 服务端 ASR 已退役：只送音频（无 transcript）不再被识别，返回空结果而不是转写。
    // 识别一律在客户端端侧完成，本路由只认成品文本。
    const audioOnly = await app.inject({
      method: 'POST',
      url: '/onboarding/intro',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ pcmBase64: Buffer.from([0, 0, 0, 0]).toString('base64'), rate: 16000 }),
    });
    const r4 = audioOnly.json() as { transcript: string; name: string };
    assert.equal(r4.transcript, '', '只送音频不再产出转写（服务端不识别）');
    assert.equal(r4.name, '');
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
