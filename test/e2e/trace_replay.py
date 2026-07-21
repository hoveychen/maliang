#!/usr/bin/env python3
"""trace 回放（game-pilot 重写 P5）：把一段录制的 trace.jsonl 里的命令重发一遍、逐条比对 ok，
做回归——「上次这么点一遍是通的，这次还通吗」。

trace.jsonl 由 h.start_trace(dir) 写：每行 {"t",...}，命令记录含 "cmd"/"reply"，截图记录含 "shot"。
回放只重发 cmd 记录，比对新 reply.ok 与录制时的 reply.ok（命令忠实、非应答忠实——截图/b64 不可重建）。

    python3 test/e2e/trace_replay.py --trace DIR/trace.jsonl [--port 8578]

退出码 = 不匹配条数（0=全对）。
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, HarnessError  # noqa: E402


def load_cmds(trace_path):
    """读 trace.jsonl → 只保留命令记录（含 cmd 键）的 [(cmd, recorded_reply), ...]。纯函数，可单测。"""
    out = []
    with open(trace_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if "cmd" in rec:
                out.append((rec["cmd"], rec.get("reply", {})))
    return out


def replay(h, trace_path, verbose=True):
    """重发录制的命令，比对 ok。返回不匹配条数。"""
    cmds = load_cmds(trace_path)
    mism = 0
    for i, (cmd, want) in enumerate(cmds):
        try:
            got = h.send(cmd, timeout=h.timeout + 15.0)
        except HarnessError as e:
            got = {"ok": False, "error": str(e)}
        want_ok, got_ok = bool(want.get("ok")), bool(got.get("ok"))
        if want_ok != got_ok:
            mism += 1
            if verbose:
                print(f"  ✗ [{i}] {cmd.get('op')} ok {want_ok}→{got_ok}: {got.get('error', '')}", file=sys.stderr)
        elif verbose:
            print(f"  ✓ [{i}] {cmd.get('op')} ok={got_ok}")
    print(f"回放 {len(cmds)} 条命令，{mism} 条不匹配")
    return mism


def main():
    ap = argparse.ArgumentParser(description="game-pilot trace 回放")
    ap.add_argument("--trace", required=True, help="trace.jsonl 路径")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578)
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()
    if not Path(args.trace).exists():
        print(f"trace 不存在: {args.trace}", file=sys.stderr)
        return 2
    h = Harness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=5, delay=1.0)
    except HarnessError as e:
        print(f"连不上: {e}", file=sys.stderr)
        return 2
    try:
        return replay(h, args.trace)
    finally:
        h.close()


if __name__ == "__main__":
    sys.exit(main())
