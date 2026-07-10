// 引导式造物品（guideProp）的服务端单测：图标库结构、属性累积、done、首轮快捷完成、描述汇总。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { newCreationState } from '../src/types.ts';
import type { CreationState } from '../src/types.ts';
import {
  PROP_CREATION_OPTIONS,
  propOptionsByCategory,
  findPropOption,
  composePropDesc,
} from '../src/prop_creation_options.ts';
import { CREATION_OPTIONS } from '../src/creation_options.ts';

function propState(attrs: Partial<CreationState['attrs']> = {}, turnCount = 0): CreationState {
  const s = newCreationState('prop');
  s.attrs = { traits: [], ...attrs };
  s.turnCount = turnCount;
  return s;
}

// ── 图标库结构 ──────────────────────────────────────────────────────────
test('物品图标库：四类齐全、id 唯一、每类至少 2 项', () => {
  const cats = ['kind', 'color', 'size', 'motion'] as const;
  for (const c of cats) {
    assert.ok(propOptionsByCategory(c).length >= 2, `${c} 至少 2 项`);
  }
  const ids = PROP_CREATION_OPTIONS.map((o) => o.id);
  assert.equal(new Set(ids).size, ids.length, 'id 不重复');
});

test('物品图标库：color/size 复用造角色同 id（共享图标资产、省生成）', () => {
  const charColorSize = CREATION_OPTIONS.filter((o) => o.category === 'color' || o.category === 'size');
  for (const shared of charColorSize) {
    const inProp = findPropOption(shared.id);
    assert.ok(inProp, `造物库应含造角色的 ${shared.id}`);
    assert.equal(inProp!.label, shared.label, `${shared.id} label 应一致`);
  }
});

test('物品图标库：kind/motion 是造物专属新 id（prop_ 前缀，不与造角色 kind 撞）', () => {
  const own = PROP_CREATION_OPTIONS.filter((o) => o.category === 'kind' || o.category === 'motion');
  for (const o of own) {
    assert.ok(o.id.startsWith('prop_'), `${o.id} 应带 prop_ 前缀`);
    // 与造角色库无同 id 冲突
    assert.ok(!CREATION_OPTIONS.some((c) => c.id === o.id), `${o.id} 不该与造角色库撞 id`);
  }
});

// ── guideProp 属性累积与追问 ────────────────────────────────────────────
test('guideProp：首轮说了种类 → 记下 kind，继续追问（未 done）', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideProp(propState(), '我要一个风车');
  assert.equal(r.updatedAttrs?.kind, '风车');
  assert.equal(r.done, false);
  assert.ok((r.optionIds?.length ?? 0) >= 2, '追问应带选项图标');
});

test('guideProp：认颜色/大小/会不会动', async () => {
  const { llm } = createMockAdapters();
  const rc = await llm.guideProp(propState({ kind: '风车' }), '红色的');
  assert.equal(rc.updatedAttrs?.color, '红');
  const rm = await llm.guideProp(propState({ kind: '风车', color: '红' }), '会转圈');
  assert.equal(rm.updatedAttrs?.motion, '会转圈');
});

test('guideProp：种类 + 一项属性 → 攒够即 done，带中文描述', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideProp(propState({ kind: '风车' }), '红色的');
  assert.equal(r.done, true);
  assert.ok(r.description && r.description.includes('风车'), '描述应含种类');
});

test('guideProp：说「就这样」立即 done', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideProp(propState({ kind: '小花' }, 1), '就这样');
  assert.equal(r.done, true);
});

test('guideProp：超轮兜底强制 done', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideProp(propState({}, 5), '嗯');
  assert.equal(r.done, true);
});

// ── 描述汇总 ────────────────────────────────────────────────────────────
test('composePropDesc：属性汇成中文描述，安静不赘述 motion', () => {
  assert.equal(composePropDesc({ traits: [], kind: '风车', color: '红', size: '小', motion: '会转圈' }), '一个红小的风车，会转圈');
  const still = composePropDesc({ traits: [], kind: '小花', motion: '安安静静' });
  assert.ok(!still.includes('安安静静'), '安静的物件不该把「安安静静」写进描述');
});

// ── 造角色路径不受影响（回归锚） ────────────────────────────────────────
test('newCreationState 缺省 goal=character，传 prop 则为 prop', () => {
  assert.equal(newCreationState().goal, 'character');
  assert.equal(newCreationState('prop').goal, 'prop');
});
