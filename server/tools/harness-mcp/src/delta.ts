// 两份状态快照的增量（game-pilot 重写 P4）——与 test/e2e/harness.py 的 diff_state 同形。
// key-absence 有别于值变：cur 有 prev 无 → added；prev 有 cur 无 → removed。
// 对象值用 JSON 串比较（JS === 是引用比较，需深比才与 Python 的 != 语义一致）。
export type State = Record<string, unknown>;

export type Delta = {
  changed: Record<string, [unknown, unknown]>;
  added: Record<string, unknown>;
  removed: Record<string, unknown>;
};

function eq(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  return JSON.stringify(a) === JSON.stringify(b);
}

export function diffState(prev: State | null, cur: State | null): Delta {
  const p = prev ?? {};
  const c = cur ?? {};
  const changed: Record<string, [unknown, unknown]> = {};
  const added: Record<string, unknown> = {};
  const removed: Record<string, unknown> = {};
  for (const k of Object.keys(c)) {
    if (!(k in p)) added[k] = c[k];
    else if (!eq(p[k], c[k])) changed[k] = [p[k], c[k]];
  }
  for (const k of Object.keys(p)) {
    if (!(k in c)) removed[k] = p[k];
  }
  return { changed, added, removed };
}
