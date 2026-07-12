import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sizeToScale, inferSizeFromText, SIZE_TO_SCALE } from '../src/creation_options.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';

// P1：size → scale 映射（明显档）。见 docs/character-size-design.md。

test('sizeToScale 明显档：small/medium/big → 0.7/1.0/1.4', () => {
  assert.equal(sizeToScale('small'), 0.7);
  assert.equal(sizeToScale('medium'), 1.0);
  assert.equal(sizeToScale('big'), 1.4);
  assert.equal(SIZE_TO_SCALE.small, 0.7);
  assert.equal(SIZE_TO_SCALE.big, 1.4);
});

test('sizeToScale 接受中文标签 小/中/大', () => {
  assert.equal(sizeToScale('小'), 0.7);
  assert.equal(sizeToScale('中'), 1.0);
  assert.equal(sizeToScale('大'), 1.4);
  assert.equal(sizeToScale('迷你'), 0.7);
  assert.equal(sizeToScale('巨大'), 1.4);
});

test('sizeToScale 缺失/非法/大小写 → 回落 1.0（=存量角色不跳变）', () => {
  assert.equal(sizeToScale(undefined), 1.0);
  assert.equal(sizeToScale(null), 1.0);
  assert.equal(sizeToScale(''), 1.0);
  assert.equal(sizeToScale('huge'), 1.0); // 未识别词 → 中号
  assert.equal(sizeToScale('BIG'), 1.4); // 大小写不敏感
  assert.equal(sizeToScale(' small '), 0.7); // 去空白
});

test('inferSizeFromText：大/小关键词确定性推断，噪声词不误伤', () => {
  assert.equal(inferSizeFromText('一只红大的猫'), 'big'); // 引导式汇总描述形态
  assert.equal(inferSizeFromText('一只很小的兔子'), 'small');
  assert.equal(inferSizeFromText('一只巨大的恐龙'), 'big');
  assert.equal(inferSizeFromText('一只普通的小猫'), 'small'); // 「小猫」按 small
  assert.equal(inferSizeFromText('一只红的狗'), 'medium'); // 没提体型 → 中
  // 噪声词：小朋友/小心 里的「小」不当体型
  assert.equal(inferSizeFromText('小朋友想要一只狗'), 'medium');
  assert.equal(inferSizeFromText('大家一起玩的鸟'), 'medium');
});

test('mock designCharacter：体型词经 sizeToScale 落到 spec.scale', async () => {
  const { llm } = createMockAdapters();
  const big = await llm.designCharacter('一只巨大的恐龙', true);
  assert.equal(big.scale, 1.4);
  const small = await llm.designCharacter('一只很小的兔子', true);
  assert.equal(small.scale, 0.7);
  const plain = await llm.designCharacter('一只红的狗', true);
  assert.equal(plain.scale, 1.0);
});
