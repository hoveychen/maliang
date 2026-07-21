#!/usr/bin/env python3
"""monkey 脚本 runner（game-pilot 重写 P5）：跑一个暴露 run(h) 的 .py 脚本，统一提供连接、trace、
计时、pass/fail。让 AI「摸索出交互后写下来做回归」——脚本是真 Python（带条件/循环/断言），可重跑。

    python3 test/e2e/pilot_runner.py --script test/e2e/pilot_example.py [--port 8578] [--trace DIR]

脚本约定：模块级 def run(h): ...  —— h 是已连上的 Harness；抛 HarnessError/AssertionError = 失败。
退出码：0 通过、1 失败、2 用法/加载错。
"""
import argparse
import importlib.util
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, HarnessError  # noqa: E402


def load_run(script_path):
    """加载脚本模块，返回其 run 函数。缺 run → SystemExit(2)。"""
    p = Path(script_path)
    if not p.exists():
        raise SystemExit(f"[runner] 脚本不存在: {script_path}")
    spec = importlib.util.spec_from_file_location("pilot_script", str(p))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["pilot_script"] = mod
    spec.loader.exec_module(mod)
    fn = getattr(mod, "run", None)
    if not callable(fn):
        raise SystemExit(f"[runner] {script_path} 没有 run(h) 函数")
    return fn


def main():
    ap = argparse.ArgumentParser(description="game-pilot monkey 脚本 runner")
    ap.add_argument("--script", required=True, help="暴露 run(h) 的 .py 脚本")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578)
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--trace", default="", help="trace 目录（命令+应答+截图落 trace.jsonl）")
    args = ap.parse_args()

    try:
        run = load_run(args.script)
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 2

    h = Harness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=5, delay=1.0)
    except HarnessError as e:
        print(f"[runner] 连不上: {e}", file=sys.stderr)
        return 1
    if args.trace:
        h.start_trace(args.trace)

    name = Path(args.script).stem
    t0 = time.time()
    try:
        result = run(h)
        dt = time.time() - t0
        print(f"[PASS] {name} ({dt:.1f}s)" + (f" → {result}" if result is not None else ""))
        return 0
    except (HarnessError, AssertionError) as e:
        dt = time.time() - t0
        print(f"[FAIL] {name} ({dt:.1f}s): {e}", file=sys.stderr)
        return 1
    finally:
        h.close()


if __name__ == "__main__":
    sys.exit(main())
