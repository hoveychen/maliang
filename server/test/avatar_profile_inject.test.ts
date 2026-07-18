import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer } from '../src/server.ts';
import { respondToTranscript } from '../src/voice.ts';
import { WorldStore } from '../src/persistence.ts';
import { onboardingProfileNote } from '../src/avatar_options.ts';
import type { IntentContext, PlayerOnboardingProfile } from '../src/types.ts';

// P5 喜好接线（docs/onboarding-avatar-redesign-design.md §2.5）：
// 世界会话按 playerId 查 onboarding 档案 → 摘要注入对话类 LLM 的 IntentContext.childProfile。

function profile(overrides: Partial<PlayerOnboardingProfile> = {}): PlayerOnboardingProfile {
  return {
    playerId: 'p1', name: '朵朵', nickname: '朵朵',
    attrs: { gender: '小女生', color: '粉色', motifs: ['小恐龙', '星星'], extras: ['我要会发光的头发'] },
    visualDescription: 'desc', refineNotes: ['头发要长一点'], spriteAsset: 'h', createdAt: '',
    ...overrides,
  };
}

test('onboardingProfileNote：称呼/图案/主色/原话/refine 全进摘要；无料返回 undefined', () => {
  const note = onboardingProfileNote(profile())!;
  assert.ok(note.includes('朵朵'));
  assert.ok(note.includes('小恐龙、星星'));
  assert.ok(note.includes('粉色'));
  assert.ok(note.includes('我要会发光的头发'));
  assert.ok(note.includes('头发要长一点'));
  assert.equal(onboardingProfileNote(undefined), undefined, '无档案不注入');
  assert.equal(
    onboardingProfileNote(profile({ name: '', nickname: '', refineNotes: [], attrs: { motifs: [], extras: [] } })),
    undefined,
    '空档案不注入（老玩家一个字节都不多花）',
  );
});

test('respondToTranscript：有档案注入 childProfile，无档案不注入', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  const app = await buildServer({ adapters, store });
  try {
    await app.inject({ method: 'GET', url: '/worlds/default' }); // 种默认世界（含点点与村民）
    const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
    // 包一层 routeIntent 抓 ctx（mock 行为不变，只旁路观察）。用数组存以绕开
    // TS 对「赋 null 后经 await 被回调改写」的控制流窄化（会把 captured 判成 never）。
    const captured: IntentContext[] = [];
    const origRoute = adapters.llm.routeIntent.bind(adapters.llm);
    adapters.llm.routeIntent = async (transcript, ctx) => {
      captured.push(ctx);
      return origRoute(transcript, ctx);
    };

    store.saveOnboardingProfile(profile());
    await respondToTranscript('default', fairy.id, 'p1', '你好呀', adapters, store);
    assert.equal(captured.length, 1, 'routeIntent 被调用');
    assert.ok(captured[0]!.childProfile!.includes('小恐龙'), '点点的 prompt ctx 带上喜好摘要');

    await respondToTranscript('default', fairy.id, 'p-nobody', '你好呀', adapters, store);
    assert.equal(captured[1]!.childProfile, undefined, '无档案玩家不注入');
    // 注：childProfile 现在做了信息不对称——只对点点注入，村民恒 undefined（靠聊积累）。
    // 村民侧的断言见 player_awareness_inject.test.ts。
  } finally {
    await app.close();
  }
});
