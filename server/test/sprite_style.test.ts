import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildSpritePrompt, SPRITE_STYLE_SUFFIX } from '../src/adapters/sprite_style.ts';

test('buildSpritePrompt 追加统一画风后缀', () => {
  const p = buildSpritePrompt('a small cat wearing a red hat');
  assert.equal(p, `a small cat wearing a red hat. ${SPRITE_STYLE_SUFFIX}`);
});

test('buildSpritePrompt 规整主体末尾标点与空白', () => {
  const p = buildSpritePrompt('  a friendly dragon.  ');
  assert.equal(p, `a friendly dragon. ${SPRITE_STYLE_SUFFIX}`);
});

test('画风后缀锁定动森风格与绿幕抠图约束', () => {
  for (const kw of ['Animal Crossing', 'chibi', '#00FF00', 'full body', 'no shadows']) {
    assert.ok(SPRITE_STYLE_SUFFIX.includes(kw), `缺少关键词: ${kw}`);
  }
});

test('画风后缀锁定纸片贴纸感（粗黑描边+白色贴纸边+扁平上色）', () => {
  for (const kw of ['Paper Mario', 'bold black outline', 'white die-cut sticker border', 'flat cel shading']) {
    assert.ok(SPRITE_STYLE_SUFFIX.includes(kw), `缺少关键词: ${kw}`);
  }
});

test('画风后缀锁定统一朝右（客户端水平翻转做朝左，防螃蟹步）', () => {
  assert.ok(SPRITE_STYLE_SUFFIX.includes('facing right'), '缺少关键词: facing right');
  assert.ok(!SPRITE_STYLE_SUFFIX.includes('facing viewer'), '不应再有 facing viewer（正面立绘会导致左右移动螃蟹步）');
});
