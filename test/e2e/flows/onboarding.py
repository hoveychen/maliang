#!/usr/bin/env python3
"""onboarding —— monkey 跑过首次建角色（Flow Registry P9，kind=setup，provides 世界就绪）。

enter_world 的**替代 setup**：enter_world 假定档案已有角色（走 menu→world）；onboarding 处理**没有角色档**
的首次设备——语音多轮把角色建出来、照镜子改一改、落档进世界。两者都 provides in_world/online/villagers_ready，
按当前状态二选一（onboarding flow 的 requires 为空，因为它自己负责把世界带起来）。

**只用 MonkeyHarness（玩家 SDK）**：do / say / say_when_open / state / actions / wait_*。不碰任何 god op
（teleport/scene/pick/…MonkeyHarness 上根本不存在）。诚实：名字靠真开麦说进去（inject 换 ScriptedAsr 喂
合成 PCM 过真 VAD），确认/选卡/收尾靠真 tap 书页上的按钮（SubViewport gui feed，同手机按钮）。

onboarding 页由 snapshot 的 onboarding_page 暴露（debug_cmd_server._snapshot，P9 同批加）：
  story        绘本旁白页（自动翻页；书页有 ▶ 也可主动翻）——按 ▶ 推进
  intro        说名字页。说名字 → 服务端念「你叫X对不对呀」→ onboarding_intro_confirm 置真、书页显 ✓/✗
               → 按 ✓（书页首个按钮=ic_yes，见 onboarding.gd _build_intro 顺序）。★名字页【不】走 VC 确认
               模式，故 vc_confirming 恒 false，判「待确认」须键 onboarding_intro_confirm。
  avatar_chat  点点引导式形象对话。点点动态提问出图标卡（书页按钮）→ 按首张卡；无卡但开麦则说一句开放答复。
               busy(onboarding_chat_busy) 时等；done 那轮服务端翻页到 generate。
  generate     形象生成 + 照镜子改一改。图亮相(onboarding_refine_ready)后按 ✓（书页唯一按钮）直接「就是我」
               收尾——不说「不用改了」（那会被当成一次 refine 请求再生一轮图）。

终止信号 = world_id 出现（_finish → change_scene main.tscn，带原 player_id/world，不清档）。
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness import HarnessError  # noqa: E402

# 整个 onboarding 涉及多轮 LLM（intro 提名字 / avatar-chat 每轮 / 生图）——给足总预算。
_OVERALL_DEADLINE = 300.0
_CHAT_ROUND = 30.0   # 一轮 avatar-chat（含 LLM + 念题）
_GEN_WAIT = 60.0     # 生图/refine 一轮（图像模型偏慢）


def _in_world(s):
    return bool(s.get("world_id"))


def _find_menu_entry(h, timeout=30.0):
    """轮询 actions 找 menu 全屏进入键（press 且落在 /root/Menu/ 下）。冷启停在 menu 时用它进 onboarding。

    与 enter_world 同一识别法（节点名自动生成 @Button@N，按路径前缀匹配、不写死名字）。菜单按档案分流：
    无角色→onboarding.tscn、有角色→loading→world（menu.gd target_scene）。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            acts = h.actions().get("actions", [])
        except (OSError, HarnessError):
            acts = []
        for a in acts:
            aid = a.get("action_id", "")
            if a.get("kind") == "press" and "/root/Menu/" in aid and a.get("enabled", True):
                return aid
        time.sleep(1.0)
    return None


def _book_buttons(h):
    """当前书页（SubViewport）上可按的按钮 action_id 列表，保持树序。

    书页按钮的 execution=='gui'（SubViewport gui feed），根视口按钮是 'tap'——据此把书页按钮从
    actions() 扁平表里筛出来，不必再读 access() 的 viewport 字段。树序里首个即页面主按钮
    （intro=✓、story=▶、generate=✓、avatar_chat=首张卡）。
    """
    try:
        acts = h.actions().get("actions", [])
    except (OSError, HarnessError):
        return []
    return [a.get("action_id") for a in acts
            if a.get("kind") == "press" and a.get("execution") == "gui" and a.get("enabled", True)]


def _press_first_book_button(h):
    """按书页首个按钮（页面主按钮）。返回是否按到。"""
    btns = _book_buttons(h)
    if not btns:
        return False
    h.do(btns[0])
    return True


def run(h, name="小马", intro=""):
    # 1) 幂等：已在世界（有角色档）→ 复用，不重跑 onboarding。
    s = h.state()
    if _in_world(s):
        h.wait_world(need_vc=False)
        return {"status": "reused", "world_id": s.get("world_id", ""), "scene_id": s.get("scene_id", "")}

    # 2) 冷启停在 menu（还没 onboarding_page）：真 tap 全屏进入键让菜单按档案分流。无角色档 → onboarding.tscn。
    if s.get("onboarding_page") is None:
        entry = _find_menu_entry(h)
        if entry is None:
            raise HarnessError(
                "onboarding: 不在世界、不在 onboarding、也找不到菜单进入键——无从进 onboarding。"
                "确认游戏在 menu（无角色档会由菜单分流进 onboarding）或已在 onboarding。")
        h.do(entry)   # 真 tap → menu.gd _go_to(target_scene) → onboarding.tscn（无角色）或 loading→world（有角色）
        h.wait_until(lambda st: st.get("onboarding_page") is not None or _in_world(st),
                     "菜单分流到 onboarding/world", timeout=30.0)
        s = h.state()
        if _in_world(s):
            # 菜单发现档案里其实已有角色 → 直接进了世界。幂等复用，不建角色。
            h.wait_world(need_vc=False)
            return {"status": "reused", "world_id": s.get("world_id", ""), "scene_id": s.get("scene_id", "")}

    # 3) 换 ScriptedAsr + 等 onboarding 的 VC 就绪，才能用 say 把名字/答复喂进真 VAD。
    h.inject()
    h.wait_until(lambda st: st.get("vc_ready"), "onboarding vc_ready", timeout=45.0)

    intro_line = intro or ("我叫" + name)
    deadline = time.time() + _OVERALL_DEADLINE
    steps = []   # 走过的页/动作留痕，回包里好看清跑了哪几步

    while time.time() < deadline:
        s = h.state()
        if _in_world(s):
            break
        page = str(s.get("onboarding_page", ""))

        if page == "story":
            # 绘本页会自动翻；主动按 ▶ 更快。按不到就等自动翻。
            _press_first_book_button(h)
            h.wait_until(lambda st: str(st.get("onboarding_page", "")) != "story" or _in_world(st),
                         "离开 story 页", timeout=12.0, soft=True)

        elif page == "intro":
            if s.get("onboarding_intro_confirm"):
                # 名字已识别、✓/✗ 行显 → 按 ✓（书页首个按钮=ic_yes）。
                if _press_first_book_button(h):
                    steps.append("intro:confirm")
                h.wait_until(lambda st: str(st.get("onboarding_page", "")) != "intro" or _in_world(st),
                             "离开 intro 页", timeout=15.0, soft=True)
            elif s.get("onboarding_intro_submitting"):
                # 已提交、等服务端提名字：等确认行出现或重问放开。
                h.wait_until(lambda st: st.get("onboarding_intro_confirm")
                             or not st.get("onboarding_intro_submitting") or _in_world(st),
                             "intro 提交落定", timeout=20.0, soft=True)
            else:
                # 开麦窗开着就说名字（say_when_open 会等旁白/门禁）。
                fed = h.say_when_open(intro_line, tries=8)
                steps.append("intro:say(%s,fed=%s)" % (intro_line, fed))
                h.wait_until(lambda st: st.get("onboarding_intro_confirm")
                             or str(st.get("onboarding_page", "")) != "intro" or _in_world(st),
                             "名字提交后落定", timeout=25.0, soft=True)

        elif page == "avatar_chat":
            if s.get("onboarding_chat_busy"):
                h.wait_until(lambda st: not st.get("onboarding_chat_busy")
                             or str(st.get("onboarding_page", "")) != "avatar_chat" or _in_world(st),
                             "avatar-chat 一轮落定", timeout=_CHAT_ROUND, soft=True)
                continue
            btns = _book_buttons(h)
            if btns:
                h.do(btns[0])       # 点首张图标卡（真 tap）
                steps.append("chat:card")
            elif s.get("vc_open"):
                fed = h.say_when_open("我喜欢蓝色", tries=6)   # 无卡的开放语音轮
                steps.append("chat:say(fed=%s)" % fed)
            else:
                time.sleep(1.0)
                continue
            # 等这一轮推进（busy 起或翻页或世界起）。
            h.wait_until(lambda st: st.get("onboarding_chat_busy")
                         or str(st.get("onboarding_page", "")) != "avatar_chat" or _in_world(st),
                         "avatar-chat 提交后推进", timeout=_CHAT_ROUND, soft=True)

        elif page == "generate":
            if s.get("onboarding_refine_ready"):
                # 图亮相 → 按 ✓「就是我」收尾（书页唯一按钮）。不说「不用改了」（会触发再一轮 refine）。
                if _press_first_book_button(h):
                    steps.append("generate:accept")
                h.wait_until(lambda st: str(st.get("onboarding_page", "")) != "generate" or _in_world(st),
                             "generate 收尾→进世界", timeout=_GEN_WAIT, soft=True)
            else:
                # 生图/refine 在途：等图亮相或直接翻页（离线失败会跳过）。
                h.wait_until(lambda st: st.get("onboarding_refine_ready")
                             or str(st.get("onboarding_page", "")) != "generate" or _in_world(st),
                             "等生图亮相", timeout=_GEN_WAIT, soft=True)

        else:
            # 页未知/翻页瞬间：短歇再看。
            time.sleep(1.0)

    # 4) 落定：等世界就绪（穿过 loading 过场）。没进世界=超时失败，诚实抛错。
    st = h.wait_world(need_vc=False, timeout=90.0)
    return {"status": "onboarded", "world_id": st.get("world_id", ""),
            "scene_id": st.get("scene_id", ""), "steps": steps}
