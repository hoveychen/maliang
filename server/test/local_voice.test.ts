import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  resolveSid,
  floatToPcm16,
  pcm16ToFloat,
  hasLocalVoiceModels,
} from '../src/adapters/local.ts';
import { resolveVoiceProvider } from '../src/adapters/factory.ts';
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

test('floatToPcm16 / pcm16ToFloat：往返一致 + 越界钳制 + 奇数尾字节截断', () => {
  const src = new Float32Array([0, 0.5, -0.5, 1, -1, 0.25]);
  const bytes = floatToPcm16(src);
  assert.equal(bytes.byteLength, src.length * 2);
  const back = pcm16ToFloat(bytes);
  assert.equal(back.length, src.length);
  for (let i = 0; i < src.length; i++) {
    assert.ok(Math.abs(back[i] - src[i]) < 1e-3, `sample ${i}: ${back[i]} vs ${src[i]}`);
  }
  // 超出 [-1,1] 的样本钳制到满幅而非回绕
  const clipped = pcm16ToFloat(floatToPcm16(new Float32Array([2, -2])));
  assert.ok(clipped[0] > 0.99 && clipped[1] < -0.99);
  // 奇数长度字节流：截断最后半个样本，不抛错
  assert.equal(pcm16ToFloat(new Uint8Array(5)).length, 2);
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
  return { ...loadConfig(), xfyunAppId: undefined, xfyunApiKey: undefined, xfyunApiSecret: undefined, ...over };
}

test('resolveVoiceProvider：显式指定优先于 auto 探测', () => {
  assert.equal(resolveVoiceProvider(baseConfig({ voiceProvider: 'mock' })), 'mock');
  assert.equal(resolveVoiceProvider(baseConfig({ voiceProvider: 'xfyun' })), 'xfyun');
  assert.equal(resolveVoiceProvider(baseConfig({ voiceProvider: 'local' })), 'local');
});

test('resolveVoiceProvider：auto 无模型无讯飞 → mock；有讯飞 → xfyun；有模型 → local', () => {
  assert.equal(
    resolveVoiceProvider(baseConfig({ voiceProvider: 'auto', voiceModelsDir: '/nonexistent-path-xyz' })),
    'mock',
  );
  assert.equal(
    resolveVoiceProvider(
      baseConfig({
        voiceProvider: 'auto',
        voiceModelsDir: '/nonexistent-path-xyz',
        xfyunAppId: 'a', xfyunApiKey: 'b', xfyunApiSecret: 'c',
      }),
    ),
    'xfyun',
  );
  // 本地模型已就绪时（开发机跑过 fetch 脚本），auto 应选 local——讯飞凭证在场也优先本地
  if (hasLocalVoiceModels('models')) {
    assert.equal(
      resolveVoiceProvider(
        baseConfig({
          voiceProvider: 'auto', voiceModelsDir: 'models',
          xfyunAppId: 'a', xfyunApiKey: 'b', xfyunApiSecret: 'c',
        }),
      ),
      'local',
    );
  }
});
