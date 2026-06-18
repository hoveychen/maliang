import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveVcn } from '../src/adapters/xfyun.ts';

const CHILD_VOICE = 'aisbabyxu'; // 讯飞童声，幼儿游戏默认

test('未知/默认音色回落到童声而非成人播音腔 xiaoyan', () => {
  // 角色生成时 voiceId='cn-child-default'（不在已知发音人集合里），
  // 旧实现回落到 xiaoyan（成人女声播音腔，被老板反馈为"系统自带"感）。
  assert.equal(resolveVcn('cn-child-default'), CHILD_VOICE);
  assert.equal(resolveVcn('unknown-voice'), CHILD_VOICE);
});

test('已知发音人原样保留', () => {
  assert.equal(resolveVcn('aisjinger'), 'aisjinger');
  assert.equal(resolveVcn('aisbabyxu'), 'aisbabyxu');
});
