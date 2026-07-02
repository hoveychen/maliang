import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MinimaxTTSAdapter, FallbackTTSAdapter, resolveMinimaxVoice } from '../src/adapters/minimax.ts';
import type { AudioBlob } from '../src/adapters/types.ts';

test('resolveMinimaxVoice：已知音色直用，游戏内 voiceId 回落默认', () => {
  assert.equal(resolveMinimaxVoice('lovely_girl', 'x'), 'lovely_girl');
  assert.equal(resolveMinimaxVoice('cute_boy', 'x'), 'cute_boy');
  assert.equal(resolveMinimaxVoice('cn-child-default', 'lovely_girl'), 'lovely_girl');
});

test('MinimaxTTSAdapter：hex 音频解码 + 请求体（模型/音色/PCM 24k）', async () => {
  let captured: any = null;
  const fakeFetch = (async (_url: any, init: any) => {
    captured = JSON.parse(init.body);
    return {
      ok: true,
      json: async () => ({
        data: { audio: '01020304' },
        base_resp: { status_code: 0, status_msg: 'success' },
      }),
    };
  }) as unknown as typeof fetch;
  const tts = new MinimaxTTSAdapter({ apiKey: 'k', fetchFn: fakeFetch });
  const blob = await tts.synthesize('你好', 'cn-child-default');
  assert.deepEqual(Array.from(blob.bytes), [1, 2, 3, 4]);
  assert.equal(blob.mime, 'audio/L16;rate=24000');
  assert.equal(captured.model, 'speech-2.6-turbo');
  assert.equal(captured.voice_setting.voice_id, 'lovely_girl');
  assert.equal(captured.voice_setting.speed, 1.35); // 默认语速：Boss 试听选定（童声原生偏慢）
  assert.equal(captured.audio_setting.format, 'pcm');
  assert.equal(captured.audio_setting.sample_rate, 24000);
});

test('MinimaxTTSAdapter：API 报错 → throw（带状态码）', async () => {
  const fakeFetch = (async () => ({
    ok: true,
    json: async () => ({ base_resp: { status_code: 1004, status_msg: 'auth failed' } }),
  })) as unknown as typeof fetch;
  const tts = new MinimaxTTSAdapter({ apiKey: 'bad', fetchFn: fakeFetch });
  await assert.rejects(() => tts.synthesize('你好', 'v'), /1004/);
});

test('FallbackTTSAdapter：主失败自动走备用，主成功不碰备用', async () => {
  const ok: AudioBlob = { bytes: new Uint8Array([9]), mime: 'audio/L16;rate=24000' };
  let secondaryCalls = 0;
  const failing = { synthesize: async () => { throw new Error('boom'); } };
  const good = { synthesize: async () => { secondaryCalls++; return ok; } };
  const fb = new FallbackTTSAdapter(failing, good);
  assert.equal((await fb.synthesize('a', 'v')).bytes[0], 9);
  assert.equal(secondaryCalls, 1);

  const primaryOk = { synthesize: async () => ok };
  const fb2 = new FallbackTTSAdapter(primaryOk, good);
  await fb2.synthesize('a', 'v');
  assert.equal(secondaryCalls, 1, '主成功时不应调用备用');
});
