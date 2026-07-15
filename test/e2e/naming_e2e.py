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
import json
import socket
import subprocess
import sys
import time

PORT = 8577
PACKAGE = "com.hoveychen.maliang"
ADB = "/Users/hoveychen/Library/Android/sdk/platform-tools/adb"
LAUNCH_ACTIVITY = f"{PACKAGE}/com.godot.game.GodotAppLauncher"

# 点卡后 _creation_q 的过渡字幕（不是新问句，别当作新一轮应答）
TRANSIENT_Q = {"施法中…", "施法中", "拼上啦…", "拼好啦！"}


class HarnessError(Exception):
    pass


class Harness:
    """一个 TCP 命令口客户端：一行一条 JSON 命令，读回一行 JSON 应答。"""

    def __init__(self, host="127.0.0.1", port=PORT, timeout=12.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = None
        self.buf = b""

    def connect(self, retries=25, delay=1.0):
        last = None
        for _ in range(retries):
            try:
                self.sock = socket.create_connection((self.host, self.port), self.timeout)
                self.sock.settimeout(self.timeout)
                return
            except OSError as e:
                last = e
                time.sleep(delay)
        raise HarnessError(f"连不上 {self.host}:{self.port}（App 起了吗？adb forward 做了吗？）: {last}")

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def send(self, obj):
        line = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
        self.sock.sendall(line)
        return self._recv_line()

    def _recv_line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise HarnessError("连接被对端关闭（等应答时）")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        resp = json.loads(line.decode("utf-8"))
        if not resp.get("ok", False):
            print(f"  ⚠ 命令返回错误: {resp}", file=sys.stderr)
        return resp

    # ── 命令封装 ──
    def inject(self):
        return self.send({"op": "inject"})

    def say(self, text):
        return self.send({"op": "say", "text": text})

    def pick(self, option_id):
        return self.send({"op": "pick", "optionId": option_id})

    def tap(self, x, y):
        return self.send({"op": "tap", "x": x, "y": y})

    def talk_fairy(self):
        return self.send({"op": "talk_fairy"})

    def reset_budget(self):
        return self.send({"op": "reset_budget"})

    def state(self):
        return self.send({"op": "state"})

    def accept(self):
        return self.send({"op": "accept"})

    def wait_state(self, pred, desc, timeout=45.0, poll=1.0):
        """轮询 state 直到 pred(snapshot) 为真；超时抛错。返回命中的快照。"""
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = self.state()
            if pred(last):
                return last
            time.sleep(poll)
        raise HarnessError(f"等待超时: {desc}；最后一次快照={_brief(last)}")

    def wait_banner_stable(self, secs=4.0, timeout=40.0):
        """等 banner 连续 secs 秒不变（=对方 TTS 放完）再返回其值。"""
        deadline = time.time() + timeout
        last, since = None, time.time()
        while time.time() < deadline:
            b = self.state().get("banner_text", "")
            if b != last:
                last, since = b, time.time()
            elif time.time() - since >= secs:
                return last
            time.sleep(1.0)
        return last

    def say_when_open(self, text, tries=8):
        """门禁开着才真喂（对方说完）。关着就等 banner 稳再试。返回是否喂进去。"""
        for _ in range(tries):
            r = self.say(text)
            if r.get("fed"):
                return True
            self.wait_banner_stable(secs=3.0, timeout=12.0)
        return False


def _brief(s):
    if not s:
        return s
    keys = ("in_creation", "creation_category", "creation_question", "creation_options",
            "naming_item", "bag_size", "banner_text", "ws_open")
    return {k: s.get(k) for k in keys if k in s}


def adb(*args):
    return subprocess.run([ADB, *args], capture_output=True, text=True)


def setup_forward():
    r = adb("forward", f"tcp:{PORT}", f"tcp:{PORT}")
    if r.returncode != 0:
        raise HarnessError(f"adb forward 失败: {r.stderr.strip()}")
    print(f"[adb] forward tcp:{PORT} → 设备 tcp:{PORT}")


def launch_app():
    adb("shell", "am", "force-stop", PACKAGE)
    r = adb("shell", "am", "start", "-n", LAUNCH_ACTIVITY)
    if r.returncode != 0:
        raise HarnessError(f"起 App 失败: {r.stderr.strip()}")
    print(f"[adb] 起 App {LAUNCH_ACTIVITY}")


def _answer_prompt(h, snap):
    """应答当前这一轮引导：有卡就 pick（recipient→self，否则第一张），无卡开放问就 say 肯定。"""
    opts = snap.get("creation_options") or []
    cat = snap.get("creation_category", "")
    if opts:
        oid = None
        if cat == "recipient":
            for o in opts:
                if o.get("id") == "self":
                    oid = o["id"]
                    break
        if oid is None:
            oid = opts[0]["id"]
        r = h.pick(oid)
        print(f"    → pick optionId={oid!r}（{cat or '无类别'}）picked={r.get('picked')}")
        return bool(r.get("picked"))
    # 无卡 = 开放语音问句（如属性确认「对吗？」）：语音肯定应答
    ans = "对呀就是这样"
    fed = h.say_when_open(ans)
    print(f"    → say {ans!r} fed={fed}")
    return fed


def run_flow(h, intent, name, pre_taps):
    fails = 0

    print("[1] inject：运行时换 ScriptedAsr（真机注入入口，不推标志文件）")
    r = h.inject()
    if not (r.get("ok") and r.get("injected") and r.get("ready")):
        print(f"  ✗ inject 未成功: {r}"); return 1
    print("  ✓ 已换 ScriptedAsr 且 ready")
    h.reset_budget()  # 清游玩时长冷却门，免得连测被拦

    for (x, y) in pre_taps:
        print(f"[*] 预置 tap ({x},{y})")
        h.send({"op": "tap", "x": x, "y": y})
        time.sleep(0.6)

    print("[2] talk_fairy：进与点点的对话（造物意图对她说）")
    r = h.talk_fairy()
    if not r.get("entered"):
        print(f"  ✗ talk_fairy 没进对话（无仙子？不在世界？）: {r}"); return 1
    greet = h.wait_banner_stable(secs=4.0, timeout=40.0)
    print(f"  ✓ 进对话，招呼稳定 banner={greet!r}")

    start_bag = h.state().get("bag_size", 0) or 0
    print(f"[3] say 造物意图: 「{intent}」（初始 bag={start_bag}）")
    if not h.say_when_open(intent):
        print("  ✗ 意图没喂进去（门禁一直没开 / 不在对话态）"); return 1
    print("  ✓ 意图已说出，进引导多轮应答…")

    print("[4] guided-creation 逐轮应答直到火箭落背包")
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
        try:
            snap = h.wait_state(settled, "新引导问句或造物完成", timeout=55.0)
        except HarnessError as e:
            print(f"  ✗ 第{rnd}轮 {e}"); fails += 1; break
        if snap.get("naming_item") or (snap.get("bag_size", 0) or 0) > start_bag:
            created = snap
            print(f"  ✓✓ 造物落地！bag={snap.get('bag_size')} naming_item={snap.get('naming_item')!r} banner={snap.get('banner_text')!r}")
            break
        q = snap.get("creation_question", "")
        labels = [o.get("label") for o in (snap.get("creation_options") or [])]
        print(f"  轮{rnd}: 问「{q}」options={labels}")
        last_q = q
        if not _answer_prompt(h, snap):
            print(f"  ✗ 第{rnd}轮应答没喂进去"); fails += 1; break
    else:
        print("  ✗ 8 轮内造物没落地（引导没走完）"); fails += 1

    if created is None:
        print(f"  末态: {_brief(h.state())}")
        return max(fails, 1)

    # 造物成功。可选：起名收尾（naming_item 置位=已进起名子模式）
    if name and created.get("naming_item"):
        print(f"[5] say 名字: 「{name}」（起名子模式已开）")
        if h.say_when_open(name):
            time.sleep(1.5)
            snap = h.state()
            if snap.get("vc_confirming"):
                print("  · 确认模式：回放中，发 accept 采纳")
                h.accept()
            try:
                h.wait_state(lambda s: not s.get("naming_item"),
                             "起名收尾 → naming_item 回空", timeout=25.0)
                print("  ✓ 起名收尾（naming_item 回空）")
            except HarnessError as e:
                print(f"  ⚠ 起名未收尾（可选步骤，不算硬失败）: {e}")
        else:
            print("  ⚠ 名字没喂进去（起名可选，不算硬失败）")
        print("\n[核验] 服务端 nameVoiceAsset 是否落库需另查：debug 物品页 / muveectl curl 该 world items。")

    return fails


def main():
    ap = argparse.ArgumentParser(description="端侧语音 e2e：造物（guided-creation 多轮）→ 起名 全流程驱动")
    ap.add_argument("--host", default="127.0.0.1", help="命令口地址（桌面 debug 直连用）")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--device", action="store_true", help="真机模式：先 adb forward")
    ap.add_argument("--launch", action="store_true", help="起 App（配 --device）")
    ap.add_argument("--intent", default="点点，帮我造一个火箭", help="造物意图（说给点点）")
    ap.add_argument("--name", default="", help="给造物起的名字（可选；给了才驱起名收尾）")
    ap.add_argument("--tap", action="append", default=[], metavar="X,Y",
                    help="talk_fairy 前的预置盲坐标 tap（如从标题页进世界，可多次）")
    args = ap.parse_args()

    pre_taps = []
    for t in args.tap:
        xs, ys = t.split(",")
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
