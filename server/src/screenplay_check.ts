// 剧本类型检查关卡：把一段剧本源码对着 stage_sdk.d.ts 编译，返回人类可读诊断（空数组=通过）。
//
// 这是 Plan 2(screenplay-gen) 的把关核心：LLM 吐出来的脚本先过这一关，过了才剥类型进沙箱。
// 手写剧本的回归校验(server/test/screenplay_typecheck.test.ts)与生成层(server/src/screenplay_gen.ts)
// 共用这一个实现——同一把尺子量手写与生成的脚本。
//
// 契约见 src/screenplays/stage_sdk.d.ts；剧本是「异步函数体」（顶层 await + 全局 stage/cast），
// 不是模块，所以包一层 async function 再编译（与运行时 stage_runner 的包装一致）。

import { fileURLToPath } from 'node:url';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import ts from 'typescript';

const DTS = fileURLToPath(new URL('./screenplays/stage_sdk.d.ts', import.meta.url));

/**
 * 对着 stage_sdk.d.ts 编译一段剧本源码（函数体），返回人类可读诊断（空数组=通过）。
 * 与运行时同构：顶层 await 只在模块里合法，故包一层 async function 并 export {} 成模块，
 * d.ts 提供 stage/cast/console 全局；沙箱里没有 node 全局(types:[])，所以 require/process 会报错。
 */
export function checkScreenplay(code: string): string[] {
  const dir = mkdtempSync(path.join(tmpdir(), 'maliang-screenplay-'));
  const file = path.join(dir, 'screenplay.ts');
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
      // 减去包装的 2 行（export {} + async function 签名），换算回剧本自身的行号，回喂 LLM 时更准。
      return `第 ${Math.max(1, line - 1)} 行: ${msg}`;
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
