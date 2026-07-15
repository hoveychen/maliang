import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { AVATAR_FORBIDDEN_DESC } from '../src/avatar_options.ts';
import type { AvatarGuideState } from '../src/types.ts';

// 玩家形象 onboarding P2（docs/onboarding-avatar-redesign-design.md §3.1）：
// 无状态 HTTP 多轮端点 + 档案落库 + /player-sprite refine。

async function makeApp(): Promise<{ app: Awaited<ReturnType<typeof buildServer>>; store: WorldStore }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  return { app, store };
}

type ChatResp = {
  replyText: string;
  done: boolean;
  description?: string;
  question?: string;
  category?: string;
  options?: { id: string; label: string; iconAsset: string }[];
  state: AvatarGuideState;
};

async function chat(app: Awaited<ReturnType<typeof buildServer>>, body: Record<string, unknown>): Promise<ChatResp> {
  const res = await app.inject({ method: 'POST', url: '/onboarding/avatar-chat', payload: body });
  assert.equal(res.statusCode, 200);
  return res.json() as ChatResp;
}

test('avatar-chat：无状态多轮——首轮问性别，state 回带累积，性别+2项外观 done 带描述', async () => {
  const { app } = await makeApp();
  try {
    // 首轮：空状态进
    const r1 = await chat(app, { childInput: '', childName: '朵朵' });
    assert.equal(r1.done, false);
    assert.equal(r1.category, 'gender', '第一问必须问性别');
    assert.ok((r1.options ?? []).length >= 2, '选项卡要带 id+label');
    assert.equal(r1.options![0]!.iconAsset, '', '图标未生成时 iconAsset 空串（客户端回落文字卡）');
    assert.equal(r1.state.turnCount, 1);
    assert.equal(r1.state.childName, '朵朵', 'childName 随 state 回带');

    // 第二轮：客户端把 state 原样带回 + 答性别
    const r2 = await chat(app, { ...r1.state, childInput: '小女生' });
    assert.equal(r2.done, false);
    assert.equal(r2.state.attrs.gender, '小女生', '服务端归并增量进 state');
    assert.ok(r2.state.dialog.length >= 2, '对话累积进 state');

    // 第三、四轮：发型 + 衣服 → done
    const r3 = await chat(app, { ...r2.state, childInput: '双马尾' });
    assert.equal(r3.state.attrs.hairstyle, '双马尾');
    const r4 = await chat(app, { ...r3.state, childInput: '蓬蓬裙' });
    assert.equal(r4.done, true, '性别+2项外观即 done');
    assert.ok(r4.description && r4.description.length > 0, 'done 要带外观描述');
    assert.ok(!AVATAR_FORBIDDEN_DESC.test(r4.description!), `描述不得有持物措辞：${r4.description}`);
    assert.ok(r4.description!.includes('小女孩'));
  } finally {
    await app.close();
  }
});

test('avatar-chat：开放语音原话进属性；图标已生成时 options 带资产 hash', async () => {
  const { app, store } = await makeApp();
  try {
    store.setCreationIcon('av_boy', 'hash_boy_icon');
    const r1 = await chat(app, { childInput: '' });
    const boy = (r1.options ?? []).find((o) => o.id === 'av_boy');
    assert.equal(boy?.iconAsset, 'hash_boy_icon', '生成过的图标要带 hash');

    const r2 = await chat(app, { ...r1.state, childInput: '小男生' });
    assert.equal(r2.category, 'hairstyle');
    const r3 = await chat(app, { ...r2.state, childInput: '我要会发光的头发' });
    assert.equal(r3.state.attrs.hairstyle, '我要会发光的头发', '开放语音原话收进上一轮问的类别，不归一');
  } finally {
    await app.close();
  }
});

test('avatar-chat：不可信输入夹紧——超长/超轮/垃圾类别不炸、必然收敛', async () => {
  const { app } = await makeApp();
  try {
    const r = await chat(app, {
      childInput: 'x'.repeat(9999),
      turnCount: 99999,
      askedCategories: ['hack', 'gender', 42],
      attrs: { gender: 'g'.repeat(500), motifs: Array(99).fill('m'), extras: 'not-array' },
      dialog: Array(99).fill({ role: 'evil', text: 't'.repeat(9999) }),
    });
    assert.equal(r.done, true, 'turnCount 夹紧到上限 → 超轮强制 done');
    assert.ok(r.state.attrs.gender!.length <= 20);
    assert.ok(r.state.attrs.motifs.length <= 6);
    assert.ok(r.state.dialog.length <= 24);
    for (const t of r.state.dialog) assert.ok(t.role === 'child' || t.role === 'npc');
  } finally {
    await app.close();
  }
});

test('onboarding/profile：落库可查、幂等覆盖；缺 playerId 400', async () => {
  const { app, store } = await makeApp();
  try {
    const bad = await app.inject({ method: 'POST', url: '/onboarding/profile', payload: { name: '朵朵' } });
    assert.equal(bad.statusCode, 400);

    const ok = await app.inject({
      method: 'POST', url: '/onboarding/profile',
      payload: {
        playerId: 'p-123', name: '朵朵', nickname: '朵朵',
        attrs: { gender: '小女生', hairstyle: '双马尾', motifs: ['小恐龙'], extras: [] },
        visualDescription: '一个可爱的小女孩……', refineNotes: ['头发要长一点'],
        spriteAsset: 'hash_sprite', createdAt: '2026-07-15T00:00:00Z',
      },
    });
    assert.equal(ok.statusCode, 200);
    const saved = store.getOnboardingProfile('p-123');
    assert.equal(saved?.name, '朵朵');
    assert.equal(saved?.attrs.gender, '小女生');
    assert.deepEqual(saved?.attrs.motifs, ['小恐龙']);
    assert.deepEqual(saved?.refineNotes, ['头发要长一点'], 'refine 原话要落库（个性化金矿）');
    assert.equal(saved?.spriteAsset, 'hash_sprite');

    // 幂等覆盖：重报换形象
    await app.inject({
      method: 'POST', url: '/onboarding/profile',
      payload: { playerId: 'p-123', name: '朵朵', attrs: { gender: '小女生', motifs: [], extras: [] }, spriteAsset: 'hash_v2' },
    });
    assert.equal(store.getOnboardingProfile('p-123')?.spriteAsset, 'hash_v2');
    assert.equal(store.listOnboardingProfiles().length, 1, '同 playerId 覆盖不新增');
  } finally {
    await app.close();
  }
});

test('player-sprite：refineFrom+refineRequest 走 refineAvatar，返回体带最终描述', async () => {
  const { app } = await makeApp();
  try {
    const res = await app.inject({
      method: 'POST', url: '/player-sprite',
      payload: { refineFrom: '一个可爱的小女孩，留着双马尾', refineRequest: '头发要长一点' },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { spriteAsset: string; visualDescription: string };
    assert.ok(body.spriteAsset.length > 0, 'refine 后要真生图');
    assert.ok(body.visualDescription.includes('一个可爱的小女孩，留着双马尾'), '原描述保留');
    assert.ok(body.visualDescription.includes('头发要长一点'), '修改要求并入');
  } finally {
    await app.close();
  }
});

test('player-sprite：普通路径不回归——visualDescription 直生图，返回体新增描述字段', async () => {
  const { app } = await makeApp();
  try {
    const res = await app.inject({
      method: 'POST', url: '/player-sprite',
      payload: { visualDescription: '一个可爱的小男孩，穿着绿色的连帽衫' },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { spriteAsset: string; visualDescription: string };
    assert.ok(body.spriteAsset.length > 0);
    assert.equal(body.visualDescription, '一个可爱的小男孩，穿着绿色的连帽衫');

    const empty = await app.inject({ method: 'POST', url: '/player-sprite', payload: {} });
    assert.equal(empty.statusCode, 400, '无描述仍 400');
  } finally {
    await app.close();
  }
});

test('debug api：玩家详情带 onboarding 档案（additive 字段）+ 档案总表', async () => {
  const { app, store } = await makeApp();
  try {
    store.upsertPlayer({ id: 'p-9', name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉色', spriteAsset: 'h1', createdAt: '' });
    store.saveOnboardingProfile({
      playerId: 'p-9', name: '朵朵', nickname: '朵朵',
      attrs: { gender: '小女生', motifs: ['星星'], extras: [] },
      visualDescription: 'desc', refineNotes: [], spriteAsset: 'h1', createdAt: '',
    });
    const detail = await app.inject({ method: 'GET', url: '/debug/api/players/p-9' });
    assert.equal(detail.statusCode, 200);
    const d = detail.json() as { onboarding: { attrs: { motifs: string[] } } | null };
    assert.deepEqual(d.onboarding?.attrs.motifs, ['星星']);

    const list = await app.inject({ method: 'GET', url: '/debug/api/onboarding-profiles' });
    assert.equal(list.statusCode, 200);
    assert.equal((list.json() as { profiles: unknown[] }).profiles.length, 1);
  } finally {
    await app.close();
  }
});
