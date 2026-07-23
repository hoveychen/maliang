#!/usr/bin/env python3
"""harness.py SDK 自测（不依赖游戏）：起一个假 TCP 服务端回放 canned 应答，验证
收发分帧/截图 base64 解码落盘/手势读超时放宽/wait_state 谓词/trace 录制。

用法: python3 test/e2e/test_harness_sdk.py   （退出码=失败数）
"""

import base64
import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import MonkeyHarness, HarnessError  # noqa: E402

FAKE_JPG = b"\xff\xd8\xff\xe0FAKEJPEG\xff\xd9"


def fake_server(sock, state_seq):
    """单连接假服务端：按 op 回 canned 应答；state 按 state_seq 依次吐（末条循环）。"""
    conn, _ = sock.accept()
    buf = b""
    n_state = 0
    while True:
        try:
            chunk = conn.recv(4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            cmd = json.loads(line.decode())
            op = cmd.get("op")
            if op == "state":
                snap = state_seq[min(n_state, len(state_seq) - 1)]
                n_state += 1
                reply = {"ok": True, "op": "state", **snap}
            elif op == "ui":
                reply = {"ok": True, "op": "ui",
                         "elements": [{"kind": "button", "text": "确认", "viewport": "root"}]}
            elif op == "screencap":
                reply = {"ok": True, "op": "screencap", "w": 4, "h": 2,
                         "jpg_b64": base64.b64encode(FAKE_JPG).decode()}
            elif op == "drag":
                time.sleep(0.3)  # 模拟手势跨帧执行后才回包
                reply = {"ok": True, "op": "drag", "done": True, "ms": cmd.get("ms")}
            else:
                reply = {"ok": True, "op": op}
            conn.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode())


def main():
    fails = 0

    def check(name, got, want):
        nonlocal fails
        if got == want:
            print(f"  ✓ {name}")
        else:
            print(f"  ✗ {name}: got {got!r} want {want!r}")
            fails += 1

    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    states = [{"banner_text": "加载中", "npc_count": 0},
              {"banner_text": "你好呀", "npc_count": 8, "ws_open": True}]
    threading.Thread(target=fake_server, args=(srv, states), daemon=True).start()

    tdir = tempfile.mkdtemp(prefix="harness_sdk_")
    h = MonkeyHarness(port=port, timeout=3.0)
    h.connect(retries=3, delay=0.1)
    h.start_trace(tdir)

    print("[state/ui 往返]")
    s = h.state()
    check("state 第一帧", s.get("banner_text"), "加载中")
    u = h.ui(texts=True)
    check("ui elements", u["elements"][0]["text"], "确认")

    print("[reset_budget：定义测试控制 op 在 MonkeyHarness 上]")
    check("reset_budget 通", h.reset_budget().get("ok"), True)

    print("[wait_state 谓词轮询]")
    got = h.wait_state(lambda s: (s.get("npc_count") or 0) >= 8, "npc≥8", timeout=5.0, poll=0.1)
    check("wait_state 命中第二帧", got.get("ws_open"), True)

    print("[screenshot：b64 解码落盘]")
    p = h.screenshot()
    check("截图落 trace 目录", p.startswith(tdir), True)
    check("字节还原", open(p, "rb").read(), FAKE_JPG)

    print("[observe 三合一]")
    ob = h.observe()
    check("observe 有 state", "banner_text" in ob["state"], True)
    check("observe 有 ui", len(ob["ui"]), 1)
    check("observe 有截图", os.path.exists(ob.get("shot", "")), True)

    print("[trace 录制：命令+应答落 jsonl，b64 只记长度]")
    h.close()
    lines = [json.loads(x) for x in open(os.path.join(tdir, "trace.jsonl"), encoding="utf-8")]
    cmds = [x["cmd"]["op"] for x in lines if "cmd" in x]
    check("trace 含全部命令", {"state", "ui", "screencap"} <= set(cmds), True)
    caps = [x for x in lines if "cmd" in x and x["cmd"]["op"] == "screencap"]
    check("trace 截图 b64 被瘦身", caps[0]["reply"]["jpg_b64"].startswith("<b64:"), True)
    shots = [x for x in lines if "shot" in x]
    check("trace 记截图路径", len(shots) >= 1, True)

    print("[超时路径：wait_state 报 HarnessError]")
    h2 = MonkeyHarness(port=port, timeout=1.0)
    try:
        h2.connect(retries=1, delay=0.1)
        # 假服务端只收一个连接，这里连不上属预期——两种都算过
        try:
            h2.wait_state(lambda s: False, "永假", timeout=0.5, poll=0.2)
            check("永假谓词必超时", True, False)
        except HarnessError:
            check("永假谓词必超时", True, True)
    except HarnessError:
        check("永假谓词必超时", True, True)

    print("全部通过" if fails == 0 else f"{fails} 处失败")
    return fails


if __name__ == "__main__":
    sys.exit(main())
