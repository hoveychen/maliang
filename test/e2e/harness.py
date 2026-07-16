#!/usr/bin/env python3
"""maliang AI/e2e 驱动 SDK（ai-harness P5）——debug TCP 命令口的正式客户端。

游戏内对端 = scripts/debug_cmd_server.gd（仅 debug 构建，release 一行不跑）。协议：一行一条
JSON 命令、回一行 JSON 应答；手势类命令（drag/swipe/long_press/pinch）在手势完成时才回包。

三种接入：
  桌面 debug 实例   Harness()（直连 127.0.0.1:8577；多实例并存用 MALIANG_HARNESS_PORT 换口）
  Android 真机      setup_forward() 后 Harness()（adb forward 把设备口映到本机）
  桌面自起实例      launch_desktop(port=8578) 起 Godot debug 进程再 Harness(port=8578)

感知三件套（AI 驱动主路）：
  h.state()          结构化快照（fsm_state/mic_open/player_pos/wallet/bag_items/npcs/手机/摆放…）
  h.ui(texts=True)   可点/可读元素枚举（含屏幕矩形与 viewport 标记）
  h.screenshot(path) 截图 JPEG 直接回传落本地（真机 user:// adb 拉不出来，走 TCP）
  h.observe()        以上三合一打包（供 LLM 一次读全）

轨迹录制：h.start_trace(dir) 后每条命令+应答落 trace.jsonl、截图落同目录——回放审计/QA 报告原料。
"""

import base64
import json
import os
import socket
import subprocess
import sys
import time

PORT = 8577
PACKAGE = "com.hoveychen.maliang"
ADB = "/Users/hoveychen/Library/Android/sdk/platform-tools/adb"
LAUNCH_ACTIVITY = f"{PACKAGE}/com.godot.game.GodotAppLauncher"
GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"


class HarnessError(Exception):
    pass


def _brief(s):
    """快照瘦身（报错/日志用）：只留判断走向的关键字段。"""
    if not s:
        return s
    keys = ("fsm_state", "mic_open", "in_creation", "creation_category", "creation_question",
            "creation_options", "naming_item", "bag_size", "banner_text", "ws_open",
            "scene_id", "phone_open", "placing", "npc_count")
    return {k: s.get(k) for k in keys if k in s}


class Harness:
    """TCP 命令口客户端：一行一条 JSON 命令，读回一行 JSON 应答。"""

    def __init__(self, host="127.0.0.1", port=PORT, timeout=15.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = None
        self.buf = b""
        self.trace_dir = None
        self._trace_fp = None
        self._shot_n = 0

    # ── 连接 ──
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
        if self._trace_fp:
            self._trace_fp.close()
            self._trace_fp = None

    def reconnect(self, retries=3, delay=1.0):
        """只重建 socket（trace 不动）。对端是单连接模型（新连接顶掉旧的）——被顶/瞬断后用它复位。"""
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        self.buf = b""
        self.connect(retries=retries, delay=delay)

    # ── 轨迹录制 ──
    def start_trace(self, trace_dir):
        """开录：此后每条命令+应答追加到 <dir>/trace.jsonl，截图落同目录。"""
        os.makedirs(trace_dir, exist_ok=True)
        self.trace_dir = trace_dir
        self._trace_fp = open(os.path.join(trace_dir, "trace.jsonl"), "a", encoding="utf-8")
        return trace_dir

    def _trace(self, rec):
        if self._trace_fp:
            rec = {"t": round(time.time(), 3), **rec}
            self._trace_fp.write(json.dumps(rec, ensure_ascii=False) + "\n")
            self._trace_fp.flush()

    # ── 收发 ──
    def send(self, obj, timeout=None):
        line = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
        self.sock.sendall(line)
        resp = self._recv_line(timeout)
        # trace 里截图 base64 只记长度，不落原文（jsonl 不该被一张图撑爆）
        logged = {k: (f"<b64:{len(v)}>" if k == "jpg_b64" else v) for k, v in resp.items()}
        self._trace({"cmd": obj, "reply": logged})
        return resp

    def _recv_line(self, timeout=None):
        if timeout is not None:
            self.sock.settimeout(timeout)
        try:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise HarnessError("连接被对端关闭（等应答时）")
                self.buf += chunk
        finally:
            if timeout is not None:
                self.sock.settimeout(self.timeout)
        line, self.buf = self.buf.split(b"\n", 1)
        resp = json.loads(line.decode("utf-8"))
        if not resp.get("ok", False):
            print(f"  ⚠ 命令返回错误: {resp}", file=sys.stderr)
        return resp

    # ── 语音/对话 ──
    def inject(self):
        return self.send({"op": "inject"})

    def say(self, text):
        return self.send({"op": "say", "text": text})

    def pick(self, option_id):
        return self.send({"op": "pick", "optionId": option_id})

    def accept(self):
        return self.send({"op": "accept"})

    def replay(self):
        return self.send({"op": "replay"})

    def retry(self):
        return self.send({"op": "retry"})

    def talk_fairy(self):
        return self.send({"op": "talk_fairy"})

    def talk_npc(self):
        return self.send({"op": "talk_npc"})

    # ── 触屏/手势（手势完成才回包：读超时按手势时长放宽）──
    def tap(self, x, y):
        return self.send({"op": "tap", "x": x, "y": y})

    def drag(self, x1, y1, x2, y2, ms=400):
        return self.send({"op": "drag", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": ms},
                         timeout=self.timeout + ms / 1000.0)

    def swipe(self, x1, y1, x2, y2, ms=250):
        return self.send({"op": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": ms},
                         timeout=self.timeout + ms / 1000.0)

    def long_press(self, x, y, ms=700):
        return self.send({"op": "long_press", "x": x, "y": y, "ms": ms},
                         timeout=self.timeout + ms / 1000.0)

    def pinch(self, x, y, scale=0.5, ms=400, dist=80):
        return self.send({"op": "pinch", "x": x, "y": y, "scale": scale, "ms": ms, "dist": dist},
                         timeout=self.timeout + ms / 1000.0)

    # ── 语义动作 ──
    def click_ui(self, text=None, path=None):
        cmd = {"op": "click_ui"}
        if text:
            cmd["text"] = text
        if path:
            cmd["path"] = path
        return self.send(cmd)

    def phone(self, action, app_id=None):
        cmd = {"op": "phone", "action": action}
        if app_id:
            cmd["id"] = app_id
        return self.send(cmd)

    def pickup(self, tile_x, tile_y, edge_side=-1):
        return self.send({"op": "pickup", "tileX": tile_x, "tileY": tile_y, "edgeSide": edge_side})

    def teleport(self, tile_x=None, tile_y=None, near=False):
        cmd = {"op": "teleport", "near": near}
        if tile_x is not None:
            cmd.update({"tileX": tile_x, "tileY": tile_y})
        return self.send(cmd)

    def scene(self, scene_id):
        return self.send({"op": "scene", "id": scene_id})

    def photo(self, **kwargs):
        return self.send({"op": "photo", **kwargs})

    def reset_budget(self):
        return self.send({"op": "reset_budget"})

    # ── 感知 ──
    def state(self):
        return self.send({"op": "state"})

    def ui(self, texts=False):
        return self.send({"op": "ui", "texts": texts})

    def screenshot(self, path=None, max_dim=960, quality=0.75):
        """截图走 wire 回传并落本地 JPEG，返回文件路径（缺省落 trace 目录自动编号）。"""
        r = self.send({"op": "screencap", "wire": True, "max_dim": max_dim, "quality": quality})
        if not r.get("ok"):
            raise HarnessError(f"screencap 失败: {r}")
        if path is None:
            base = self.trace_dir or "."
            self._shot_n += 1
            path = os.path.join(base, f"shot_{self._shot_n:04d}.jpg")
        with open(path, "wb") as f:
            f.write(base64.b64decode(r["jpg_b64"]))
        self._trace({"shot": path, "w": r.get("w"), "h": r.get("h")})
        return path

    def observe(self, texts=True, shot=True, max_dim=960):
        """感知三合一：结构化快照 + UI 元素 + 截图路径。供 AI 一次读全再决策。"""
        out = {"state": self.state(), "ui": self.ui(texts=texts).get("elements", [])}
        if shot:
            try:
                out["shot"] = self.screenshot(max_dim=max_dim)
            except HarnessError as e:
                out["shot_error"] = str(e)
        return out

    # ── 等待谓词 ──
    def _state_soft(self):
        """轮询版 state：单次超时/瞬断（换场景黑幕、对端忙）不炸循环，返回 {}。"""
        try:
            return self.state()
        except (OSError, HarnessError, json.JSONDecodeError):
            return {}

    def wait_state(self, pred, desc, timeout=45.0, poll=1.0):
        """轮询 state 直到 pred(snapshot) 为真；超时抛错。返回命中的快照。
        轮询中的单次通讯失败不中断等待（换场景/黑幕期对端可能不应答）。"""
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            s = self._state_soft()
            if s:
                last = s
                if pred(s):
                    return s
            time.sleep(poll)
        raise HarnessError(f"等待超时: {desc}；最后一次快照={_brief(last)}")

    def wait_banner_stable(self, secs=4.0, timeout=40.0):
        """等 banner 连续 secs 秒不变（=对方 TTS 放完）再返回其值。"""
        deadline = time.time() + timeout
        last, since = None, time.time()
        while time.time() < deadline:
            b = self._state_soft().get("banner_text", "")
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


# ── Android 真机 ──
def adb(*args):
    return subprocess.run([ADB, *args], capture_output=True, text=True)


def setup_forward(port=PORT):
    r = adb("forward", f"tcp:{port}", f"tcp:{port}")
    if r.returncode != 0:
        raise HarnessError(f"adb forward 失败: {r.stderr.strip()}")
    print(f"[adb] forward tcp:{port} → 设备 tcp:{port}")


def remove_forward(port=PORT):
    """跑完拆转发——留着会占口害 headless test_harness_wire 挂（踩过）。"""
    adb("forward", "--remove", f"tcp:{port}")


def launch_app():
    adb("shell", "am", "force-stop", PACKAGE)
    r = adb("shell", "am", "start", "-n", LAUNCH_ACTIVITY)
    if r.returncode != 0:
        raise HarnessError(f"起 App 失败: {r.stderr.strip()}")
    print(f"[adb] 起 App {LAUNCH_ACTIVITY}")


# ── 桌面 debug 实例 ──
def launch_desktop(project_root, port=8578, godot=None, extra_env=None, extra_args=()):
    """起一个桌面 debug 实例（带窗），harness 口开在 port。返回 Popen（调用方负责 terminate）。

    8577 常被 adb/iproxy 转发到真机占走——桌面驱动固定换口，免得命令赛跑打进别人的设备。
    """
    env = dict(os.environ, MALIANG_HARNESS_PORT=str(port))
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen([godot or GODOT, "--path", project_root, *extra_args],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
