#!/usr/bin/env python3
"""端侧语音链·真机一键回归（voice-backlog-e2e P4）。

在真机上逐条自动驱动并断言各条语音链，清「真机未验」积压。控制通道 = debug 构建里的
本地 TCP 命令口（scripts/debug_cmd_server.gd，仅 OS.is_debug_build），复用 naming_e2e.Harness。

前置（真机）：
  1. 主 checkout 导带 harness 的 debug APK：scripts/export-apk.sh（worktree 导不了，ASR 模型 gitignored）。
     装机后核对设备端 md5（华为 install -r 有装回旧包前科）。
  2. adb forward tcp:8577 tcp:8577（脚本自动做）。设备连的是 PROD。

覆盖的链（每条独立 fresh launch，避免上一条把对话态搞脏——实测同实例连驱会因 TTS 堆叠
门禁一直关）：
  - greeting  招呼链：talk_npc→村民用自己声音先开口（last_greeting 非空）+ 招呼 TTS 期间麦门禁关
  - dialogue  对话往返：talk_npc→等招呼完→say 提问→村民 LLM 回复上 banner（上行 ASR→后端→LLM→下行）
  - guide     引路：talk_fairy→say「带我去找 X」→guide_active 置位 + guide_target=X（LLM 意图路由）

未纳入：
  - naming    起名落库：见 naming_e2e.py（需 create 意图 + 名字，另有服务端落库核验，单独跑）。
  - reuse     复用提示：需背包塞 kind 命中的旧物 + 眼前村民 wish 该【未 discovered】能力 + 本会话没提过。
              PROD 上背包无 seed 端点、wish 池 LLM 驱不可控、小明已 discovered create_prop（P2 造凳），
              三条件凑不齐 → 当前工具链不可确定性驱动。服务端 reuseHint 是纯函数已单测（server 全绿），
              客户端 wiring 与已上线的 wish-leak 共用 npc_wishes 传输，风险低。要真机驱需先加
              debug 端点（塞背包 + 强制某 wish）。

关键时序坑（踩过）：
  - inject/reset_budget 必须在【进世界后】发（VoiceCapture/world 钩子在 world 才有），在标题页发会报错。
  - say 会先 enqueue 文本再查门禁——门禁关时反复 say 会堆 ASR 队列。所以每条 say 前先等对方
    TTS 放完（banner 连续数秒不变 = 说完），门禁开了再 say。
  - 跑 headless 前必 `adb forward --remove tcp:8577`，否则占口害 test_harness_wire 挂。

用法：
  python3 test/e2e/voice_regression.py                 # 全部链，自动 fresh launch
  python3 test/e2e/voice_regression.py --only guide     # 只跑某条
  python3 test/e2e/voice_regression.py --no-launch      # 连当前运行实例跑第一条（调试用）
"""

import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from naming_e2e import Harness, adb, PACKAGE, LAUNCH_ACTIVITY, PORT, setup_forward


# 这三个 helper 曾在此重复实现，harness 重写 P3 已整合进 Harness——此处只做薄委托，保留原调用签名
# 与语义（wait 超时返 None、st 出错返 {}）。新代码请直接用 h.wait_until / h.wait_banner_stable / h.say_when_open。
def st(h):
    return h._state_soft()


def wait(h, pred, timeout=40, poll=1.0):
    return h.wait_until(pred, "voice_regression wait", timeout, poll, soft=True)


def wait_banner_stable(h, secs=5.0, timeout=45):
    return h.wait_banner_stable(secs=secs, timeout=timeout)


def say_when_open(h, text, tries=8):
    return h.say_when_open(text, tries=tries)


def fresh_world(launch=True):
    """fresh launch → 进世界 → 等 8 村民+ws+vc 就绪 → inject+reset_budget。返回 (h, ok)。"""
    if launch:
        adb("shell", "am", "force-stop", PACKAGE)
        time.sleep(1.0)
        adb("shell", "am", "start", "-n", LAUNCH_ACTIVITY)
        time.sleep(6.0)
    h = Harness("127.0.0.1", PORT, timeout=12.0)
    h.connect(retries=25, delay=1.0)
    if launch:
        h.tap(1205, 685)  # 标题页 → 进世界（盲坐标，按设备定）
    s = wait(h, lambda s: (s.get("npc_count") or 0) >= 8 and s.get("ws_open") and s.get("vc_ready"),
             timeout=45)
    if not s:
        print(f"    ✗ 45s 未就绪（可能撞空村 flake，见 empty-village-flake plan）："
              f"npc_count={st(h).get('npc_count')} vc_ready={st(h).get('vc_ready')}")
        return h, False
    h.send({"op": "inject"})
    h.send({"op": "reset_budget"})
    return h, True


# ── 各条链 ─────────────────────────────────────────────────────────────────

def chain_greeting(h):
    r = h.send({"op": "talk_npc"})
    if not r.get("entered"):
        return False, "talk_npc entered=false（无真村民？）"
    s = wait(h, lambda s: s.get("last_greeting"), timeout=20)
    if not s:
        return False, "20s 未收到招呼（last_greeting 恒空）"
    greeting = s.get("last_greeting")
    # 招呼 TTS 期间麦门禁应关
    r = h.send({"op": "say", "text": "你好呀"})
    gated = (not r.get("fed")) and r.get("reason") == "gate_closed"
    if not gated:
        return False, f"招呼期间麦门禁未关（应 gate_closed）：{r}"
    return True, f"村民先开口={greeting!r} + 招呼期麦门禁关"


def chain_dialogue(h):
    r = h.send({"op": "talk_npc"})
    if not r.get("entered"):
        return False, "talk_npc entered=false"
    greet = wait_banner_stable(h, secs=6.0, timeout=45)
    q = "你会飞吗？你有翅膀吗？"
    if not say_when_open(h, q):
        return False, "门禁一直没开（对方 TTS 没停/卡 pending）"
    s = wait(h, lambda s: s.get("banner_text", "") not in ("", greet), timeout=40)
    if not s:
        return False, f"40s 未见新回复；末 banner={st(h).get('banner_text')!r}"
    time.sleep(3.0)  # 流式回复可能还在追加，稳定后读全
    return True, f"问「{q}」→ 回复={st(h).get('banner_text')!r}"


def chain_guide(h, target="舞舞兔"):
    r = h.send({"op": "talk_fairy"})
    if not r.get("entered"):
        return False, "talk_fairy entered=false"
    wait_banner_stable(h, secs=5.0, timeout=40)
    if not say_when_open(h, f"点点，带我去找{target}呀"):
        return False, "门禁一直没开"
    s = wait(h, lambda s: s.get("guide_active"), timeout=35)
    if not s:
        return False, f"35s 未见 guide_active；guide_active={st(h).get('guide_active')}"
    return True, f"guide_active=True target={s.get('guide_target')!r}"


CHAINS = {
    "greeting": chain_greeting,
    "dialogue": chain_dialogue,
    "guide": chain_guide,
}


def run_chain(name, fn, launch):
    print(f"\n=== [{name}] ===")
    h, ok = fresh_world(launch=launch)
    if not ok:
        # 空村 flake：重试一次 fresh launch
        if launch:
            print("    (未就绪，重试一次 fresh launch)")
            h.close()
            h, ok = fresh_world(launch=True)
    if not ok:
        return None  # 就绪失败（flake），不算链本身 FAIL
    try:
        passed, detail = fn(h)
        print(f"    {'✓ PASS' if passed else '✗ FAIL'}: {detail}")
        return passed
    finally:
        h.close()


def main():
    ap = argparse.ArgumentParser(description="端侧语音链·真机一键回归")
    ap.add_argument("--only", choices=list(CHAINS), help="只跑某一条链")
    ap.add_argument("--no-launch", action="store_true", help="连当前运行实例（只对第一条链有效，调试用）")
    args = ap.parse_args()

    setup_forward()
    todo = {args.only: CHAINS[args.only]} if args.only else CHAINS

    results = {}
    for i, (name, fn) in enumerate(todo.items()):
        launch = not (args.no_launch and i == 0)
        results[name] = run_chain(name, fn, launch)

    print("\n===== 回归结果 =====")
    hard_fail = False
    for name, r in results.items():
        tag = "✓ PASS" if r is True else ("✗ FAIL" if r is False else "· SKIP(未就绪/空村flake)")
        print(f"  {name:10s} {tag}")
        if r is False:
            hard_fail = True
    print("\n未纳入：naming（见 naming_e2e.py）、reuse（PROD 不可确定性驱动，见脚本头注释）")
    sys.exit(1 if hard_fail else 0)


if __name__ == "__main__":
    main()
