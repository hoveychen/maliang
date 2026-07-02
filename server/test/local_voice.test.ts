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
