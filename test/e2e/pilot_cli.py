#!/usr/bin/env python3
"""game-pilot 唯一 CLI：每次调用连上 harness 口、执行一条命令、打印 JSON、退出。

给「AI 当玩家」的会话用：感知→决策→动作循环里，每步就是一条 Bash 命令，无需现写 python。
命令面与 MCP（server/tools/harness-mcp）**对等**——同一个 debug TCP 后台的两个入口。
配套 skill 见 .claude/skills/game-pilot/SKILL.md；SDK 见 test/e2e/harness.py。

感知/动作（curated，走 MonkeyHarness=玩家 SDK，无 god op）：
  pilot_cli.py observe                     # state+actions(+截图) 一次读全再决策
  pilot_cli.py access --texts              # 无障碍元素列表(3D 实体+2D 控件,各带 id+可用动作)
  pilot_cli.py actions                     # 当前可用动作扁平表(按 id 挑一条给 do)
  pilot_cli.py state                       # 结构化状态快照
  pilot_cli.py do talk:npc:pig_boss        # 执行动作 id(真输入优先);talk/scene/pick/phone/pickup/accept 都走 do
  pilot_cli.py do say --arg text="点点你好"  # 带参动作
  pilot_cli.py say "点点，帮我造一个火箭"     # 说一句(自动 inject,门禁关着 fed:false)
  pilot_cli.py wait --key in_creation --truthy --timeout 30   # 服务端阻塞等某字段
  pilot_cli.py shot --out /tmp/s.jpg       # 截一帧(headless 无视口会报错)

流程引擎（复用中心，与 MCP list_flows/run_flow 同一执行路径、同一注册表）：
  pilot_cli.py list-flows                  # 列可复用流程(Flow Registry)，JSON
  pilot_cli.py run-flow enter_world [--args '{"name":"小火箭"}']   # 按名跑(先跑 depends 链,带 coverage)
  pilot_cli.py run-script test/e2e/pilot_example.py               # 逃生口：跑 run(h) 脚本(完整 Harness,legacy/device 手势只在这)

★ 跑完整链路（造物起名/对话/引路…）前先 `list-flows` 看有没有现成 flow，别手搓重走前置；
  observe/state 的回包也会带 flows_hint 提醒这一点。

legacy 盲坐标/设备/调试子命令（tap/drag/click/teleport/phone/scene/talk-*/pick/accept/inject/
reset-* …）**已从 CLI 砍掉**——curated 能力经 `do <action_id>`，其余只经 `run-script`+完整 Harness SDK。

所有子命令支持 --trace DIR：命令+应答追加到 DIR/trace.jsonl（跨调用累积，audit/回放用）。
退出码：应答 ok=true → 0，否则 1（用法/加载错 → 2）。
"""

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, MonkeyHarness, HarnessError, diff_state  # noqa: E402

FLOWS_DIR = Path(__file__).parent / "flows"
sys.path.insert(0, str(FLOWS_DIR))
import registry as reg  # noqa: E402

# headless dispatch 场景没有 MCP（`claude -p` 默认不加载），agent 起手够到的就是这个 CLI。
# 把「有现成 flow 可复用」推到它最先跑的 observe/state 回包里，别让它手搓重走前置。
FLOWS_HINT = (
    "★ 要跑完整链路先看有没有现成 flow：pilot_cli.py list-flows"
    "（进世界/onboarding/造物起名等前置多半已有，run-flow 跑，带 coverage），别手搓重走。"
)


def out(obj):
    """交互式子命令：漂亮 JSON（人读）。"""
    print(json.dumps(obj, ensure_ascii=False, indent=1))
    return 0 if obj.get("ok", True) else 1


def out_machine(obj):
    """流程引擎子命令：单行 JSON（MCP/web 子进程按最后一行 JSON 解析）。"""
    print(json.dumps(obj, ensure_ascii=False))
    return 0 if obj.get("ok", True) else 1


# ── 流程引擎（原 pilot_runner.py 折入——单一 CLI，不再分脚本）──────────────────
# 逐帧漂移的高频字段（wander 让 npcs 位置每帧变）从 flow 级 delta 剔掉，否则每次塞两份全量村民数组纯噪音。
_DELTA_NOISE_KEYS = ("npcs", "npc_ids")


def _flow_delta(before, after):
    strip = lambda s: {k: v for k, v in (s or {}).items() if k not in _DELTA_NOISE_KEYS}
    return diff_state(strip(before), strip(after))


def load_run(script_path):
    """加载脚本模块，返回其 run 函数。缺 run → 加载错。"""
    p = Path(script_path)
    if not p.exists():
        raise SystemExit(f"[cli] 脚本不存在: {script_path}")
    modname = f"pilot_flow_{p.stem}"
    spec = importlib.util.spec_from_file_location(modname, str(p))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[modname] = mod
    spec.loader.exec_module(mod)
    fn = getattr(mod, "run", None)
    if not callable(fn):
        raise SystemExit(f"[cli] {script_path} 没有 run(h) 函数")
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
    """按注册名跑 flow：先按 depends 拓扑序跑前置链，本体按 args_schema 校验并传参，汇总 coverage。"""
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
        # 本体开跑前按声明的 requires 严格判当前 state（deps 已把 provides 真建立）——不靠 flow 手写 raise。
        gate = reg.evaluate_now(fdef, h.state())
        if not gate["ok"]:
            raise HarnessError(f"flow {fname} 前置未满足: {'; '.join(gate['reasons'])}")
        t0 = time.time()
        fn = load_run(fdef["script_path"])
        result = _call_run(fn, h, fargs)
        dt = round(time.time() - t0, 2)
        status = result.get("status") if isinstance(result, dict) and result.get("status") else "ok"
        ran.append({"name": fname, "kind": fdef["kind"], "status": status, "dt": dt, "result": result})

    after = h.state()
    coverage = {
        "used_setup": [r["name"] for r in ran if r["kind"] == "setup"],
        "skipped": [r["name"] for r in ran if str(r["status"]).startswith("skip")],
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


# ── flow 引擎子命令入口（不连游戏 / 自建连接）─────────────────────────────────
def _cmd_list_flows(args):
    try:
        flows = reg.load_registry(args.registry or None)
    except reg.RegistryError as e:
        return out_machine({"ok": False, "error": str(e)})
    state = None
    if args.with_availability:
        h = MonkeyHarness(args.host, args.port, timeout=args.timeout)
        try:
            h.connect(retries=2, delay=0.5)
            state = h.state()
        except HarnessError:
            state = None   # 游戏没连上 → available.ok=None（未知）
        finally:
            h.close()
    items = []
    for f in flows.values():
        item = {k: v for k, v in f.items() if k != "script_path"}
        if args.with_availability:
            item["available"] = reg.availability(flows, f["name"], state)
        items.append(item)
    return out_machine({"ok": True, "flows": items})


def _parse_args_json(raw):
    if not raw:
        return {}
    parsed = json.loads(raw)   # JSONDecodeError 交给调用方
    if not isinstance(parsed, dict):
        raise ValueError("--args 须为 JSON 对象")
    return parsed


def _cmd_run_flow(args):
    try:
        flow_args = _parse_args_json(args.args)
    except (json.JSONDecodeError, ValueError) as e:
        return out_machine({"ok": False, "flow": args.name, "error": f"--args 不合法: {e}"})
    # 注册 flow 走 MonkeyHarness（玩家 SDK，god op 不存在）——与 MCP run_flow 同一执行模型。
    h = MonkeyHarness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=5, delay=1.0)
    except HarnessError as e:
        return out_machine({"ok": False, "flow": args.name, "error": f"连不上: {e}"})
    if args.trace:
        h.start_trace(args.trace)
    try:
        return out_machine(run_flow(h, args.name, flow_args, args.registry or None))
    except reg.RegistryError as e:
        return out_machine({"ok": False, "flow": args.name, "error": str(e)})
    except (HarnessError, AssertionError) as e:
        return out_machine({"ok": False, "flow": args.name, "error": str(e)})
    finally:
        h.close()


def _cmd_run_script(args):
    try:
        script_args = _parse_args_json(args.args)
    except (json.JSONDecodeError, ValueError) as e:
        return out_machine({"ok": False, "error": f"--args 不合法: {e}"})
    name = Path(args.path).stem
    # --script 逃生口给完整 Harness（legacy/device 手势只在这条路可写）。
    h = Harness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=5, delay=1.0)
    except HarnessError as e:
        return out_machine({"ok": False, "flow": name, "error": f"连不上: {e}"})
    if args.trace:
        h.start_trace(args.trace)
    try:
        result, dt = run_script(h, args.path, script_args)
        return out_machine({"ok": True, "flow": name, "result": result, "duration": round(dt, 2)})
    except (HarnessError, AssertionError) as e:
        return out_machine({"ok": False, "flow": name, "error": str(e)})
    finally:
        h.close()


def main():
    ap = argparse.ArgumentParser(
        description="game-pilot 唯一 CLI（命令面与 MCP 对等）。"
                    "★ 跑完整链路前先 `pilot_cli.py list-flows` 看有没有现成 flow，别手搓重走前置。")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578, help="8578=桌面实例缺省；真机 forward 后用 8577")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--trace", default="", help="轨迹目录（追加 trace.jsonl+截图）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    # ── 感知/动作（MCP 对等，curated 走 MonkeyHarness）────────────────────────
    sub.add_parser("state")
    p = sub.add_parser("access")
    p.add_argument("--texts", action="store_true")
    sub.add_parser("actions")
    p = sub.add_parser("do")
    p.add_argument("action")
    p.add_argument("--arg", action="append", default=[], metavar="K=V",
                   help="动作参数 k=v（可多次，如 say 的 --arg text=你好）")
    p = sub.add_parser("observe")
    p.add_argument("--no-shot", action="store_true")
    p = sub.add_parser("say")
    p.add_argument("text")
    p = sub.add_parser("wait")   # 服务端阻塞等待某字段满足条件（= MCP wait_until）
    p.add_argument("--key", required=True)
    p.add_argument("--equals", default=None)
    p.add_argument("--truthy", action="store_true")
    p.add_argument("--falsy", action="store_true")
    p.add_argument("--changed", action="store_true", help="等该字段相对发起时变化")
    p.add_argument("--gte", type=float, default=None)
    p.add_argument("--timeout", type=float, default=45.0, dest="wtimeout")
    p = sub.add_parser("shot")
    p.add_argument("--out", default="")
    p.add_argument("--max-dim", type=int, default=960)

    # ── 流程引擎（复用中心，与 MCP list_flows/run_flow 同一注册表/执行路径）──────
    p = sub.add_parser("list-flows")
    p.add_argument("--with-availability", action="store_true",
                   help="连游戏取一份 state，给每条 flow 标 available{ok,reasons}（现在能不能跑）")
    p.add_argument("--registry", default="", help="registry.json 路径（缺省用 flows/registry.json）")
    p = sub.add_parser("run-flow")
    p.add_argument("name")
    p.add_argument("--args", default="", help="传给本体 flow 的参数（JSON 对象）")
    p.add_argument("--registry", default="")
    p = sub.add_parser("run-script")
    p.add_argument("path", help="暴露 run(h) 的 .py（逃生口，完整 Harness）")
    p.add_argument("--args", default="", help="传给 run(h,**args) 的参数（JSON 对象）")

    args = ap.parse_args()

    # flow 引擎子命令自建连接（或不连）——单行 JSON 输出。
    if args.cmd == "list-flows":
        return _cmd_list_flows(args)
    if args.cmd == "run-flow":
        return _cmd_run_flow(args)
    if args.cmd == "run-script":
        return _cmd_run_script(args)

    # 感知/动作：curated 玩家 SDK，无 god op。
    h = MonkeyHarness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=3, delay=0.5)
    except HarnessError as e:
        return out({"ok": False, "error": str(e)})
    if args.trace:
        h.start_trace(args.trace)

    try:
        c = args.cmd
        if c == "state":
            return out({**h.state(), "flows_hint": FLOWS_HINT})
        if c == "access":
            return out(h.access(texts=args.texts))
        if c == "actions":
            return out(h.actions())
        if c == "do":
            kv = {}
            for item in args.arg:
                if "=" in item:
                    k, v = item.split("=", 1)
                    kv[k] = v
            return out(h.do(args.action, **kv))
        if c == "observe":
            return out({"ok": True, **h.observe(shot=not args.no_shot), "flows_hint": FLOWS_HINT})
        if c == "say":
            return out(h.say(args.text))
        if c == "wait":
            cond = {"field": args.key}
            if args.truthy:
                cond["mode"] = "truthy"
            elif args.falsy:
                cond["mode"] = "falsy"
            elif args.changed:
                cond["mode"] = "changed"
            elif args.gte is not None:
                cond["mode"] = "gte"; cond["target"] = args.gte
            elif args.equals is not None:
                cond["mode"] = "equals"; cond["target"] = args.equals
            else:
                cond["mode"] = "present"
            return out(h.wait_server([cond], timeout=args.wtimeout))
        if c == "shot":
            path = h.screenshot(path=args.out or None, max_dim=args.max_dim)
            return out({"ok": True, "shot": path})
        return out({"ok": False, "error": f"未知子命令: {c}"})
    except HarnessError as e:
        return out({"ok": False, "error": str(e)})
    finally:
        h.close()


if __name__ == "__main__":
    sys.exit(main())
