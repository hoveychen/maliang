#!/usr/bin/env python3
"""world_ready —— 冒烟回归（Flow Registry P1，kind=regression，depends=[enter_world]）。

最小的「被测流程」样例：断言进世界后世界确实就绪。存在意义有二——
1) 证 depends 链：runner 会先跑 enter_world（把 harness 带进世界）再跑本体（设计 §5 P1 验收项）。
2) 作为一条真实（虽薄）的回归 flow，让 coverage 里 bypassed_regression=false（区别于只跑 setup）。

run(h) 断言 ws_open + npc_count>=8 + scene_id 非空，返回观测到的关键位。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness import HarnessError  # noqa: E402


def run(h, **kwargs):
    s = h.state()
    if not s.get("world_id"):
        raise HarnessError("world_ready: 不在世界（depends 链应先跑 enter_world 才对）")
    if not s.get("ws_open"):
        raise HarnessError("world_ready: ws 未连上（ws_open=false）")
    npc = int(s.get("npc_count", 0))
    if npc < 8:
        raise HarnessError(f"world_ready: 村民太少 npc_count={npc}（<8）")
    scene = s.get("scene_id", "")
    if not scene:
        raise HarnessError("world_ready: scene_id 为空")
    return {"scene_id": scene, "npc_count": npc, "ws_open": True}
