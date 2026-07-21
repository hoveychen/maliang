#!/usr/bin/env python3
"""game-pilot 一发式 CLI（ai-harness P6）：每次调用连上 harness 口、执行一条命令、打印 JSON、退出。

给「AI 当玩家」的会话用：感知→决策→动作循环里，每步就是一条 Bash 命令，无需现写 python。
配套 skill 见 .claude/skills/game-pilot/SKILL.md；SDK 见 test/e2e/harness.py。

用法（--port 缺省 8578=桌面；真机先 adb forward 后 --port 8577）：
  pilot_cli.py observe                     # 快照+UI 元素+截图(可截时)三合一
  pilot_cli.py access --texts              # 无障碍元素列表(3D 实体+2D 控件,各带 id+可用动作)
  pilot_cli.py actions                     # 当前可用动作扁平表(按 id 挑一条给 do)
  pilot_cli.py do talk:npc:pig_boss        # 执行动作(真输入优先);回包带 delta+新 actions
  pilot_cli.py do say --arg text="点点你好"  # 带参动作
  pilot_cli.py state / ui --texts / shot --out /tmp/s.jpg
  pilot_cli.py say "点点，帮我造一个火箭"
  pilot_cli.py tap 491 638 / drag x1 y1 x2 y2 --ms 400 / long-press x y / pinch x y --scale 0.5
  pilot_cli.py click --text "确认" / click --path /root/...
  pilot_cli.py phone open / phone app items / phone close
  pilot_cli.py pick self / accept / talk-fairy / talk-npc / inject / reset-budget / reset-intro
  pilot_cli.py scene forest / teleport 30 40 / teleport --near
  pilot_cli.py wait-world                  # 等 ws_open+npc≥8+vc_ready（进世界后必等）
  pilot_cli.py wait --key in_creation --truthy --timeout 30
  pilot_cli.py wait-banner --secs 4        # 等对方 TTS 放完（banner 稳定）

所有子命令支持 --trace DIR：命令+应答追加到 DIR/trace.jsonl（跨调用累积，audit/回放用）。
退出码：应答 ok=true → 0，否则 1。
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, HarnessError  # noqa: E402


def out(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=1))
    return 0 if obj.get("ok", True) else 1


def main():
    ap = argparse.ArgumentParser(description="game-pilot 一发式命令")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578, help="8578=桌面实例缺省；真机 forward 后用 8577")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--trace", default="", help="轨迹目录（追加 trace.jsonl+截图）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("state")
    p = sub.add_parser("ui")
    p.add_argument("--texts", action="store_true")
    p = sub.add_parser("access")   # 无障碍元素列表（3D 实体 + 2D 控件，各带 id + 动作）
    p.add_argument("--texts", action="store_true")
    sub.add_parser("actions")      # 当前可用动作扁平列表（按 id 挑一条给 do）
    p = sub.add_parser("do")       # 执行一个动作 id（真输入优先）
    p.add_argument("action")
    p.add_argument("--arg", action="append", default=[], metavar="K=V",
                   help="动作参数 k=v（可多次，如 say 的 --arg text=你好）")
    p = sub.add_parser("shot")
    p.add_argument("--out", default="")
    p.add_argument("--max-dim", type=int, default=960)
    p = sub.add_parser("observe")
    p.add_argument("--no-shot", action="store_true")
    p = sub.add_parser("say")
    p.add_argument("text")
    p = sub.add_parser("tap")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    for g in ("drag", "swipe"):
        p = sub.add_parser(g)
        for a in ("x1", "y1", "x2", "y2"):
            p.add_argument(a, type=float)
        p.add_argument("--ms", type=int, default=400 if g == "drag" else 250)
    p = sub.add_parser("long-press")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p.add_argument("--ms", type=int, default=700)
    p = sub.add_parser("pinch")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p.add_argument("--scale", type=float, default=0.5)
    p.add_argument("--ms", type=int, default=400)
    p.add_argument("--dist", type=float, default=80)
    p = sub.add_parser("click")
    p.add_argument("--text", default="")
    p.add_argument("--path", default="")
    p = sub.add_parser("phone")
    p.add_argument("action", choices=["open", "close", "app"])
    p.add_argument("id", nargs="?", default="")
    p = sub.add_parser("pick")
    p.add_argument("option_id")
    p = sub.add_parser("pickup")
    p.add_argument("tile_x", type=int)
    p.add_argument("tile_y", type=int)
    p.add_argument("--edge", type=int, default=-1)
    p = sub.add_parser("scene")
    p.add_argument("id")
    p = sub.add_parser("teleport")
    p.add_argument("tile_x", type=int, nargs="?")
    p.add_argument("tile_y", type=int, nargs="?")
    p.add_argument("--near", action="store_true")
    for name in ("inject", "accept", "replay", "retry", "talk-fairy", "reset-budget", "reset-intro"):
        sub.add_parser(name)
    p = sub.add_parser("talk-npc")
    p.add_argument("--name", default="", help="按名找村民进对话（缺省=列表第一个真实村民）")
    p = sub.add_parser("wait-world")
    p.add_argument("--timeout", type=float, default=120.0, dest="wtimeout")
    p.add_argument("--no-vc", action="store_true",
                   help="不等 vc_ready（桌面无端侧 ASR 时它只在 inject 之后才真）")
    p = sub.add_parser("wait")
    p.add_argument("--key", required=True)
    p.add_argument("--equals", default=None)
    p.add_argument("--truthy", action="store_true")
    p.add_argument("--gte", type=float, default=None)
    p.add_argument("--timeout", type=float, default=45.0, dest="wtimeout")
    p = sub.add_parser("wait-banner")
    p.add_argument("--secs", type=float, default=4.0)
    p.add_argument("--timeout", type=float, default=40.0, dest="wtimeout")

    args = ap.parse_args()
    h = Harness(args.host, args.port, timeout=args.timeout)
    try:
        h.connect(retries=3, delay=0.5)
    except HarnessError as e:
        return out({"ok": False, "error": str(e)})
    if args.trace:
        h.start_trace(args.trace)

    try:
        c = args.cmd
        if c == "state":
            return out(h.state())
        if c == "ui":
            return out(h.ui(texts=args.texts))
        if c == "access":
            return out(h.access(texts=args.texts))
        if c == "actions":
            return out(h.actions())
        if c == "do":
            kv = {}
            for item in args.arg:
                if "=" in item:
                    k, v = item.split("=", 1)
                    kv[k] = v
            return out(h.do(args.action, **kv))
        if c == "shot":
            path = h.screenshot(path=args.out or None, max_dim=args.max_dim)
            return out({"ok": True, "shot": path})
        if c == "observe":
            return out({"ok": True, **h.observe(shot=not args.no_shot)})
        if c == "say":
            return out(h.say(args.text))
        if c == "tap":
            return out(h.tap(args.x, args.y))
        if c in ("drag", "swipe"):
            fn = h.drag if c == "drag" else h.swipe
            return out(fn(args.x1, args.y1, args.x2, args.y2, ms=args.ms))
        if c == "long-press":
            return out(h.long_press(args.x, args.y, ms=args.ms))
        if c == "pinch":
            return out(h.pinch(args.x, args.y, scale=args.scale, ms=args.ms, dist=args.dist))
        if c == "click":
            return out(h.click_ui(text=args.text or None, path=args.path or None))
        if c == "phone":
            return out(h.phone(args.action, args.id or None))
        if c == "pick":
            return out(h.pick(args.option_id))
        if c == "pickup":
            return out(h.pickup(args.tile_x, args.tile_y, args.edge))
        if c == "scene":
            return out(h.scene(args.id))
        if c == "teleport":
            return out(h.teleport(args.tile_x, args.tile_y, near=args.near))
        if c == "wait-world":
            need_vc = not args.no_vc
            s = h.wait_state(lambda s: (s.get("npc_count") or 0) >= 8 and s.get("ws_open")
                             and (s.get("vc_ready") or not need_vc),
                             "世界就绪(ws+8村民%s)" % ("+vc" if need_vc else ""),
                             timeout=args.wtimeout, poll=2.0)
            return out(s)
        if c == "wait":
            def pred(s):
                v = s.get(args.key)
                if args.truthy:
                    return bool(v)
                if args.gte is not None:
                    return (v or 0) >= args.gte
                if args.equals is not None:
                    return str(v) == args.equals
                return v is not None
            return out(h.wait_state(pred, f"wait {args.key}", timeout=args.wtimeout))
        if c == "wait-banner":
            b = h.wait_banner_stable(secs=args.secs, timeout=args.wtimeout)
            return out({"ok": True, "banner_text": b})
        if c == "talk-npc":
            msg = {"op": "talk_npc"}
            if args.name:
                msg["name"] = args.name
            return out(h.send(msg))
        # 无参 op（inject/accept/…）：连字符转下划线直发
        return out(h.send({"op": c.replace("-", "_")}))
    except HarnessError as e:
        return out({"ok": False, "error": str(e)})
    finally:
        h.close()


if __name__ == "__main__":
    sys.exit(main())
