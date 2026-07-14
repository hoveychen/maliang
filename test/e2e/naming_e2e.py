#!/usr/bin/env python3
"""端侧语音 e2e：驱动「造物 → 起名」全流程（docs/voice-e2e-harness-design.md §4.4）。

控制通道 = debug 构建里的本地 TCP 命令口（scripts/debug_cmd_server.gd，仅 OS.is_debug_build）。
真机走 `adb forward tcp:8577 tcp:8577` 把设备端口映到本机后连；桌面 debug 直连 127.0.0.1 即可。

⚠️ 真机注入不靠推 user:// 标志（Android 上 app 私有目录 adb 推不进）——改由 TCP `inject`
命令在运行时把端侧 ASR 换成 ScriptedAsr（见 VoiceCapture.use_scripted_asr）。所以流程第一步永远是 inject。

前置（真机）：
  1. 主 checkout 导带 harness 的 debug APK：scripts/export-apk.sh debug（worktree 导不了，ASR 模型 gitignored）。
  2. 装机：adb install -r build/... ；核对设备端 md5（华为 install -r 有装回旧包前科）。
  3. 起 App、进世界、走到小仙子「点点」附近（造物意图要在与她对话时说）。

用法：
  # 真机（自动 adb forward + 起 App）：
  python3 test/e2e/naming_e2e.py --device --launch --intent "帮我造一个梯子" --name "爬爬梯"
  # 已在对话态、只驱语音：
  python3 test/e2e/naming_e2e.py --device --intent "帮我造一个梯子" --name "爬爬梯"
  # 桌面 debug（直连，不走 adb）：
  python3 test/e2e/naming_e2e.py --host 127.0.0.1 --intent ... --name ...

流程完成的判据（client 侧，可断言）：say(意图) 后 _naming_item 由空转非空（起名子模式开）；
say(名字)+（确认模式下）accept 后 _naming_item 回空（起名收尾）。服务端 nameVoiceAsset 是否落库
需另核（debug 物品页 / muveectl curl 该 world 的 items）——本脚本打印提示，不代做（要 world id + admin token）。
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


class HarnessError(Exception):
    pass


class Harness:
    """一个 TCP 命令口客户端：一行一条 JSON 命令，读回一行 JSON 应答。"""

    def __init__(self, host="127.0.0.1", port=PORT, timeout=10.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = None
        self.buf = b""

    def connect(self, retries=20, delay=0.5):
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
        """发一条命令，返回解析后的应答 dict。"""
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

    def tap(self, x, y):
        return self.send({"op": "tap", "x": x, "y": y})

    def state(self):
        return self.send({"op": "state"})

    def screencap(self):
        return self.send({"op": "screencap"})

    def accept(self):
        return self.send({"op": "accept"})

    def wait_state(self, pred, desc, timeout=15.0, poll=0.4):
        """轮询 state 直到 pred(snapshot) 为真；超时抛错。返回命中的快照。"""
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = self.state()
            if pred(last):
                return last
            time.sleep(poll)
        raise HarnessError(f"等待超时: {desc}；最后一次快照={last}")


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


def pull_screencap(h, local_path):
    """先让设备截一帧落 user://，再 adb pull 回本机（真机路径需按 Godot user:// 映射）。"""
    resp = h.screencap()
    if not resp.get("ok"):
        print(f"  ⚠ screencap 失败: {resp}")
        return
    dev_path = resp.get("path", "")
    # user:// → 设备内部私有目录，adb pull 一般拉不到（需 run-as）。这里只打印设备侧路径，
    # 真要取回用：adb exec-out run-as com.hoveychen.maliang cat <dev_path> > local.png
    print(f"  截图落设备: {dev_path} → 取回: {ADB} exec-out run-as {PACKAGE} cat '{dev_path}' > {local_path}")


def run_flow(h, intent, name, pre_taps):
    fails = 0

    print("[1] inject：运行时换 ScriptedAsr（真机注入入口，不推标志文件）")
    r = h.inject()
    if not (r.get("ok") and r.get("injected") and r.get("ready")):
        print(f"  ✗ inject 未成功: {r}"); return 1
    print("  ✓ 已换 ScriptedAsr 且 ready")

    for (x, y) in pre_taps:
        print(f"[*] 预置 tap ({x},{y}) —— 进对话/选中小仙子等（盲坐标，按设备定）")
        h.tap(x, y)
        time.sleep(0.6)

    print(f"[2] say 造物意图: 「{intent}」（喂 PCM 驱 VAD 断句 → 走后端 → 造物）")
    r = h.say(intent)
    if not r.get("fed"):
        print(f"  ✗ 意图没喂进去（门禁没开？不在对话态？）: {r}"); return 1
    print("  ✓ 意图已说出，等后端造物 + 起名子模式开启…")

    try:
        snap = h.wait_state(lambda s: s.get("naming_item", "") != "",
                            "item_created → _naming_item 置位（起名开）", timeout=40.0)
        print(f"  ✓ 起名开启，naming_item={snap.get('naming_item')!r}")
    except HarnessError as e:
        print(f"  ✗ {e}"); return 1

    pull_screencap(h, "e2e_naming_open.png")

    print(f"[3] say 名字: 「{name}」")
    r = h.say(name)
    if not r.get("fed"):
        print(f"  ✗ 名字没喂进去: {r}"); return 1

    # 确认模式：说完先回放，等 accept。非确认模式：直接落库。轮询看是否进确认。
    time.sleep(1.5)
    snap = h.state()
    if snap.get("vc_confirming"):
        print("  · 确认模式：回放中，发 accept 采纳")
        h.accept()
        time.sleep(0.5)

    try:
        h.wait_state(lambda s: s.get("naming_item", "") == "",
                    "起名收尾 → _naming_item 回空", timeout=20.0)
        print("  ✓ 起名收尾（naming_item 回空）")
    except HarnessError as e:
        print(f"  ✗ {e}"); fails += 1

    pull_screencap(h, "e2e_naming_done.png")

    print("\n[核验] 服务端 nameVoiceAsset 是否落库需另查（本脚本不代做）：")
    print("  debug 物品页，或 muveectl projects curl <maliang-server-id> 该 world 的 items，")
    print("  确认刚起名的造物 nameVoiceAsset 非空（孩子录音）+ nameText 为识别文本。")
    return fails


def main():
    ap = argparse.ArgumentParser(description="端侧语音 e2e：造物 → 起名 全流程驱动")
    ap.add_argument("--host", default="127.0.0.1", help="命令口地址（桌面 debug 直连用）")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--device", action="store_true", help="真机模式：先 adb forward")
    ap.add_argument("--launch", action="store_true", help="起 App（配 --device）")
    ap.add_argument("--intent", default="帮我造一个梯子", help="造物意图（说给小仙子）")
    ap.add_argument("--name", default="爬爬梯", help="给造物起的名字")
    ap.add_argument("--tap", action="append", default=[], metavar="X,Y",
                    help="say 意图前的预置盲坐标 tap（进对话/选中，可多次）")
    args = ap.parse_args()

    pre_taps = []
    for t in args.tap:
        xs, ys = t.split(",")
        pre_taps.append((float(xs), float(ys)))

    if args.device:
        setup_forward()
        if args.launch:
            launch_app()
            time.sleep(4.0)  # 等 App 起来 + 进世界

    h = Harness(args.host, args.port)
    h.connect()
    print(f"[已连] {args.host}:{args.port}")
    try:
        fails = run_flow(h, args.intent, args.name, pre_taps)
    finally:
        h.close()

    if fails == 0:
        print("\n✅ e2e naming: 客户端流程全部走通")
        sys.exit(0)
    print(f"\n❌ e2e naming: {fails} 处失败")
    sys.exit(1)


if __name__ == "__main__":
    main()
