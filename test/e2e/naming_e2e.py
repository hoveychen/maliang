#!/usr/bin/env python3
"""端侧语音 e2e：驱动「造物 → 起名」全流程（docs/voice-e2e-harness-design.md §4.4）。

⚠️ 造物现在走 **guided-creation 多轮引导**（docs/guided-creation-design.md）：说完造物意图后，服务端
先回 creation_prompt 追问（给谁做的 / 属性确认…），孩子逐轮点卡或语音应答，全部答完服务端才开造、
item_created 落背包、naming_item 置位进起名。老脚本「say 意图 → 直接等 naming_item」会在引导多轮上
**永远超时**（真机实测：naming_item 只在引导走完后才置位）。本脚本改为逐轮应答直到造物落地。

控制通道 = debug 构建里的本地 TCP 命令口（scripts/debug_cmd_server.gd，仅 OS.is_debug_build）。
真机走 `adb forward tcp:8577 tcp:8577` 把设备端口映到本机后连；桌面 debug 直连 127.0.0.1 即可。

⚠️ 真机注入不靠推 user:// 标志（Android 上 app 私有目录 adb 推不进）——改由 TCP `inject`
命令在运行时把端侧 ASR 换成 ScriptedAsr（见 VoiceCapture.use_scripted_asr）。所以流程第一步永远是 inject。

引导应答两条路（debug_cmd_server 命令）：
  - 有选项卡（state.creation_options 非空，如「给谁做的」）→ `{"op":"pick","optionId":..}`（category='recipient'
    选 self，否则选第一张）。
  - 开放问句（无卡，如「是那个会转圈的火箭，对吗？」）→ `{"op":"say","text":..}` 语音肯定应答。
每轮用 state.creation_question 变化判定「新一轮」，排除点卡后的过渡字幕（施法中…/拼上啦…）。

前置（真机）：
  1. 主 checkout 导带 harness 的 debug APK：scripts/export-apk.sh debug（worktree 导不了，ASR 模型 gitignored）。
  2. 装机：adb install -r build/... ；核对设备端 md5（华为 install -r 有装回旧包前科）。
  3. 起 App、进世界（脚本自动 talk_fairy 进与点点的对话，造物意图对她说）。

用法：
  # 真机（自动 adb forward + 起 App）：
  python3 test/e2e/naming_e2e.py --device --launch --intent "点点，帮我造一个火箭"
  # 已在世界里、只驱语音（不重启 App）：
  python3 test/e2e/naming_e2e.py --device --intent "点点，帮我造一个火箭" --name "冲天号"
  # 桌面 debug（直连，不走 adb）：
  python3 test/e2e/naming_e2e.py --host 127.0.0.1 --intent ... --name ...

判据（client 侧，可断言）：say(意图) 后进 in_creation；逐轮应答直到 bag_size 增长 / naming_item 置位
（=item_created，火箭落背包）。给了 --name 再驱起名（说名字→确认模式 accept）。服务端 nameVoiceAsset
是否落库需另核（debug 物品页 / muveectl curl 该 world 的 items）——本脚本打印提示，不代做。
"""

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
# 驱动 SDK 收编进 harness.py（ai-harness P5）；这里 re-export 供老调用方 from naming_e2e import 继续可用。
from harness import (Harness, HarnessError, adb, setup_forward, launch_app,  # noqa: F401,E402
                     PORT, PACKAGE, ADB, LAUNCH_ACTIVITY)

# 点卡后 _creation_q 的过渡字幕（不是新问句，别当作新一轮应答）
TRANSIENT_Q = {"施法中…", "施法中", "拼上啦…", "拼好啦！"}


def _say_until(h, text, progressed, desc, tries=4, timeout=25.0):
    """说一句并等「进展」(progressed(s) 为真)。真机真麦会与合成 PCM 打架、偶发空断句触发
    「我没听清」——撞上就清掉重说(最多 tries 次)。返回命中的快照或 None。"""
    for i in range(tries):
        if not h.say_when_open(text):
            print(f"    (第{i+1}次门禁没开,等等重说)")
            h.wait_banner_stable(secs=3.0, timeout=10.0)
            continue
        deadline = time.time() + timeout
        while time.time() < deadline:
            s = h.state()
            if progressed(s):
                return s
            if "没听清" in s.get("banner_text", ""):  # 真麦空断句干扰 → 重说
                print(f"    (第{i+1}次撞「我没听清」=真麦干扰,重说)")
                break
            time.sleep(1.5)
    return None


def _answer_prompt(h, snap, start_bag):
    """应答当前这一轮引导。**受限 harness（monkey 非 god）下不许用 pick 直选**：有卡就**真 tap 那张卡**
    （按 label 在 actions 里找 press:btn 去 do，取代旧 pick 后门）；无卡/卡没采到就 say 肯定应答。"""
    q = snap.get("creation_question", "")
    opts = snap.get("creation_options") or []
    cat = snap.get("creation_category", "")
    if opts:
        # 选中目标选项（recipient→self，否则第一张），按其 label 找真 press 卡去 do（真 tap，像孩子点卡）。
        target = next((o for o in opts if o.get("id") == "self"), None) if cat == "recipient" else None
        if target is None:
            target = opts[0]
        want = target.get("label", "")
        press = next((a["action_id"] for a in h.actions().get("actions", [])
                      if a.get("kind") == "press" and a.get("label") == want), None)
        if press:
            h.do(press)                      # 真 tap 造物卡（取代 pick 直选后门）
            print(f"    → 真 tap 卡「{want}」（{cat or '无类别'}）")
            return True
        print(f"    → 卡「{want}」没采到 press，转语音兜底")
    # 无卡（开放问句，如「对吗？」）或卡没采到 → 语音肯定应答；进展＝问句变了或造物完成。
    ans = (opts[0].get("label", "") if opts else "") or "对呀就是这样"
    got = _say_until(h, ans,
                     lambda s: (s.get("naming_item") or (s.get("bag_size", 0) or 0) > start_bag
                                or (s.get("in_creation") and s.get("creation_question", "") not in (q, "", *TRANSIENT_Q))),
                     "开放问句应答", tries=4, timeout=30.0)
    print(f"    → say {ans!r} 进展={got is not None}")
    return got is not None


def run(h, name="小火箭", intent="点点，帮我造一个火箭"):
    """造物(guided-creation 多轮)→起名 的**在世界内**核心（Flow Registry regression flow, depends=[enter_world]）。

    假设已进世界（enter_world 前置已跑）——故不做 pre_taps/等世界，直接从 inject 起。硬失败抛 HarnessError
    （runner 据此判 FAIL；老 run_flow 的返回 fails 计数模型对 flow 无效，flow 一律「抛=失败/正常返回=通过」）。
    参数化：`name`=给造物起的名字，`intent`=说给点点的造物意图。返回 {created, bag_size, naming_item, name}。
    """
    print("[1] inject：运行时换 ScriptedAsr（真机注入入口，不推标志文件）")
    r = h.inject()
    if not (r.get("ok") and r.get("injected") and r.get("ready")):
        raise HarnessError(f"inject 未成功（不在世界里？VoiceCapture 未就绪？）: {r}")
    print("  ✓ 已换 ScriptedAsr 且 ready")
    # 注：不再 reset_budget（清游玩冷却门是用户做不到的后门，受限 harness 已封）。连测撞冷却就换 fresh 实例。

    # 真输入 do talk:fairy 取代旧 talk_fairy op：实测旧 op 的 APPROACH 会中止回 EXPLORE、dialogue 从不建立、
    # mic 永不开（造物意图喂不进）；do talk:fairy 直接进 LISTENING+开麦（与 SKILL「优先 actions→do」一致）。
    # 刚进世界时仙子可能还没就绪，第一 tap 会 APPROACH→EXPLORE 中止；像真孩子那样多点几下（重试真 tap）。
    print("[2] 进与点点对话（真输入 do talk:fairy:<id>，未开麦就重点）")
    opened = False
    for attempt in range(4):
        acts = h.actions().get("actions", [])
        fairy = next((a["action_id"] for a in acts if a.get("action_id", "").startswith("talk:fairy:")), None)
        if not fairy:
            time.sleep(2.0)                  # 仙子还没 spawn，等一下再看（time.sleep 是纯 Python，非 harness op）
            continue
        h.do(fairy)                          # 真 tap 仙子
        # 给足时间等开麦——仙子招呼可能很长（如「魔法用完啦…」），10s 不够；过早重点会打断正在进行的对话，
        # 反把 VC 搞乱导致后面 say 喂不进（实测栽过）。只要进了对话就耐心等，不掉回 EXPLORE 就别再点。
        s = h.wait_until(lambda s: s.get("mic_open") or s.get("fsm_state") == "LISTENING",
                         "进对话+开麦", timeout=28.0, soft=True)
        if s and (s.get("mic_open") or s.get("fsm_state") == "LISTENING"):
            opened = True
            break
        print(f"    (第{attempt + 1}次没开麦 fsm={h.state().get('fsm_state')!r}，重点)")
    if not opened:
        raise HarnessError("反复 do talk:fairy 都没进对话开麦（仙子未就绪/approach 中止）")
    print(f"  ✓ 进对话开麦 banner={h.state().get('banner_text')!r}")

    start_bag = h.state().get("bag_size", 0) or 0
    print(f"[3] say 造物意图: 「{intent}」（初始 bag={start_bag}）")
    started = _say_until(h, intent,
                         lambda s: s.get("in_creation") or (s.get("bag_size", 0) or 0) > start_bag,
                         "造物意图→引导开启", tries=4, timeout=30.0)
    if started is None:
        raise HarnessError("造物意图反复没进引导（门禁没开 / 真麦干扰未克服）")
    print("  ✓ 意图已说出，进引导多轮应答…")

    print("[4] guided-creation 逐轮应答直到造物落背包")
    last_q = None
    created = None
    for rnd in range(8):
        def settled(s):
            if s.get("naming_item") or (s.get("bag_size", 0) or 0) > start_bag:
                return True
            if s.get("in_creation"):
                q = s.get("creation_question", "")
                if q and q != last_q and q not in TRANSIENT_Q:
                    return True
            return False
        snap = h.wait_state(settled, "新引导问句或造物完成", timeout=55.0)  # 超时抛 HarnessError=FAIL
        if snap.get("naming_item") or (snap.get("bag_size", 0) or 0) > start_bag:
            created = snap
            print(f"  ✓✓ 造物落地！bag={snap.get('bag_size')} naming_item={snap.get('naming_item')!r} banner={snap.get('banner_text')!r}")
            break
        q = snap.get("creation_question", "")
        labels = [o.get("label") for o in (snap.get("creation_options") or [])]
        print(f"  轮{rnd}: 问「{q}」options={labels}")
        last_q = q
        if not _answer_prompt(h, snap, start_bag):
            raise HarnessError(f"第{rnd}轮应答没喂进去")
    if created is None:
        raise HarnessError("8 轮内造物没落地（引导没走完）")

    # 造物成功。可选：起名收尾（naming_item 置位=已进起名子模式）
    if name and created.get("naming_item"):
        print(f"[5] say 名字: 「{name}」（起名子模式已开）")
        if h.say_when_open(name):
            time.sleep(1.5)
            snap = h.state()
            if snap.get("vc_confirming"):
                print("  · 确认模式：回放中，do confirm:confirm_accept 真 tap 采纳键")
                h.do("confirm:confirm_accept")   # 真 tap 采纳键（取代 accept 直触后门）
            try:
                h.wait_state(lambda s: not s.get("naming_item"),
                             "起名收尾 → naming_item 回空", timeout=25.0)
                print("  ✓ 起名收尾（naming_item 回空）")
            except HarnessError as e:
                print(f"  ⚠ 起名未收尾（可选步骤，不算硬失败）: {e}")
        else:
            print("  ⚠ 名字没喂进去（起名可选，不算硬失败）")
        print("\n[核验] 服务端 nameVoiceAsset 是否落库需另查：debug 物品页 / muveectl curl 该 world items。")

    return {"created": True, "bag_size": created.get("bag_size"),
            "naming_item": created.get("naming_item", ""), "name": name}


def run_flow(h, intent, name, pre_taps):
    """独立 CLI/真机入口：先 pre_taps 进世界 + 等就绪，再委托 run() 跑造物→起名核心。返回 fails 计数（0=通过）。

    （flow 化后核心在 run()；这里保留 pre_taps + 设备侧「等 vc_ready」的等待，是 flow 的 enter_world 前置不覆盖的
    真机启动段。）"""
    # [0] 进世界：标题页→世界的 pre_taps（如进世界按钮）+ 等世界就绪。inject 必须在世界里
    # （VoiceCapture.current 只在 world 场景 _ready 后才有；标题页 inject 会「no active VoiceCapture」）。
    for (x, y) in pre_taps:
        print(f"[0] 进世界 tap ({x},{y})")
        h.tap(x, y)
        time.sleep(0.6)
    if pre_taps:
        # 就绪＝服务端 bootstrap 完成：ws 连上 + 8 个服务端村民 + vc 就绪。只等「有村民」不够——
        # 本地种子村民(4)立即出现但 ws 未连=离线模式,造物意图发不出去(实测 npc=4/ws=False 时门禁不开)。
        print("[0] 等世界就绪（ws_open + npc≥8 + vc_ready，冷缓存慢填最多 120s）…")
        try:
            s = h.wait_state(lambda s: (s.get("npc_count") or 0) >= 8 and s.get("ws_open") and s.get("vc_ready"),
                             "世界就绪(ws+8村民+vc)", timeout=120.0, poll=2.0)
            print(f"  ✓ 世界就绪 npc={s.get('npc_count')} ws_open={s.get('ws_open')} vc_ready={s.get('vc_ready')}")
        except HarnessError as e:
            print(f"  ✗ {e}"); return 1
    try:
        run(h, name=name, intent=intent)
        return 0
    except HarnessError as e:
        print(f"  ✗ {e}")
        return 1


def main():
    ap = argparse.ArgumentParser(description="端侧语音 e2e：造物（guided-creation 多轮）→ 起名 全流程驱动")
    ap.add_argument("--host", default="127.0.0.1", help="命令口地址（桌面 debug 直连用）")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--device", action="store_true", help="真机模式：先 adb forward")
    ap.add_argument("--launch", action="store_true", help="起 App（配 --device）")
    ap.add_argument("--intent", default="点点，帮我造一个火箭", help="造物意图（说给点点）")
    ap.add_argument("--name", default="", help="给造物起的名字（可选；给了才驱起名收尾）")
    ap.add_argument("--tap", action="append", default=[], metavar="X,Y",
                    help="进世界前的预置盲坐标 tap（标题页→世界，可多次；inject 前执行）")
    ap.add_argument("--enter-tap", default="491,638", metavar="X,Y",
                    help="--launch 且未给 --tap 时，默认点这个进世界按钮坐标（本机=华为 Mate20Pro 的黄箭头）")
    args = ap.parse_args()

    pre_taps = []
    for t in args.tap:
        xs, ys = t.split(",")
        pre_taps.append((float(xs), float(ys)))
    # --launch 起 App 后停在标题页：没显式给 --tap 就自动补进世界 tap（否则 inject 会「不在世界」失败）。
    if args.launch and not pre_taps:
        xs, ys = args.enter_tap.split(",")
        pre_taps.append((float(xs), float(ys)))

    if args.device:
        setup_forward()
        if args.launch:
            launch_app()
            time.sleep(8.0)  # 等 App 起来 + 进世界（冷缓存慢填，真机可能更久）

    h = Harness(args.host, args.port)
    h.connect()
    print(f"[已连] {args.host}:{args.port}")
    try:
        fails = run_flow(h, args.intent, args.name, pre_taps)
    finally:
        h.close()

    if fails == 0:
        print("\n✅ e2e 造物: guided-creation 全流程走通，火箭落背包")
        sys.exit(0)
    print(f"\n❌ e2e 造物: {fails} 处失败")
    sys.exit(1)


if __name__ == "__main__":
    main()
