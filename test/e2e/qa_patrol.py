#!/usr/bin/env python3
"""QA 自主巡检（ai-harness P7）：AI/随机策略自主玩游戏 N 分钟，记录异常，产出巡检报告。

策略是「状态感知的加权随机」：读 state 决定当下合法动作集（menu 点进入、对话中说话/退出、
造物引导中应答、探索态则 走路/对话/手机/手势/切场景 里抽一个），每步动作后核对回包与状态。

异常检测（每步）：
  reply_error    命令回包 ok=false（预期内的除外，如 gate_closed）
  ws_drop        ws_open 从 true 掉 false
  npc_dead       npcs 明细里出现 dead=true
  stuck_transition  transitioning 连续 >30s
  stuck_thinking    fsm_state=THINKING 连续 >60s
  conn_lost      TCP 断（游戏进程崩了）——巡检终止并记 fatal

产出：<trace_dir>/report.md + trace.jsonl（每步命令+应答）+ 截图（带窗实例才有）。

用法：
  python3 test/e2e/qa_patrol.py --minutes 3 --port 8578 [--seed 7] [--allow-create]
  （缺省不主动发起造物意图——巡检别往老板的 PROD 世界里乱造东西；--allow-create 才开）

退出码 = 异常条数（fatal 记 100）。
"""

import argparse
import json
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Harness, HarnessError  # noqa: E402

CHAT_LINES = ["你好呀", "你在做什么呀", "今天天气真好", "再见啦"]
NAME_POOL = ["小可爱", "亮晶晶", "圆滚滚"]
CREATE_INTENTS = ["点点，帮我造一个小星星"]
SCENES = ["village", "forest"]
# 造物引导的过渡字幕（同 naming_e2e.TRANSIENT_Q）：不是新问句
TRANSIENT_Q = {"施法中…", "施法中", "拼上啦…", "拼好啦！"}


class Patrol:
    def __init__(self, h, rng, allow_create, log):
        self.h = h
        self.rng = rng
        self.allow_create = allow_create
        self.log = log
        self.anomalies = []
        self.actions = {}
        self.steps = 0
        self._last_ws = None
        self._trans_since = None
        self._think_since = None
        self._injected = False

    def note(self, kind, detail):
        rec = {"t": round(time.time(), 1), "kind": kind, "detail": detail}
        self.anomalies.append(rec)
        self.log(f"  ⚠ 异常[{kind}] {detail}")

    def bump(self, name):
        self.actions[name] = self.actions.get(name, 0) + 1
        self.steps += 1

    # ── 不变量哨兵：每步扫一遍 state ──
    def watch(self, s):
        now = time.time()
        ws = s.get("ws_open")
        if self._last_ws is True and ws is False:
            self.note("ws_drop", "ws_open true→false")
        if ws is not None:
            self._last_ws = ws
        for n in s.get("npcs", []):
            if n.get("dead"):
                self.note("npc_dead", f"npc {n.get('id')} 节点已死")
        if s.get("transitioning"):
            self._trans_since = self._trans_since or now
            if now - self._trans_since > 30:
                self.note("stuck_transition", f"过场卡了 {int(now - self._trans_since)}s")
                self._trans_since = now  # 去重：再过 30s 才再报
        else:
            self._trans_since = None
        if s.get("fsm_state") == "THINKING":
            self._think_since = self._think_since or now
            if now - self._think_since > 60:
                self.note("stuck_thinking", f"THINKING 卡了 {int(now - self._think_since)}s")
                self._think_since = now
        else:
            self._think_since = None

    def do(self, name, fn, expect_err=()):
        """执行一步动作并核对回包；预期内错误（如 gate_closed）不算异常。"""
        self.bump(name)
        self.log(f"[{self.steps}] {name}")
        try:
            r = fn()
        except HarnessError as e:
            self.note("reply_error", f"{name}: {e}")
            return {}
        if isinstance(r, dict) and r.get("ok") is False:
            err = str(r.get("error", ""))
            if not any(x in err for x in expect_err):
                self.note("reply_error", f"{name}: {err}")
        return r or {}

    # ── 各态策略 ──
    def step(self):
        s = self.h._state_soft()
        if not s:
            raise HarnessError("state 读不到（连接/进程问题）")
        self.watch(s)

        # menu：只有全屏进入钮 → 点进世界
        if not s.get("scene_id") and not s.get("vc_open"):
            ui = self.do("ui", lambda: self.h.ui())
            btns = [e for e in ui.get("elements", []) if e.get("kind") == "button"]
            if btns:
                self.do("click_enter", lambda: self.h.click_ui(path=btns[0]["path"]))
                time.sleep(3)
            return

        # 起名子模式：给个名字收尾
        if s.get("naming_item"):
            self._ensure_inject()
            self.do("say_name", lambda: self.h.say(self.rng.choice(NAME_POOL)))
            time.sleep(2)
            if self.h._state_soft().get("vc_confirming"):
                self.do("accept", self.h.accept)
            return

        # 造物引导中：有卡点卡，无卡肯定应答
        if s.get("in_creation"):
            q = s.get("creation_question", "")
            opts = s.get("creation_options") or []
            if opts:
                oid = opts[0]["id"]
                for o in opts:
                    if o.get("id") == "self":
                        oid = "self"
                        break
                self.do("pick", lambda: self.h.pick(oid))
            elif q and q not in TRANSIENT_Q:
                self._ensure_inject()
                self.do("say_yes", lambda: self.h.say("对呀就是这样"), expect_err=("gate",))
            time.sleep(2)
            return

        # 对话中：说一句或走开
        if s.get("selected"):
            if self.rng.random() < 0.5 and s.get("mic_open"):
                self._ensure_inject()
                line = self.rng.choice(
                    CHAT_LINES + (CREATE_INTENTS if self.allow_create else []))
                self.do("say", lambda: self.h.say(line))
                time.sleep(4)
            else:
                self.do("walk_away", lambda: self.h.tap(240, 900))
                time.sleep(2)
            return

        # 探索态：加权抽一个
        moves = [
            ("tap_ground", lambda: self.h.tap(self.rng.uniform(200, 900),
                                              self.rng.uniform(400, 900)), 4),
            ("talk_fairy", self.h.talk_fairy, 2),
            ("talk_npc", self.h.talk_npc, 2),
            ("phone_tour", self._phone_tour, 2),
            ("long_press", lambda: self.h.long_press(self.rng.uniform(300, 800),
                                                     self.rng.uniform(400, 800), ms=800), 1),
            ("pinch", lambda: self.h.pinch(540, 500, scale=self.rng.choice([0.6, 1.5]),
                                           ms=300), 1),
            ("scene_hop", lambda: self.h.scene(self.rng.choice(SCENES)), 1),
            ("teleport_near", lambda: self.h.teleport(near=True), 1),
        ]
        names = [m[0] for m in moves]
        weights = [m[2] for m in moves]
        pick = self.rng.choices(range(len(moves)), weights=weights)[0]
        self.do(names[pick], moves[pick][1], expect_err=("已在", "被拒"))
        time.sleep(2)

    def _ensure_inject(self):
        if not self._injected:
            r = self.do("inject", self.h.inject)
            self._injected = bool(r.get("injected"))
            self.do("reset_budget", self.h.reset_budget)

    def _phone_tour(self):
        r = self.h.phone("open")
        time.sleep(1)
        app = self.rng.choice(["items", "stickers", "flowers"])
        self.h.phone("app", app)
        time.sleep(1)
        st = self.h._state_soft()
        if not st.get("phone_open"):
            self.note("state_mismatch", "phone open 后 phone_open 仍为 false")
        self.h.phone("close")
        return r


def write_report(path, patrol, minutes, started):
    lines = [
        "# QA 巡检报告",
        "",
        f"- 时间：{time.strftime('%Y-%m-%d %H:%M', time.localtime(started))} 起，计划 {minutes} 分钟",
        f"- 步数：{patrol.steps}",
        f"- 异常：{len(patrol.anomalies)} 条",
        "",
        "## 动作分布",
        "",
    ]
    for k, v in sorted(patrol.actions.items(), key=lambda x: -x[1]):
        lines.append(f"- {k}: {v}")
    lines += ["", "## 异常明细", ""]
    if not patrol.anomalies:
        lines.append("（无）")
    for a in patrol.anomalies:
        ts = time.strftime("%H:%M:%S", time.localtime(a["t"]))
        lines.append(f"- `{ts}` **{a['kind']}** — {a['detail']}")
    lines += ["", "轨迹与截图见同目录 trace.jsonl / shot_*.jpg。", ""]
    Path(path).write_text("\n".join(lines), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description="QA 自主巡检")
    ap.add_argument("--minutes", type=float, default=3.0)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8578)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--allow-create", action="store_true",
                    help="允许主动发起造物意图（会往连接的服务端世界里造东西）")
    ap.add_argument("--trace", default="", help="轨迹/报告目录（缺省 /tmp/qa_patrol_<ts>）")
    ap.add_argument("--shots", action="store_true", help="每 30s 截一张（带窗实例才有图）")
    args = ap.parse_args()

    tdir = args.trace or f"/tmp/qa_patrol_{int(time.time())}"
    rng = random.Random(args.seed)
    h = Harness(args.host, args.port)
    h.connect(retries=5, delay=1.0)
    h.start_trace(tdir)
    log = print

    patrol = Patrol(h, rng, args.allow_create, log)
    started = time.time()
    deadline = started + args.minutes * 60
    last_shot = 0.0
    fatal = False
    try:
        while time.time() < deadline:
            if args.shots and time.time() - last_shot > 30:
                try:
                    h.screenshot(max_dim=640)
                except HarnessError:
                    pass
                last_shot = time.time()
            patrol.step()
    except HarnessError as e:
        patrol.note("conn_lost", f"巡检中断：{e}")
        fatal = True
    finally:
        h.close()
        report = str(Path(tdir) / "report.md")
        write_report(report, patrol, args.minutes, started)
        log(f"\n报告: {report}  （步数={patrol.steps} 异常={len(patrol.anomalies)}）")
    return 100 if fatal else len(patrol.anomalies)


if __name__ == "__main__":
    sys.exit(main())
