#!/usr/bin/env python3
"""benchmark 噪声探针：抓一次「首启定档」的 BENCH logcat → 解析 trial 增益/采纳档/达标 → 两次对比。

背景：benchmark-unify 真机验收发现同一台华为跑两次 benchmark、采纳档不一样、trial 噪声高达 ±60ms。
根因（代码坐实）：12 个负载村民是【随机 wander、无 seed】，采样期不冻，全代码零 RNG seed →
每个 trial 窗的负载都不同 → 测量不可复现。为「眼见为实」做了 freeze PoC（world._step_executors 里
`if _bench_freeze: return`，采样期冻住负载）。本探针就是量它：冻结版 trial 噪声塌不塌、两次采纳档一不一致。

用法：
  # 1) 抓一次 benchmark（脚本会 tail logcat 到出现 `BENCH done` 或超时；期间在设备上触发定档）：
  python3 test/e2e/bench_probe.py probe --out run1.json
  #    触发方式：pm clear 冷启走 onboarding→世界（fresh 自动跑），或世界里 设置→画质页底「重新检测画质」。

  # 2) 再抓一次，另存：
  python3 test/e2e/bench_probe.py probe --out run2.json

  # 3) 对比两次（噪声谱 + 采纳档一致性）：
  python3 test/e2e/bench_probe.py compare run1.json run2.json

  # onboarding 名字步注入（app 级 harness 在 onboarding 能不能注入的验证点）：
  python3 test/e2e/bench_probe.py name --name 小明   # 需先 adb forward + App 在 onboarding intro 页

判据：冻结版 trial 增益的绝对值谱应 ≪ 未冻的 ±60ms（残余只剩真实画质旋钮差）；两次采纳 levels 应一致。
若冻后噪声塌 + 两次复现 → 坐实随机 wander 是主因、且可治（最终修法：确定化负载，非冻死）。
"""

import argparse
import json
import re
import subprocess
import sys
import time

ADB = "/Users/hoveychen/Library/Android/sdk/platform-tools/adb"
PORT = 8577

# ── BENCH 日志行解析（对齐 scripts/benchmark.gd 的 print 格式）───────────────────
# BENCH trial actor_shadows   lv2 p95=27.6ms gain=-15.4ms
RE_TRIAL = re.compile(r"BENCH trial (\S+)\s+lv(\d+) p95=([\d.]+)ms gain=([+-][\d.]+)ms")
# BENCH 采纳 actor_shadows → lv2（收益 -15.4ms，p95=27.6ms）
RE_ADOPT = re.compile(r"BENCH 采纳 (\S+) → lv(\d+)（收益 ([+-][\d.]+)ms，p95=([\d.]+)ms）")
# BENCH 本轮最佳收益 -0.3ms ≤ 1.5ms 门槛：瓶颈不在画质旋钮，停手保画质
RE_STOP = re.compile(r"BENCH 本轮最佳收益 ([+-][\d.]+)ms ≤ ([\d.]+)ms 门槛")
# BENCH 测量预算用尽（30 次）：...
RE_BUDGET = re.compile(r"BENCH 测量预算用尽（(\d+) 次）")
# BENCH done p95=27.6ms（基线 120.0ms）达标=true 测量25次 levels={...}
RE_DONE = re.compile(r"BENCH done p95=([\d.]+)ms（基线 ([\d.]+)ms）达标=(\w+) 测量(\d+)次 levels=(.+)")


def adb_run(*args, **kw):
    return subprocess.run([ADB, *args], capture_output=True, text=True, **kw)


def capture_bench(timeout=180.0, settle=3.0):
    """tail `adb logcat -s godot`，收所有含 BENCH 的行，直到见 `BENCH done` 后再多收 settle 秒或超时。

    返回收到的 BENCH 原始行列表（去掉 logcat 前缀，只留 `BENCH ...` 起）。先 logcat -c 清缓冲避免读到旧跑。
    """
    adb_run("logcat", "-c")  # 清缓冲：只看这次跑
    print(f"[probe] 已清 logcat 缓冲，开始 tail（超时 {timeout:.0f}s）。请在设备上触发定档……", file=sys.stderr)
    proc = subprocess.Popen(
        [ADB, "logcat", "-s", "godot"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    lines = []
    done_at = None
    deadline = time.time() + timeout
    try:
        for raw in proc.stdout:
            now = time.time()
            if now > deadline:
                print("[probe] 超时，停止 tail", file=sys.stderr)
                break
            idx = raw.find("BENCH ")
            if idx >= 0:
                bench = raw[idx:].rstrip("\n")
                lines.append(bench)
                print(f"  {bench}", file=sys.stderr)
                if "BENCH done" in bench:
                    done_at = now
            # done 后多收 settle 秒（防最后一行还在管道里），随后收尾
            if done_at is not None and now - done_at > settle:
                break
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
    return lines


def parse_bench(lines):
    """把 BENCH 原始行解析成结构化结果。纯函数（供无设备单测）。"""
    trials = []      # [{key, lv, p95, gain}]
    adopts = []      # [{key, lv, gain, p95}]
    stop = None      # {best_gain, threshold} 或 None
    budget = None    # 测量预算上限触发的次数 或 None
    done = None      # {p95, baseline, passed, measures, levels}
    for ln in lines:
        m = RE_TRIAL.search(ln)
        if m:
            trials.append({"key": m.group(1), "lv": int(m.group(2)),
                           "p95": float(m.group(3)), "gain": float(m.group(4))})
            continue
        m = RE_ADOPT.search(ln)
        if m:
            adopts.append({"key": m.group(1), "lv": int(m.group(2)),
                           "gain": float(m.group(3)), "p95": float(m.group(4))})
            continue
        m = RE_STOP.search(ln)
        if m:
            stop = {"best_gain": float(m.group(1)), "threshold": float(m.group(2))}
            continue
        m = RE_BUDGET.search(ln)
        if m:
            budget = int(m.group(1))
            continue
        m = RE_DONE.search(ln)
        if m:
            done = {"p95": float(m.group(1)), "baseline": float(m.group(2)),
                    "passed": m.group(3) == "true", "measures": int(m.group(4)),
                    "levels": m.group(5).strip()}
    return {"trials": trials, "adopts": adopts, "stop": stop, "budget": budget, "done": done}


def summarize(parsed):
    """从解析结果算噪声谱：trial 增益的绝对值 max / 分布，采纳档，是否达标。"""
    gains = [t["gain"] for t in parsed["trials"]]
    abs_gains = [abs(g) for g in gains]
    s = {
        "n_trials": len(gains),
        "gain_abs_max": max(abs_gains) if abs_gains else None,
        "gain_min": min(gains) if gains else None,
        "gain_max": max(gains) if gains else None,
        "gain_spread": (max(gains) - min(gains)) if gains else None,  # 峰峰值 = 噪声宽度
        "n_adopts": len(parsed["adopts"]),
        "budget_exhausted": parsed["budget"],
        "done": parsed["done"],
    }
    return s


def fmt_summary(tag, s):
    d = s["done"] or {}
    out = [f"== {tag} =="]
    out.append(f"  trial 数: {s['n_trials']}  采纳档变更: {s['n_adopts']} 次")
    if s["gain_abs_max"] is not None:
        out.append(f"  trial 增益: min={s['gain_min']:+.1f}ms  max={s['gain_max']:+.1f}ms  "
                    f"峰峰={s['gain_spread']:.1f}ms  |增益|max={s['gain_abs_max']:.1f}ms")
    if s["budget_exhausted"]:
        out.append(f"  ⚠ 测量预算用尽（{s['budget_exhausted']} 次）——未干净收敛")
    if d:
        out.append(f"  done: p95={d['p95']:.1f}ms 基线={d['baseline']:.1f}ms "
                   f"达标={d['passed']} 测量{d['measures']}次")
        out.append(f"  采纳 levels: {d['levels']}")
    return "\n".join(out)


def cmd_probe(args):
    lines = capture_bench(timeout=args.timeout)
    parsed = parse_bench(lines)
    s = summarize(parsed)
    print(fmt_summary(args.out or "run", s))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"lines": lines, "parsed": parsed, "summary": s}, f, ensure_ascii=False, indent=2)
        print(f"[probe] 已存 {args.out}")
    if parsed["done"] is None:
        print("[probe] ✗ 没抓到 BENCH done（定档没跑完或没触发）", file=sys.stderr)
        return 1
    return 0


def cmd_compare(args):
    def load(p):
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    a, b = load(args.run1), load(args.run2)
    sa, sb = a["summary"], b["summary"]
    print(fmt_summary(args.run1, sa))
    print(fmt_summary(args.run2, sb))
    print("\n== 对比结论 ==")
    la = (sa["done"] or {}).get("levels")
    lb = (sb["done"] or {}).get("levels")
    same_levels = (la is not None and la == lb)
    print(f"  两次采纳档一致: {'✓ 是' if same_levels else '✗ 否'}")
    if not same_levels:
        print(f"    run1 levels: {la}")
        print(f"    run2 levels: {lb}")
    if sa["gain_abs_max"] is not None and sb["gain_abs_max"] is not None:
        print(f"  |增益|max: run1={sa['gain_abs_max']:.1f}ms  run2={sb['gain_abs_max']:.1f}ms")
        print(f"  峰峰噪声: run1={sa['gain_spread']:.1f}ms  run2={sb['gain_spread']:.1f}ms")
        worst = max(sa["gain_abs_max"], sb["gain_abs_max"])
        if worst < 5.0 and same_levels:
            print("  → 噪声已塌到 <5ms 且两次复现：坐实随机 wander 是主因、且冻结可治 ✓")
        elif worst >= 30.0:
            print("  → 噪声仍 ≥30ms：冻结没治住，另有噪声源（热漂移/GC?），需再查")
        else:
            print("  → 噪声居中：部分收敛，结合采纳档一致性判断")
    return 0


def cmd_name(args):
    """onboarding 名字步注入：验证 app 级 harness 在 onboarding 能否注入 + 起名。

    复用 naming_e2e 的 Harness。前置：adb forward tcp:8577 + App 停在 onboarding intro 页（自我介绍）。
    流程：inject（换 ScriptedAsr）→ 轮询 vc_open（旁白播完自动开麦）→ say(名字)→ gate_closed 则等旁白再试。
    """
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from naming_e2e import Harness, HarnessError, setup_forward

    if args.device:
        setup_forward()
    h = Harness(args.host, args.port)
    h.connect()
    print(f"[已连] {args.host}:{args.port}")
    try:
        r = h.inject()
        if not (r.get("ok") and r.get("injected")):
            print(f"  ✗ inject 未成功（onboarding 的 VoiceCapture.current 没就位？）: {r}")
            return 1
        print(f"  ✓ inject 成功 ready={r.get('ready')}")

        # 轮询 vc_open：intro 页旁白播完自动开麦（onboarding-vad）。
        print("  · 等麦克风开（旁白播完自动开）……")
        opened = False
        for _ in range(60):  # 最多 ~30s
            st = h.state()
            if st.get("vc_open"):
                opened = True
                break
            time.sleep(0.5)
        if not opened:
            print("  ✗ 30s 内麦克风没开——是不是没到 intro 页 / 旁白没播完 / 端侧未就绪")
            return 1
        print("  ✓ 麦克风已开")

        # say 名字，处理 gate_closed（旁白又插播时）重试
        for attempt in range(4):
            r = h.say(args.name)
            if r.get("fed"):
                print(f"  ✓ 名字「{args.name}」已喂进（第 {attempt + 1} 次）")
                break
            print(f"  · 门禁关（{r.get('reason')}），等 1.5s 重试")
            time.sleep(1.5)
        else:
            print("  ✗ 名字始终喂不进（门禁一直关）")
            return 1

        print("  · 说完等识别→服务端确认「你叫XX对不对」。这层确认要点 ✓（盲坐标，本命令不代点）。")
        print("    看状态：", h.state())
        return 0
    finally:
        h.close()


def main():
    ap = argparse.ArgumentParser(description="benchmark 噪声探针 + onboarding 名字注入")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="抓一次 benchmark 定档的 BENCH logcat 并解析")
    p.add_argument("--out", help="结果存 JSON（供 compare）")
    p.add_argument("--timeout", type=float, default=180.0, help="tail 最长秒数")
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("compare", help="对比两次 probe 结果")
    p.add_argument("run1")
    p.add_argument("run2")
    p.set_defaults(func=cmd_compare)

    p = sub.add_parser("name", help="onboarding 名字步注入验证")
    p.add_argument("--name", default="小明")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=PORT)
    p.add_argument("--device", action="store_true", help="先 adb forward")
    p.set_defaults(func=cmd_name)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
