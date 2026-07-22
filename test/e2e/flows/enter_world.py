#!/usr/bin/env python3
"""enter_world —— 诚实幂等前置夹具（Flow Registry P1，kind=setup）。

把「从冷启到站在世界里」这段最常见前置收成一条可复用 flow，免得每个脚本/agent 都重走一遍
点菜单→等加载。**诚实**：只走真输入（真 tap 菜单全屏进入按钮，让游戏自己 menu→loading→world），
不引瞬移/seed 后门（守 harness-redesign「源头不给后门」）。**幂等**：已在世界则记 reused、跳过导航。

实测（2026-07-22 桌面 8578 实例）建立的路径事实：
- 冷启停在 menu：world_id 为空，不自发进世界；此时 actions 只有一条 press:btn:/root/Menu/*（全屏进入键）。
- 真 tap 该键 → loading → world（village_forest, world_id 置位, npc>=8, ws_open）。
- 档案持久（intro_seen + 有角色）→ target_scene 走 main.tscn，不落 onboarding。
- 若落 onboarding（首次设备无角色）：语音多轮建角色无法盲输诚实自动化 → 抛清晰错误，不伪造。

run(h) 返回 dict：{"status": "reused"|"navigated", "world_id":..., "scene_id":...}。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # test/e2e 上 sys.path，好 import harness
from harness import HarnessError  # noqa: E402

# 冷启到 menu 就绪的观察窗（app 级 harness 早于 menu 起，故 actions 可能先空）。
_BOOT_WINDOW = 30.0


def _in_world(s):
    """已在世界：world_id 非空即成立（menu/onboarding 时该字段为空或缺席）。"""
    return bool(s.get("world_id"))


def _find_menu_entry(h, timeout=_BOOT_WINDOW):
    """轮询 actions 找 menu 全屏进入键（press 且 target 落在 /root/Menu/ 下）。

    菜单只有这一条可点动作（实测），但节点名是自动生成的 @Button@N，故按路径前缀匹配、不写死名字。
    """
    import time
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            acts = h.actions().get("actions", [])
        except (OSError, HarnessError):
            acts = []
        for a in acts:
            aid = a.get("action_id", "")
            if a.get("kind") == "press" and "/root/Menu/" in aid and a.get("enabled", True):
                return aid
        time.sleep(1.0)
    return None


def run(h, **kwargs):
    """诚实幂等地把 harness 带进世界。kwargs 目前无参（args_schema={}），保留 **kwargs 兼容签名。"""
    # 1) 已在世界？幂等复用——只确认世界就绪，不再导航。
    s = h.state()
    if _in_world(s):
        h.wait_world(need_vc=False)  # 已在世界仍确认 ws+8村民就绪（可能刚进、村民未 spawn 全）
        return {"status": "reused", "world_id": s.get("world_id", ""), "scene_id": s.get("scene_id", "")}

    # 2) 在菜单：真 tap 全屏进入键，让游戏自己走 menu→loading→world。
    entry = _find_menu_entry(h)
    if entry is None:
        # 3) 既不在世界、也找不到菜单进入键 → 多半落在 onboarding（首次设备语音建角色）。
        #    诚实失败：不盲输伪造建角色。首次设备需手动完成一次 onboarding，档案持久后本 fixture 即走复用/菜单路径。
        raise HarnessError(
            "enter_world: 不在世界、也找不到菜单进入键（很可能落在 onboarding 语音建角色页）。"
            "首次设备需手动完成一次 onboarding（建角色），档案持久化后本 fixture 即走复用/菜单路径。")

    h.do(entry)  # 真 tap（execution=tap 投影全屏矩形）
    st = h.wait_world(need_vc=False)  # 服务端阻塞等 ws_open + npc>=8（穿过 loading 过场）
    return {"status": "navigated", "world_id": st.get("world_id", ""), "scene_id": st.get("scene_id", "")}
