#!/usr/bin/env python3
"""声明式 flow 单测（harness-declarative-flows P1）：registry 的 steps 校验 + pilot_cli.run_steps dispatch。

核心断言是「不泄漏非定义词汇」由格式硬保证：steps 里出现任何 legacy/盲坐标 op（tap/scene/phone…）
在 registry 加载期就被拒（RegistryError），根本进不到 executor。纯函数 + fake harness，不起游戏、无网络。
运行: python3 test/e2e/test_declarative_flow.py（退出码=失败数）。"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent / "flows"))
import registry as reg          # noqa: E402
from pilot_cli import run_steps  # noqa: E402

fails = 0


def check(name, cond):
    global fails
    if cond:
        print(f"  ✓ {name}")
    else:
        print(f"  ✗ {name}", file=sys.stderr)
        fails += 1


def load_one(flow):
    """把单条 flow 写进临时 registry.json 并加载，返回 (flows 或 None, error 或 None)。"""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fp:
        json.dump({"flows": [flow]}, fp, ensure_ascii=False)
        path = fp.name
    try:
        return reg.load_registry(path), None
    except reg.RegistryError as e:
        return None, str(e)
    finally:
        Path(path).unlink(missing_ok=True)


# ── 校验：合法声明式 flow（do/say/wait/inject 全用上）能加载 ──
GOOD = {
    "name": "rec_demo", "desc": "录制回放示例", "kind": "regression",
    "steps": [
        {"op": "inject"},
        {"op": "say", "text": "点点，帮我造一个火箭"},
        {"op": "wait", "conds": [{"field": "in_creation", "mode": "truthy"}], "timeout": 30},
        {"op": "do", "action": "confirm:confirm_accept"},
    ],
}
flows, err = load_one(GOOD)
check("合法声明式 flow 加载成功", flows is not None and "rec_demo" in flows)
check("加载后带 steps 字段", flows and flows["rec_demo"].get("steps") is not None)
check("声明式 flow 无 script_path", flows and flows["rec_demo"].get("script_path") is None)

# ── 不泄漏：含 legacy op(tap) 的 steps 被格式拒（本套件的灵魂断言）──
_, err = load_one({"name": "leak", "kind": "regression",
                   "steps": [{"op": "tap", "x": 1, "y": 2}]})
check("含 tap 的声明式 flow 被拒", err is not None and "op 非法" in err)
_, err = load_one({"name": "leak2", "kind": "regression",
                   "steps": [{"op": "teleport", "tileX": 3, "tileY": 4}]})
check("含 teleport 的声明式 flow 被拒", err is not None and "op 非法" in err)

# ── 必需字段缺失被拒 ──
_, err = load_one({"name": "bad_do", "kind": "regression", "steps": [{"op": "do"}]})
check("do 缺 action 被拒", err is not None and "缺字段 action" in err)
_, err = load_one({"name": "empty", "kind": "regression", "steps": []})
check("空 steps 被拒", err is not None and "非空数组" in err)

# ── script/steps 二选一：都缺 / 都有 均拒 ──
_, err = load_one({"name": "neither", "kind": "regression"})
check("script/steps 都缺被拒", err is not None and "恰好有 script 或 steps" in err)
_, err = load_one({"name": "both", "kind": "regression",
                   "script": "flows/enter_world.py",
                   "steps": [{"op": "say", "text": "x"}]})
check("script/steps 都有被拒", err is not None and "恰好有 script 或 steps" in err)


# ── executor：run_steps 用 fake harness 按序 dispatch ──
class FakeH:
    def __init__(self, wait_matched=True):
        self.calls = []
        self._wm = wait_matched

    def do(self, action, **args):
        self.calls.append(("do", action, args)); return {"ok": True}

    def say(self, text):
        self.calls.append(("say", text)); return {"ok": True}

    def wait_server(self, conds, timeout=40.0):
        self.calls.append(("wait", conds, timeout)); return {"ok": True, "matched": self._wm}

    def inject(self):
        self.calls.append(("inject",)); return {"ok": True}

    def state(self):
        self.calls.append(("state",)); return {}   # run_flow 的 before/after + gate 会调


h = FakeH()
res = run_steps(h, GOOD["steps"])
check("run_steps 全绿 status=ok", res["status"] == "ok")
check("run_steps 按序 dispatch 4 步", [c[0] for c in h.calls] == ["inject", "say", "wait", "do"])
check("do 步带 action_id", ("do", "confirm:confirm_accept", {}) in h.calls)
check("say 步带文本", ("say", "点点，帮我造一个火箭") in h.calls)

# do 带 args 透传
h2 = FakeH()
run_steps(h2, [{"op": "do", "action": "say", "args": {"text": "hi"}}])
check("do.args 透传给 h.do", h2.calls == [("do", "say", {"text": "hi"})])

# wait 没等到 → status wait_timeout，且不再往下跑
h3 = FakeH(wait_matched=False)
res = run_steps(h3, [{"op": "wait", "conds": [{"field": "x", "mode": "truthy"}]},
                     {"op": "say", "text": "不该跑到"}])
check("wait 超时 status=wait_timeout", res["status"] == "wait_timeout")
check("wait 超时 failed_at=0", res.get("failed_at") == 0)
check("wait 超时后不继续 dispatch", [c[0] for c in h3.calls] == ["wait"])


# ── P2 steps_from_trace：trace 记录 → 声明式 steps ──
from pilot_cli import steps_from_trace  # noqa: E402

recs = [
    {"cmd": {"op": "inject"}, "reply": {"ok": True}},
    {"cmd": {"op": "state"}, "reply": {}},                       # 读操作丢弃
    {"cmd": {"op": "say", "text": "你好"}, "reply": {"ok": True}},
    {"cmd": {"op": "do", "action": "talk:npc:x", "args": {}}, "reply": {}},
    {"cmd": {"op": "do", "action": "say", "args": {"text": "hi"}}, "reply": {}},
    {"cmd": {"op": "wait", "conds": [{"field": "y", "mode": "truthy"}], "timeout": 20}, "reply": {}},
    {"shot": "x.jpg"},                                           # 非 cmd 记录跳过
]
st = steps_from_trace(recs)
check("trace 抽出 5 步(读操作丢弃)", len(st) == 5)
check("readonly state 被丢", all(s["op"] != "state" for s in st))
check("do 带 args 保留", {"op": "do", "action": "say", "args": {"text": "hi"}} in st)
check("do 空 args 省略", {"op": "do", "action": "talk:npc:x"} in st)
check("wait timeout 保留",
      {"op": "wait", "conds": [{"field": "y", "mode": "truthy"}], "timeout": 20} in st)

try:
    steps_from_trace([{"cmd": {"op": "tap", "x": 1, "y": 2}}])
    check("trace 含 tap 被拒", False)
except ValueError as e:
    check("trace 含 tap 被拒", "非定义动作" in str(e))

flows, _ = load_one({"name": "from_trace", "kind": "regression", "steps": st})
check("trace 抽出的 steps 可注册成 flow", flows is not None and "from_trace" in flows)


# ── P3 run_flow 跑声明式 flow（temp registry + fake h，离线验执行路径，不起游戏）──
from pilot_cli import run_flow  # noqa: E402

_decl = {"name": "decl_e2e", "kind": "regression",
         "steps": [{"op": "inject"}, {"op": "say", "text": "hi"},
                   {"op": "do", "action": "confirm:confirm_accept"}]}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fp:
    json.dump({"flows": [_decl]}, fp, ensure_ascii=False)
    _rpath = fp.name
hh = FakeH()
res = run_flow(hh, "decl_e2e", registry_path=_rpath)
Path(_rpath).unlink(missing_ok=True)
check("run_flow 声明式 ok", res.get("ok") is True)
check("run_flow 跑了声明式本体",
      any(r["name"] == "decl_e2e" and r["status"] == "ok" for r in res["ran"]))
check("run_flow 经 run_steps 真 dispatch",
      [c[0] for c in hh.calls].count("do") == 1 and ("say", "hi") in hh.calls)


if fails == 0:
    print("[PASS] test_declarative_flow")
else:
    print(f"[FAIL] test_declarative_flow: {fails} 处", file=sys.stderr)
sys.exit(fails)
