#!/usr/bin/env python3
"""diff_state 纯函数单测（game-pilot 重写 P3）。验增量的 changed/added/removed 与 key-absence 语义。
不起游戏、无网络。运行: python3 test/e2e/test_harness_delta.py（退出码=失败数）。"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import diff_state  # noqa: E402

fails = 0


def check(name, got, want):
    global fails
    if got == want:
        print(f"  ✓ {name}")
    else:
        print(f"  ✗ {name}: got {got!r} want {want!r}", file=sys.stderr)
        fails += 1


# 值变化 → changed[k]=[旧,新]
d = diff_state({"a": 1, "b": 2}, {"a": 1, "b": 9})
check("changed 只含变的", d["changed"], {"b": [2, 9]})
check("changed 不含没变的", "a" in d["changed"], False)
check("changed 无 added", d["added"], {})
check("changed 无 removed", d["removed"], {})

# 新增 key（cur 有 prev 无）→ added，不进 changed
d = diff_state({"a": 1}, {"a": 1, "phone_open": True})
check("added 新 key", d["added"], {"phone_open": True})
check("added 不算 changed", d["changed"], {})

# 移除 key（prev 有 cur 无）→ removed（key-absence 有别于值变）
d = diff_state({"a": 1, "active_task": {"id": "t"}}, {"a": 1})
check("removed 缺失 key", d["removed"], {"active_task": {"id": "t"}})
check("removed 不算 changed", d["changed"], {})

# 嵌套字典按值比较
d = diff_state({"wallet": {"flowers": 1}}, {"wallet": {"flowers": 2}})
check("嵌套变化进 changed", d["changed"], {"wallet": [{"flowers": 1}, {"flowers": 2}]})
d = diff_state({"wallet": {"flowers": 1}}, {"wallet": {"flowers": 1}})
check("嵌套相等不进 changed", d["changed"], {})

# None/空基线：无 prev → 全 added
check("prev=None 全 added", diff_state(None, {"a": 1})["added"], {"a": 1})
check("prev=None 无 changed", diff_state(None, {"a": 1})["changed"], {})
check("cur=None 全 removed", diff_state({"a": 1}, None)["removed"], {"a": 1})
check("双空", diff_state({}, {}), {"changed": {}, "added": {}, "removed": {}})

# 同快照 → 全空
same = {"fsm_state": "EXPLORE", "npc_count": 8}
check("同快照零增量", diff_state(same, dict(same)), {"changed": {}, "added": {}, "removed": {}})

if fails == 0:
    print("[PASS] test_harness_delta")
else:
    print(f"[FAIL] test_harness_delta: {fails} 处", file=sys.stderr)
sys.exit(fails)
