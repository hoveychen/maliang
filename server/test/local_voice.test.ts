import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  resolveSid,
  floatToPcm16,
  hasLocalVoiceModels,
} from '../src/adapters/local.ts';
import { resolveTtsProvider } from '../src/adapters/factory.ts';
import { loadConfig, type Config } from '../src/config.ts';

test('resolveSid：音色名 / 数字 sid / 未知回落 undefined', () => {
  assert.equal(resolveSid('zf_001'), 3); // talk-cli 默认中文女声
  assert.equal(resolveSid('af_maple'), 0);
  assert.equal(resolveSid('zm_100'), 102);
  assert.equal(resolveSid('42'), 42);
  assert.equal(resolveSid('103'), undefined); // 越界数字不放行
  assert.equal(resolveSid('cn-child-default'), undefined); // 游戏内音色 → 调用方回落默认
  assert.equal(resolveSid(''), undefined);
});

// TTS 出的 Float32 → PCM16LE 字节（反向的 pcm16ToFloat 随服务端 ASR 一起退役）。
test('floatToPcm16：小端 16bit + 越界钳制到满幅（不回绕）', () => {
  const bytes = floatToPcm16(new Float32Array([0, 0.5, -0.5]));
  assert.equal(bytes.byteLength, 6);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(view.getInt16(0, true), 0);
  assert.ok(Math.abs(view.getInt16(2, true) - 16384) <= 1);
  assert.ok(Math.abs(view.getInt16(4, true) + 16384) <= 1);
  // 超出 [-1,1] 钳制到满幅而非回绕（回绕会把最响的样本翻成反相噪音）
  const clipped = floatToPcm16(new Float32Array([2, -2]));
  const cv = new DataView(clipped.buffer, clipped.byteOffset, clipped.byteLength);
  assert.equal(cv.getInt16(0, true), 32767);
  assert.equal(cv.getInt16(2, true), -32767);
});

test('hasLocalVoiceModels：目录缺失 → false', () => {
  assert.equal(hasLocalVoiceModels('/nonexistent-path-xyz'), false);
});

// 回归：kokoro 配置带 lang:'zh' 时，英文/括号等非纯中文文本会让 espeak-ng 抛
// "Failed to set eSpeak-ng voice"——异步路径下回调被吞，synthesize 永远不 resolve。
// 需要真模型（fetch-voice-models.sh），CI 无模型时跳过。
test('LocalTTS：英文+全角括号混合文本能在限时内合成（lang 配置回归）', { skip: !hasLocalVoiceModels('models'), timeout: 60000 }, async () => {
  const { LocalTTSAdapter } = await import('../src/adapters/local.ts');
  const tts = new LocalTTSAdapter({ modelsDir: 'models' });
  const blob = await Promise.race([
    tts.synthesize('（mock 回应）你说的是「hello」对吗？', 'cn-child-default'),
    new Promise<never>((_, rej) => setTimeout(() => rej(new Error('synthesize 卡死（>20s 未返回）')), 20000)),
  ]);
  assert.ok(blob.bytes.byteLength > 1000, 'PCM 应非空');
  assert.match(blob.mime, /^audio\/L16;rate=\d+$/);
});

function baseConfig(over: Partial<Config>): Config {
  return {
    ...loadConfig(),
    minimaxApiKey: undefined,
    voiceTtsProvider: 'auto',
    ...over,
  };
}

test('resolveTtsProvider：有 MiniMax key 时 auto 优先 minimax；显式指定不受影响', () => {
  assert.equal(
    resolveTtsProvider(baseConfig({ minimaxApiKey: 'k', voiceModelsDir: '/nonexistent-path-xyz' })),
    'minimax',
  );
  assert.equal(
    resolveTtsProvider(baseConfig({ voiceModelsDir: '/nonexistent-path-xyz' })),
    'mock',
  );
  assert.equal(
    resolveTtsProvider(baseConfig({ minimaxApiKey: 'k', voiceTtsProvider: 'local' })),
    'local', // 显式 local 覆盖 auto 的 minimax 优先
  );
});
