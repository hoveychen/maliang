#!/usr/bin/env python3
"""monkey 脚本 / flow runner（game-pilot 重写 P5 + Flow Registry P1）：跑一个暴露 run(h,**args) 的脚本，
统一提供连接、trace、计时、pass/fail。让 AI「摸索出交互后写下来做回归」——脚本是真 Python（带条件/循环/断言）。

两种调用（MCP/web/CLI 三入口都经这里 → 单一执行路径，设计 §4 A2）：
    # 直接跑某个 .py（老用法，无 depends/参数解析）
    python3 test/e2e/pilot_runner.py --script test/e2e/pilot_example.py [--port 8578] [--trace DIR]
    # 按注册名跑（先按 depends 拓扑序跑前置链，按 args_schema 校验并传参，汇总 coverage）
    python3 test/e2e/pilot_runner.py --flow enter_world [--args '{"name":"小火箭"}'] [--json]

脚本约定：模块级 def run(h, **args): ...  —— h 是已连上的 Harness；抛 HarnessError/AssertionError = 失败。
无参 run(h) 照旧兼容（不传参时按 run(h) 调）。
退出码：0 通过、1 失败、2 用法/加载错。

coverage（设计 R6/D4，随 --flow 汇总，--json 时进回包，否则打印一行）：
    used_setup           本次执行到的 setup 型 flow 名（含依赖链里的）
    skipped              本次被跳过的 flow（正常拓扑执行下为空；fixture 自报 skip 时进这里）
    bypassed_regression  本次没跑到任何 regression 型 flow=true（=只做了 setup、没真验回归 → 让缩水可见）
"""
import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, HarnessError, diff_state  # noqa: E402

FLOWS_DIR = Path(__file__).parent / "flows"
sys.path.insert(0, str(FLOWS_DIR))
import registry as reg  # noqa: E402

# 逐帧漂移的高频字段（wander 让 npcs 位置每帧变）——从 flow 级 delta 里剔掉，否则每次回包塞两份全量
# 村民数组，纯噪音、白烧 token。world_id/scene_id/bag/wallet/creation 等真信号照留。
_DELTA_NOISE_KEYS = ("npcs", "npc_ids")


def _flow_delta(before, after):
    strip = lambda s: {k: v for k, v in (s or {}).items() if k not in _DELTA_NOISE_KEYS}
    return diff_state(strip(before), strip(after))


def load_run(script_path):
    """加载脚本模块，返回其 run 函数。缺 run → Registry/加载错。"""
    p = Path(script_path)
    if not p.exists():
        raise SystemExit(f"[runner] 脚本不存在: {script_path}")
    # 模块名按 stem 唯一化，避免依赖链里多个脚本共用 "pilot_script" 相互覆盖。
    modname = f"pilot_flow_{p.stem}"
    spec = importlib.util.spec_from_file_location(modname, str(p))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[modname] = mod
    spec.loader.exec_module(mod)
    fn = getattr(mod, "run", None)
    if not callable(fn):
        raise SystemExit(f"[runner] {script_path} 没有 run(h) 函数")
    return fn


def _call_run(fn, h, args):
    """调 run：有参就 run(h,**args)，无参就 run(h)（兼容老的 run(h) 签名）。"""
    if args:
        return fn(h, **args)
    return fn(h)


def run_script(h, script_path, args=None):
    """跑单个脚本（不解析 registry）。返回 (result, dt)。抛错交给调用方。"""
    fn = load_run(script_path)
    t0 = time.time()
    result = _call_run(fn, h, args or {})
    return result, time.time() - t0


def run_flow(h, name, args=None, registry_path=None):
    """按注册名跑 flow：先按 depends 拓扑序跑前置链，本体按 args_schema 校验并传参，汇总 coverage。

    返回 {ok, flow, ran:[{name,kind,status,dt,result}], coverage, delta, duration, error?}。
    delta = 全链跑完前后 state 的增量。ran 里前置 flow 无参跑（走默认），仅本体收 args。
    """
    flows = reg.load_registry(registry_path)
    order = reg.resolve_order(flows, name)          # depends 先、本体后
    target = reg.get(flows, name)
    args = reg.validate_args(target, args)          # 只校验本体入参（依赖走默认）

    before = h.state()
    ran = []
    t_all = time.time()
    for fname in order:
        fdef = flows[fname]
        fargs = args if fname == name else {}       # 依赖链无参跑，仅本体传 args
        # P6 硬 gate：本体开跑前按声明的 requires 严格判当前 state（deps 已把 provides 真建立）。
        # 未满足即抛——把「声明的前置」变成代码 gate，不靠各 flow 手写 raise，也不靠 LLM 自觉。
        gate = reg.evaluate_now(fdef, h.state())
        if not gate["ok"]:
            raise HarnessError(f"flow {fname} 前置未满足: {'; '.join(gate['reasons'])}")
        t0 = time.time()
        fn = load_run(fdef["script_path"])
        result = _call_run(fn, h, fargs)
        dt = round(time.time() - t0, 2)
        # fixture 可自报 status（如 enter_world 的 reused/navigated）；否则记 ok。
        status = result.get("status") if isinstance(result, dict) and result.get("status") else "ok"
        ran.append({"name": fname, "kind": fdef["kind"], "status": status, "dt": dt, "result": result})

    after = h.state()
    coverage = {
        "used_setup": [r["name"] for r in ran if r["kind"] == "setup"],
        # fixture 自报 status 含 skip 的记为跳过（正常拓扑执行为空）——让「谁没真跑」显式可见。
        "skipped": [r["name"] for r in ran if str(r["status"]).startswith("skip")],
        # 全链没跑到任何 regression = 只做了 setup、没真验回归。
        "bypassed_regression": not any(r["kind"] == "regression" for r in ran),
    }
    return {
        "ok": True,
        "flow": name,
        "ran": ran,
        "coverage": coverage,
        "delta": _flow_delta(before, after),
        "duration": round(time.time() - t_all, 2),
    }


def main():
    ap = argparse.ArgumentParser(description="game-pilot monkey 脚本 / flow runner")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--script", help="直接跑某个暴露 run(h) 的 .py 脚本（无 depends/参数解析）")
    g.add_argument("--flow", help="按注册名跑（解析 depends 链 + args_schema + coverage）")
    g.add_argument("--list", action="store_true", help="列出注册表全部 flow（JSON，不连游戏），供 MCP/web list_flows")
    ap.add_argument("--with-availability", action="store_true",
                    help="配 --list：连游戏取一份 state，给每条 flow 标 available{ok,reasons}（现在能不能跑）")
    ap.add_argument("--args", default="", help="传给本体 flow 的参数（JSON 对象，如 '{\"name\":\"小火箭\"}'）")
    ap.add_argument("--registry", default="", help="registry.json 路径（缺省用 flows/registry.json）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578)
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--trace", default="", help="trace 目录（命令+应答+截图落 trace.jsonl）")
    ap.add_argument("--json", action="store_true", help="结果以单行 JSON 打到 stdout（供 MCP/web 子进程解析）")
    args = ap.parse_args()

    # --list 默认不连游戏：加载校验注册表并把 flow 元数据打成 JSON（去掉 script_path 绝对路径）。
    # --with-availability 时才连游戏取一份 state，给每条标 available{ok,reasons}（现在能不能跑，含依赖 provides）。
    if args.list:
        try:
            flows = reg.load_registry(args.registry or None)
        except reg.RegistryError as e:
            print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
            return 2
        state = None
        if args.with_availability:
            h = Harness(args.host, args.port, timeout=args.timeout)
            try:
                h.connect(retries=2, delay=0.5)
                state = h.state()
            except HarnessError:
                state = None   # 游戏没连上 → available.ok=None（未知）
            finally:
                h.close()
        out = []
        for f in flows.values():
            item = {k: v for k, v in f.items() if k != "script_path"}
            if args.with_availability:
                item["available"] = reg.availability(flows, f["name"], state)
            out.append(item)
        print(json.dumps({"ok": True, "flows": out}, ensure_ascii=False))
        return 0

    parsed_args = {}
    if args.args:
        try:
            parsed_args = json.loads(args.args)
        except json.JSONDecodeError as e:
            print(f"[runner] --args 不是合法 JSON: {e}", file=sys.stderr)
            return 2
        if not isinstance(parsed_args, dict):
            print("[runner] --args 须为 JSON 对象", file=sys.stderr)
            return 2

    h = Harness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=5, delay=1.0)
    except HarnessError as e:
        print(f"[runner] 连不上: {e}", file=sys.stderr)
        return 1
    if args.trace:
        h.start_trace(args.trace)

    try:
        if args.flow:
            try:
                out = run_flow(h, args.flow, parsed_args, args.registry or None)
            except reg.RegistryError as e:
                if args.json:
                    print(json.dumps({"ok": False, "flow": args.flow, "error": str(e)}, ensure_ascii=False))
                else:
                    print(f"[FAIL] flow {args.flow}: {e}", file=sys.stderr)
                return 2
            if args.json:
                print(json.dumps(out, ensure_ascii=False))
            else:
                chain = " -> ".join(f"{r['name']}({r['status']},{r['dt']}s)" for r in out["ran"])
                print(f"[PASS] flow {args.flow} ({out['duration']}s): {chain}")
                print(f"       coverage: {json.dumps(out['coverage'], ensure_ascii=False)}")
            return 0
        else:
            name = Path(args.script).stem
            result, dt = run_script(h, args.script, parsed_args)
            if args.json:
                print(json.dumps({"ok": True, "flow": name, "result": result,
                                  "duration": round(dt, 2)}, ensure_ascii=False))
            else:
                print(f"[PASS] {name} ({dt:.1f}s)" + (f" → {result}" if result is not None else ""))
            return 0
    except (HarnessError, AssertionError) as e:
        if args.json:
            print(json.dumps({"ok": False, "flow": args.flow or Path(args.script).stem,
                              "error": str(e)}, ensure_ascii=False))
        else:
            print(f"[FAIL] {args.flow or args.script}: {e}", file=sys.stderr)
        return 1
    finally:
        h.close()


if __name__ == "__main__":
    sys.exit(main())
