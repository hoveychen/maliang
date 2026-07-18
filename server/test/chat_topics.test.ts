import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pickChatTopics } from '../src/chat_topics.ts';
import type { MemoryKind, PlayerOnboardingProfile } from '../src/types.ts';

function profile(overrides: Partial<PlayerOnboardingProfile> = {}): PlayerOnboardingProfile {
  return {
    playerId: 'p1', name: '朵朵', nickname: '朵朵',
    attrs: { gender: '小女生', color: '粉色', motifs: ['小恐龙', '星星'], extras: [] },
    visualDescription: 'd', refineNotes: [], spriteAsset: 'h', createdAt: '',
    ...overrides,
  };
}
const mem = (...texts: string[]) => texts.map((text) => ({ text, kind: 'preference' as MemoryKind }));

test('村民得「了解型」开放话题（借机问喜好）', () => {
  const topics = pickChatTopics({ isFairy: false, profile: undefined, memory: [] });
  assert.ok(topics.length >= 1 && topics.length <= 2, '返回 1–2 个');
  assert.ok(topics.some((t) => t.includes('喜欢') || t.includes('名字')), '是了解型开放问题');
});

test('点点得「已知型」话题——基于已知喜好（图案/颜色）', () => {
  const topics = pickChatTopics({ isFairy: true, profile: profile(), memory: [] });
  const joined = topics.join('｜');
  assert.ok(joined.includes('小恐龙') || joined.includes('星星') || joined.includes('粉色'), '话题带上已知喜好');
});

test('点点没 profile 时回落到了解型（也有话聊）', () => {
  const topics = pickChatTopics({ isFairy: true, profile: undefined, memory: [] });
  assert.ok(topics.length >= 1, '不空');
});

test('记忆里已聊过的话题被排除（问过就不再重复问）', () => {
  // memory 已含「动物」→ 「问最喜欢什么小动物」这条应被排除。
  const withAnimal = pickChatTopics({
    isFairy: false, profile: undefined,
    memory: mem('小朋友最喜欢的小动物是小猫'), // 含「动物」key
  });
  assert.ok(!withAnimal.some((t) => t.includes('小动物')), '已聊过的小动物话题被排除');
});

test('轮换：记忆条数不同→话题起点错开（同一状态不总是同两条）', () => {
  const t0 = pickChatTopics({ isFairy: false, profile: undefined, memory: [] });
  const t1 = pickChatTopics({ isFairy: false, profile: undefined, memory: mem('x') });
  assert.notDeepEqual(t0, t1, '不同记忆条数下话题错开');
});
