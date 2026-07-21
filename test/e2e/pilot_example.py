#!/usr/bin/env python3
"""可重复 monkey 脚本范式（game-pilot 重写 P3）：用 access→do→wait 原语驱一整段交互，
而不是走一步截图看一步。这就是「AI 摸索出交互方式后写下来做回归」的形态——真 Python、带条件、可重跑。

跑法（先起桌面 debug 实例，见 SKILL.md）：
    python3 test/e2e/pilot_example.py [--port 8578]

它做的事：进世界 → 找点点(fairy)搭话 → 说一句造物请求 → 引导造物点卡直到起名 → 起名并确认。
每一步都用 wait 原语等落定（不卡 sleep），失败即抛错退非零——可直接进 CI/回归。
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, HarnessError  # noqa: E402


def find_action(acts, prefix):
    """在 actions 列表里找第一个 action_id 以 prefix 开头且 enabled 的动作 id。"""
    for a in acts:
        if a.get("action_id", "").startswith(prefix) and a.get("enabled", True):
            return a["action_id"]
    return None


def run(h):
    """一段可重复的造物+起名交互。h 是已连上、已进世界的 Harness。返回起的名字。"""
    # 1) 进世界就绪（桌面无端侧 ASR → inject 后 vc 才真，故 need_vc=False）。
    h.wait_world(need_vc=False)
    h.inject()

    # 2) 找点点搭话：从 actions 里挑 talk:fairy:*，do 之（真输入优先，落定后回包带新 actions）。
    fairy = find_action(h.actions().get("actions", []), "talk:fairy:")
    if not fairy:
        raise HarnessError("没找到可搭话的点点")
    h.do(fairy)
    h.wait_banner_stable(secs=3.0, timeout=15)   # 等点点招呼说完

    # 3) 说造物请求 → 等进入引导造物。
    h.say_when_open("点点，帮我造一个火箭")
    h.wait_until(lambda s: s.get("in_creation"), "进入引导造物", timeout=30)

    # 4) 引导循环：有卡就【真 tap 那张卡】（通用 press，不走 pick_option 后门），直到 naming_item 置位。
    #    观察 state.creation_options 拿到选项 label，再从 actions 里找 label 匹配的 press:btn 卡去 do。
    #    (卡是真 Button，world 给图标卡也挂了 tooltip=label，故 press 动作的 label == 选项 label。)
    for _ in range(12):
        s = h.state()
        if s.get("naming_item"):
            break
        opts = s.get("creation_options") or []
        if opts:
            want = opts[0].get("label", "")
            acts = h.actions().get("actions", [])
            press = next((a["action_id"] for a in acts
                          if a.get("kind") == "press" and a.get("label") == want), None)
            if press:
                h.do(press)                    # 真 tap 匹配 label 的造物卡
            else:
                h.say_when_open(want or "好的")  # 兜底：卡没采到就语音应答
            h.wait_delta("creation_question", timeout=20)
        else:
            h.say_when_open("好的")            # 开放问句：肯定应答
            h.wait_delta("creation_question", timeout=20)

    # 5) 起名 + 确认。
    name = "小火箭"
    h.wait_until(lambda s: s.get("naming_item"), "等待起名窗口", timeout=20)
    h.say_when_open(name)
    h.wait_until(lambda s: s.get("vc_confirming"), "进入确认模式", timeout=15)
    h.do("confirm:confirm_accept")
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578)
    ap.add_argument("--trace", default="")
    args = ap.parse_args()
    h = Harness(args.host, args.port, timeout=15.0)
    h.connect(retries=5, delay=1.0)
    if args.trace:
        h.start_trace(args.trace)
    try:
        name = run(h)
        print(f"[PASS] pilot_example：造物+起名完成 → {name}")
        return 0
    except HarnessError as e:
        print(f"[FAIL] pilot_example: {e}", file=sys.stderr)
        return 1
    finally:
        h.close()


if __name__ == "__main__":
    sys.exit(main())
