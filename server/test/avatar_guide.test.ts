import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { newAvatarGuideState, type AvatarGuideState, type GuideAvatarResult } from '../src/types.ts';
import {
  AVATAR_FORBIDDEN_HEAD,
  avatarDescForbidden,
  AVATAR_ICON_CATEGORIES,
  AVATAR_ICON_PROMPTS,
  AVATAR_OPTIONS,
  avatarOptionsByCategory,
  composeAvatarDesc,
  findAvatarOption,
} from '../src/avatar_options.ts';

// 玩家形象 onboarding P1（docs/onboarding-avatar-redesign-design.md）：
// 选项库结构不变量 + guideAvatar/describeAvatar/refineAvatar 的 mock 确定性行为。

// 模拟 P2 端点做的事：把一轮结果的增量并回 state（供多轮累积测试用）
function apply(state: AvatarGuideState, r: GuideAvatarResult, childInput: string): void {
  const u = r.updatedAttrs;
  if (u) {
    if (u.gender) state.attrs.gender = u.gender;
    if (u.hairstyle) state.attrs.hairstyle = u.hairstyle;
    if (u.outfit) state.attrs.outfit = u.outfit;
    if (u.color) state.attrs.color = u.color;
    if (u.accessory) state.attrs.accessory = u.accessory;
    if (u.motifs) state.attrs.motifs = u.motifs;
    if (u.extras) state.attrs.extras = u.extras;
  }
  if (r.category) state.askedCategories.push(r.category);
  state.dialog.push({ role: 'child', text: childInput, ts: 0 });
  state.dialog.push({ role: 'npc', text: r.replyText, ts: 0 });
  state.turnCount += 1;
}

test('形象选项库：id 唯一、类别覆盖齐全、每类 ≥2 项', () => {
  const ids = AVATAR_OPTIONS.map((o) => o.id);
  assert.equal(new Set(ids).size, ids.length, 'id 必须唯一');
  for (const cat of ['gender', 'hairstyle', 'outfit', 'color', 'motif', 'accessory'] as const) {
    assert.ok(avatarOptionsByCategory(cat).length >= 2, `${cat} 至少 2 个选项`);
  }
  assert.equal(findAvatarOption('av_boy')?.label, '小男生');
});

test('形象图标 prompt：图标类别全覆盖、color 不生成（客户端色块）、无持物措辞', () => {
  for (const cat of AVATAR_ICON_CATEGORIES) {
    for (const o of avatarOptionsByCategory(cat)) {
      const p = AVATAR_ICON_PROMPTS[o.id];
      assert.ok(p && p.length > 0, `图标类别选项 ${o.id} 必须有生图 prompt`);
    }
  }
  for (const o of avatarOptionsByCategory('color')) {
    assert.equal(AVATAR_ICON_PROMPTS[o.id], undefined, `color 选项 ${o.id} 不该有图标 prompt（客户端渲染色块）`);
  }
  for (const [id, p] of Object.entries(AVATAR_ICON_PROMPTS)) {
    assert.ok(!/holding|carrying|hugging/i.test(p), `${id} 图标 prompt 不得有持物措辞`);
  }
});

test('guideAvatar：性别第一问，属性逐轮累积，性别+2项外观即 done', async () => {
  const llm = createMockAdapters().llm;
  const state = newAvatarGuideState('朵朵');

  const r1 = await llm.guideAvatar(state, '');
  assert.equal(r1.done, false);
  assert.equal(r1.category, 'gender', '第一问必须问性别');
  assert.ok((r1.optionIds ?? []).length >= 2);
  apply(state, r1, '');

  const r2 = await llm.guideAvatar(state, '小女生');
  assert.equal(r2.done, false);
  assert.equal(state.attrs.gender, undefined, 'guideAvatar 是纯函数，不自己改 state');
  assert.equal(r2.updatedAttrs?.gender, '小女生');
  apply(state, r2, '小女生');
  assert.equal(state.attrs.gender, '小女生');

  const r3 = await llm.guideAvatar(state, '双马尾');
  assert.equal(r3.done, false, '性别+1项外观还不够');
  apply(state, r3, '双马尾');
  assert.equal(state.attrs.hairstyle, '双马尾');

  const r4 = await llm.guideAvatar(state, '蓬蓬裙');
  assert.equal(r4.updatedAttrs?.outfit, '蓬蓬裙');
  assert.equal(r4.done, true, '性别+2项外观即 done');
});

test('guideAvatar：开放语音优先——非库内原话收进上一轮问的类别，不归一', async () => {
  const llm = createMockAdapters().llm;
  const state = newAvatarGuideState();
  state.attrs.gender = '小男生';
  state.askedCategories = ['gender', 'hairstyle'];
  state.turnCount = 2;

  const r = await llm.guideAvatar(state, '我要会发光的头发');
  assert.equal(r.updatedAttrs?.hairstyle, '我要会发光的头发', '原话进属性，不改写成库里的词');
});

test('guideAvatar：说「就这样」立刻 done；超轮强制 done', async () => {
  const llm = createMockAdapters().llm;
  const early = newAvatarGuideState();
  const r1 = await llm.guideAvatar(early, '就这样');
  assert.equal(r1.done, true, '「就这样」立刻 done（哪怕什么都不知道）');

  const forced = newAvatarGuideState();
  forced.turnCount = 5;
  const r2 = await llm.guideAvatar(forced, '唔……');
  assert.equal(r2.done, true, '超轮强制 done，绝不把孩子拖在问答里');
});

test('guideAvatar：没有 cancelled 语义——「算了」也走 done 而不是反悔', async () => {
  const llm = createMockAdapters().llm;
  const state = newAvatarGuideState();
  const r = await llm.guideAvatar(state, '算了不选了');
  // onboarding 必须产出形象：不耐烦 → done 用已知属性画
  assert.equal((r as { cancelled?: boolean }).cancelled, undefined);
  assert.equal(r.done, true);
});

test('describeAvatar：纯外观描述，双手空着，图案转穿戴，无持物/头顶遮挡措辞', async () => {
  const llm = createMockAdapters().llm;
  const desc = await llm.describeAvatar(
    { gender: '小男生', hairstyle: '短短的头发', outfit: '连帽衫', color: '绿色', motifs: ['小恐龙'], accessory: undefined, extras: [] },
    [],
  );
  assert.ok(desc.includes('小男孩'));
  assert.ok(desc.includes('小恐龙'), '喜好要进描述');
  assert.ok(desc.includes('印着') || desc.includes('图案'), '图案是穿戴元素');
  assert.ok(!avatarDescForbidden(desc), `描述不得有持物/头顶遮挡措辞：${desc}`);
  assert.ok(desc.includes('双手'), '明确双手空着');
  assert.ok(desc.includes('头顶'), '明确头顶留空（贴纸锚点槽）');
});

test('头顶留空判据：帽子/皇冠拦截，连帽衫不误伤', () => {
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('戴着红色的棒球帽'), true);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('头上戴着小皇冠'), true);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('一顶草帽'), true);
  assert.equal(AVATAR_FORBIDDEN_HEAD.test('穿着绿色的恐龙图案连帽衫，兜帽垂在脑后'), false, '连帽衫是穿的不是戴的');
  assert.equal(avatarDescForbidden('抱着一只小熊'), true, '持物判据并入总闸');
});

test('配饰库无任何头顶物（headTop 是贴纸锚点槽，结构不变量）', () => {
  const HEAD_WORDS = /(帽|皇冠|头盔|头纱|发冠)/;
  for (const o of avatarOptionsByCategory('accessory')) {
    assert.ok(!HEAD_WORDS.test(o.label), `配饰 ${o.id}(${o.label}) 不得是头顶物`);
  }
});

test('composeAvatarDesc：属性缺省也能出可用描述（降级链兜底）', () => {
  const empty = composeAvatarDesc({ motifs: [], extras: [] });
  assert.ok(empty.includes('小朋友'));
  assert.ok(!avatarDescForbidden(empty));
  assert.ok(empty.includes('头顶上也没有戴任何东西'), '兜底模板同样头顶留空');
  const girl = composeAvatarDesc({ gender: '小女生', motifs: ['星星', '彩虹'], extras: ['会发光的头发'] });
  assert.ok(girl.includes('小女孩'));
  assert.ok(girl.includes('星星和彩虹'));
  assert.ok(girl.includes('会发光的头发'), '开放语音的 extras 要进描述');
});

test('refineAvatar：保留原描述、并入小朋友点名的修改', async () => {
  const llm = createMockAdapters().llm;
  const before = '一个可爱的小女孩，留着双马尾，穿着粉色的蓬蓬裙';
  const after = await llm.refineAvatar(before, '头发要长一点');
  assert.ok(after.includes(before), 'mock 确定性：原描述整段保留');
  assert.ok(after.includes('头发要长一点'), '小朋友的修改要求要进产物');
});
