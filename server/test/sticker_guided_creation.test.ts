// 引导式造贴纸（guideSticker）的服务端单测：图标库结构、属性累积、done、快捷完成、描述汇总、路由。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { newCreationState } from '../src/types.ts';
import type { CreationState, IntentContext } from '../src/types.ts';
import {
  STICKER_CREATION_OPTIONS,
  stickerOptionsByCategory,
  findStickerOption,
  composeStickerDesc,
} from '../src/sticker_creation_options.ts';
import { CREATION_OPTIONS } from '../src/creation_options.ts';

function stickerState(attrs: Partial<CreationState['attrs']> = {}, turnCount = 0): CreationState {
  const s = newCreationState('sticker');
  s.attrs = { traits: [], ...attrs };
  s.turnCount = turnCount;
  return s;
}

function fairyCtx(): IntentContext {
  return {
    characterName: '小仙子',
    personality: '温柔',
    abilities: ['create_character', 'create_prop', 'create_sticker'],
  };
}

// ── 图标库结构 ──────────────────────────────────────────────────────────
test('贴纸图标库：kind+color 两类齐全、id 唯一、每类至少 2 项', () => {
  for (const c of ['kind', 'color'] as const) {
    assert.ok(stickerOptionsByCategory(c).length >= 2, `${c} 至少 2 项`);
  }
  const ids = STICKER_CREATION_OPTIONS.map((o) => o.id);
  assert.equal(new Set(ids).size, ids.length, 'id 不重复');
});

test('贴纸图标库：color 复用造角色同 id（共享图标资产）', () => {
  const charColor = CREATION_OPTIONS.filter((o) => o.category === 'color');
  for (const shared of charColor) {
    const inSticker = findStickerOption(shared.id);
    assert.ok(inSticker, `贴纸库应含造角色的 ${shared.id}`);
    assert.equal(inSticker!.label, shared.label, `${shared.id} label 应一致`);
  }
});

test('贴纸图标库：kind 图案是造贴纸专属新 id（stk_ 前缀，不与造角色 kind 撞）', () => {
  const own = STICKER_CREATION_OPTIONS.filter((o) => o.category === 'kind');
  assert.ok(own.length >= 2, '至少 2 个图案');
  for (const o of own) {
    assert.ok(o.id.startsWith('stk_'), `${o.id} 应带 stk_ 前缀`);
    assert.ok(!CREATION_OPTIONS.some((c) => c.id === o.id), `${o.id} 不该与造角色库撞 id`);
  }
});

// ── guideSticker 属性累积与追问 ─────────────────────────────────────────
test('guideSticker：首轮说了图案 → 记下 kind，攒够即 done（图案就足够）', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideSticker(stickerState(), '我要一个太阳');
  assert.equal(r.updatedAttrs?.kind, '太阳');
  assert.equal(r.done, true, '有图案即可造');
  assert.ok(r.description && r.description.includes('太阳'), '描述应含图案');
});

test('guideSticker：什么都没说 → 追问图案，带选项图标', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideSticker(stickerState(), '嗯');
  assert.equal(r.done, false);
  assert.equal(r.category, 'kind');
  assert.ok((r.optionIds?.length ?? 0) >= 2, '追问应带选项图标');
});

test('guideSticker：认颜色', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideSticker(stickerState(), '红色的');
  assert.equal(r.updatedAttrs?.color, '红');
});

test('guideSticker：说「就这样」立即 done', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideSticker(stickerState({}, 1), '就这样');
  assert.equal(r.done, true);
});

test('guideSticker：反悔说「算了」→ cancelled，不 done', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.guideSticker(stickerState({ kind: '太阳' }), '算了不要了');
  assert.equal(r.cancelled, true);
  assert.equal(r.done, false);
});

// ── 描述汇总 & designSticker ─────────────────────────────────────────────
test('composeStickerDesc：图案+颜色汇成中文描述', () => {
  assert.equal(composeStickerDesc({ traits: [], kind: '太阳', color: '红' }), '一个红的太阳贴纸');
});

test('designSticker：中文描述 → 贴纸名 + 英文生图 prompt', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.designSticker('一个红的太阳贴纸');
  assert.ok(r.name.includes('太阳'), 'name 应含图案');
  assert.ok(/sun/i.test(r.prompt), 'prompt 应是英文生图描述');
});

// ── 路由：仙子听到「贴纸」→ create_sticker（不误归造物/造角色） ──────────
test('routeIntent：仙子「做个太阳贴纸」→ create_sticker 命令', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.routeIntent('做个太阳贴纸', fairyCtx());
  assert.equal(r.kind, 'command');
  assert.equal(r.behaviorScript?.commands[0].type, 'create_sticker');
});

test('routeIntent：无 create_sticker 能力时「贴纸」不误触发造贴纸', async () => {
  const { llm } = createMockAdapters();
  const r = await llm.routeIntent('做个太阳贴纸', {
    characterName: '村民', personality: '普通', abilities: ['move_to'],
  });
  assert.notEqual(r.behaviorScript?.commands?.[0]?.type, 'create_sticker');
});

// ── 造角色/造物路径不受影响（回归锚） ──────────────────────────────────
test('newCreationState 支持 sticker goal，缺省仍 character', () => {
  assert.equal(newCreationState().goal, 'character');
  assert.equal(newCreationState('sticker').goal, 'sticker');
});
