// 手写剧本库：把 src/screenplays/*.ts 的源码原样读出来交给 ScriptRunner。
// 剧本不是模块（顶层 await + 全局 stage），不能 import，只能当文本读——
// 它们和 LLM 生成的脚本走同一条路：stripTypeScriptTypes → vm 沙箱。
// 类型契约见 src/screenplays/stage_sdk.d.ts。

import { readFileSync } from 'node:fs';

/** 内置手写剧本（Plan 2 的 LLM 生成层上线前的样本 + 回归基线）+ M2 章回剧情《三只小猪》各幕。 */
export const SCREENPLAYS = [
  'hide_and_seek',
  'three_act_play',
  'soccer',
  'eagle_and_chicks',
  'story_pigs_1',
  'story_pigs_2',
  'story_pigs_3',
  'story_pigs_end',
  'story_hood_1',
  'story_hood_end',
  'story_oz_1',
  'story_oz_2',
  'story_oz_end',
] as const;
export type ScreenplayName = (typeof SCREENPLAYS)[number];

const cache = new Map<string, string>();

function read(file: string): string {
  let src = cache.get(file);
  if (src === undefined) {
    src = readFileSync(new URL(`./screenplays/${file}`, import.meta.url), 'utf8');
    cache.set(file, src);
  }
  return src;
}

/** 剧本源码（TS，未剥类型）。 */
export function loadScreenplay(name: ScreenplayName): string {
  return read(`${name}.ts`);
}

/** Stage SDK 的类型声明源码：Plan 2 把它拼进 LLM prompt 当接口契约。 */
export function stageSdkDts(): string {
  return read('stage_sdk.d.ts');
}
