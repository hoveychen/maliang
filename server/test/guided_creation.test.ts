import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { newCreationState, type CreationState, type GuideCreationResult } from '../src/types.ts';
import { CREATION_OPTIONS, findOption, optionsByCategory } from '../src/creation_options.ts';

// 模拟 P2 状态机做的事：把一轮结果的增量并回 state（供多轮累积测试用）
function apply(state: CreationState, r: GuideCreationResult): void {
  const u = r.updatedAttrs;
  if (u) {
    if (u.kind) state.attrs.kind = u.kind;
    if (u.color) state.attrs.color = u.color;
    if (u.size) state.attrs.size = u.size;
    if (u.personality) state.attrs.personality = u.personality;
    if (u.name) state.attrs.name = u.name;
    if (u.traits) state.attrs.traits = u.traits;
  }
  if (r.category) state.askedCategories.push(r.category);
  state.turnCount += 1;
}

test('图标库：类别齐全、id 唯一、name 无图标不进库', () => {
  const ids = CREATION_OPTIONS.map((o) => o.id);
  assert.equal(new Set(ids).size, ids.length, 'id 必须唯一');
  assert.ok(optionsByCategory('kind').length >= 2);
  assert.ok(optionsByCategory('color').length >= 2);
  assert.equal(CREATION_OPTIONS.some((o) => o.category === 'name'), false, 'name 走语音，不进图标库');
  assert.equal(findOption('cat')?.label, '猫');
});

test('guideCreation：含糊首句 → 追问 kind + 给合法选项 id', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideCreation(newCreationState(), '我想要一个朋友');
  assert.equal(r.done, false);
  assert.equal(r.category, 'kind');
  assert.ok(r.optionIds && r.optionIds.length >= 2 && r.optionIds.length <= 4);
  // 选项必须都是图标库里 kind 类的真实 id
  for (const id of r.optionIds!) assert.equal(findOption(id)?.category, 'kind');
  assert.ok(r.replyText.length > 0);
});

test('guideCreation：多轮累积 → 攒够(kind+color)即 done + 汇出描述', async () => {
  const { llm } = createMockAdapters();
  const state = newCreationState();
  const r1 = await llm.guideCreation(state, '小猫');       // 给 kind
  apply(state, r1);
  assert.equal(state.attrs.kind, '猫');
  assert.equal(r1.done, false);
  const r2 = await llm.guideCreation(state, '红');         // 给 color → 够了
  apply(state, r2);
  assert.equal(state.attrs.color, '红');
  assert.equal(r2.done, true);
  assert.ok(r2.description && r2.description.includes('猫') && r2.description.includes('红'));
});

test('guideCreation：快捷方式——首句说全 → 首轮即 done', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideCreation(newCreationState(), '一只会飞的红色小猫');
  assert.equal(r.done, true);
  assert.ok(r.description!.includes('猫'));
  assert.ok(r.description!.includes('红'));
  assert.ok(r.description!.includes('会飞'));
});

test('guideCreation：语音名字——问过 name 后自由文本当名字', async () => {
  const { llm } = createMockAdapters();
  // 构造一个已攒够但仍在问名字的状态：kind+color 已有，上一轮问的是 name
  const state: CreationState = {
    active: true,
    attrs: { kind: '猫', color: '红', traits: [] },
    askedCategories: ['name'],
    turnCount: 3,
  };
  const r = await llm.guideCreation(state, '咪咪');
  assert.equal(r.updatedAttrs?.name, '咪咪');
});

test('guideCreation：提前造——说「就这样」立即 done', async () => {
  const { llm } = createMockAdapters();
  const state: CreationState = { active: true, attrs: { kind: '狗', traits: [] }, askedCategories: ['kind'], turnCount: 1 };
  const r = await llm.guideCreation(state, '就这样');
  assert.equal(r.done, true);
});

test('guideCreation：超轮兜底——turnCount 到上限强制 done', async () => {
  const { llm } = createMockAdapters();
  const state: CreationState = { active: true, attrs: { kind: '兔', traits: [] }, askedCategories: ['kind', 'color', 'trait', 'name', 'personality'], turnCount: 5 };
  const r = await llm.guideCreation(state, '嗯');
  assert.equal(r.done, true);
});
