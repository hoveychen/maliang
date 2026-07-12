// 剧本 ↔ Stage SDK 类型契约：手写剧本必须对着 stage_sdk.d.ts 类型检查通过。
// 校验实现抽到 src/screenplay_check.ts（生成层 screenplay_gen 与本回归共用同一把尺子）。
// 这段校验也是 Plan 2 的把关关卡——LLM 吐出来的脚本先过 checkScreenplay，再进沙箱。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SCREENPLAYS, loadScreenplay } from '../src/screenplays.ts';
import { checkScreenplay } from '../src/screenplay_check.ts';

for (const name of SCREENPLAYS) {
  test(`剧本 ${name} 对 stage_sdk.d.ts 类型检查通过`, () => {
    assert.deepEqual(checkScreenplay(loadScreenplay(name)), []);
  });
}

test('类型检查确实在把关: 用错 SDK 的脚本被拦下', () => {
  // moveTo 收 Spot(地点名/坐标)，不收数字；once('near') 少给 dist。
  const bad = `const a = stage.actors[0];\nawait a.moveTo(42);\n`;
  const diags = checkScreenplay(bad);
  assert.equal(diags.length > 0, true, '错误脚本必须报诊断');
  assert.match(diags.join('\n'), /number/);
});

test('类型检查不认得沙箱外的东西: require/process 直接报错', () => {
  const diags = checkScreenplay(`console.log(process.env.HOME);\n`);
  assert.match(diags.join('\n'), /process/);
});
