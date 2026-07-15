import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { AVATAR_FORBIDDEN_HEAD } from '../src/avatar_options.ts';
import type { AvatarGuideState, GuideAvatarResult } from '../src/types.ts';

// 生产抽查（2026-07-15）逮到的两个洞的回归测试：
// ① 真 LLM 会无视「就这样」连问 6 轮——终止性必须写死在端点，不靠 LLM 自觉（A1 同款纪律）。
// ② refine 说「想戴大帽子」时 LLM 输出「头顶别着…帽子」——旧判据只盯「戴着…帽」，「别着」漏网。

test('头顶判据：「别着/顶着」等非「戴」措辞也拦；连帽衫/兜帽不误伤', () => {
  // 生产漏网原文
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('头顶别着可爱的小大帽子'), true, '生产漏网用例必须拦住');
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('头上顶着一顶大帽子'), true);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('一顶可爱的小红帽'), true);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('戴着棒球帽'), true);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('头上戴着小皇冠'), true);
  // 不误伤：连帽衫是穿的、兜帽垂在脑后是明确合规措辞
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('穿着绿色的恐龙图案连帽衫'), false);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('连帽衫的兜帽垂在脑后'), false);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('帽兜里绣着小星星'), false);
});

test('avatar-chat 端点：「就这样」确定性收工，LLM 想继续问也拦下', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  // 模拟生产观察到的坏行为：LLM 无视「就这样」永远继续追问
  adapters.llm.guideAvatar = async (_state: AvatarGuideState, _input: string): Promise<GuideAvatarResult> => ({
    replyText: '再选一个嘛！', done: false, question: '再选一个嘛！', category: 'accessory', optionIds: ['av_acc_bow'],
  });
  const app = await buildServer({ adapters, store });
  try {
    const res = await app.inject({
      method: 'POST', url: '/onboarding/avatar-chat',
      payload: {
        childInput: '就这样',
        attrs: { gender: '小女生', hairstyle: '双马尾', color: '粉色', motifs: [], extras: [] },
        askedCategories: ['gender', 'hairstyle', 'color'], turnCount: 3, dialog: [],
      },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { done: boolean; description?: string };
    assert.equal(body.done, true, '「就这样」必须立刻 done——终止性写死在端点，不靠 LLM 自觉');
    assert.ok(body.description && body.description.length > 0, 'done 要带描述');
  } finally {
    await app.close();
  }
});
