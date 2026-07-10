// 剧本 ↔ Stage SDK 类型契约：两个手写剧本必须对着 stage_sdk.d.ts 类型检查通过。
// 剧本被主 tsconfig 排除（顶层 await + 全局 stage 不是模块），所以在这里单独起一个
// TS Program 编译：剧本源码包一层 async function 当模块跑，d.ts 提供 stage/cast 全局。
// 这段校验也是 Plan 2 的雏形——LLM 吐出来的脚本先过这一关，再进沙箱。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import ts from 'typescript';
import { SCREENPLAYS, loadScreenplay } from '../src/screenplays.ts';

const DTS = fileURLToPath(new URL('../src/screenplays/stage_sdk.d.ts', import.meta.url));

/** 对着 stage_sdk.d.ts 编译一段剧本源码，返回人类可读的诊断（空数组 = 通过）。 */
function typecheck(code: string): string[] {
  const dir = mkdtempSync(path.join(tmpdir(), 'maliang-screenplay-'));
  const file = path.join(dir, 'screenplay.ts');
  // 顶层 await 只在模块里合法：包一层 async function，并 export {} 让它成为模块。
  writeFileSync(file, `export {};\nasync function __screenplay(): Promise<void> {\n${code}\n}\nvoid __screenplay;\n`);
  try {
    const program = ts.createProgram([DTS, file], {
      target: ts.ScriptTarget.ES2022,
      lib: ['lib.es2022.d.ts'],
      module: ts.ModuleKind.ESNext,
      strict: true,
      noEmit: true,
      types: [], // 剧本沙箱里没有 node 全局
    });
    const src = program.getSourceFile(file)!;
    return ts.getPreEmitDiagnostics(program, src).map((d) => {
      const msg = ts.flattenDiagnosticMessageText(d.messageText, ' ');
      if (d.start === undefined) return msg;
      const { line } = src.getLineAndCharacterOfPosition(d.start);
      return `第 ${line} 行(含包装): ${msg}`;
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

for (const name of SCREENPLAYS) {
  test(`剧本 ${name} 对 stage_sdk.d.ts 类型检查通过`, () => {
    assert.deepEqual(typecheck(loadScreenplay(name)), []);
  });
}

test('类型检查确实在把关: 用错 SDK 的脚本被拦下', () => {
  // moveTo 收 Spot(地点名/坐标)，不收数字；once('near') 少给 dist。
  const bad = `const a = stage.actors[0];\nawait a.moveTo(42);\n`;
  const diags = typecheck(bad);
  assert.equal(diags.length > 0, true, '错误脚本必须报诊断');
  assert.match(diags.join('\n'), /number/);
});

test('类型检查不认得沙箱外的东西: require/process 直接报错', () => {
  const diags = typecheck(`console.log(process.env.HOME);\n`);
  assert.match(diags.join('\n'), /process/);
});
