#!/usr/bin/env python3
"""menu 相册拍摄（menu-dynamic P1）：桌面高分辨率跑游戏连 PROD，逐场景拍干净截图。

用 debug 命令口（scripts/debug_cmd_server.gd）驱动：photo 命令关 HUD/设摄影机位，
scene 命令走正常过场切场景，screencap 落盘后拷出。产出一批候选图，人工挑 6~8 张
精修进 assets/menu_album/。

前置：
  - 本机 /Applications/Godot.app 为 4.6.3（编辑器构建即 debug feature，命令口会开）。
  - 首次跑会向 user://profile.json 写一份「摄影师」档案（跳过 onboarding/benchmark intro）；
    --keep-profile 保留已有档案不动。
  - 连 PROD（api.gd 缺省），拍摄玩家会在 PROD 留一条 player 记录，拍完可 prune。

用法：
  python3 test/e2e/menu_photo_shoot.py [--out /tmp/menu_shoot] [--keep-profile]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from naming_e2e import Harness, HarnessError  # noqa: E402

GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
ROOT = Path(__file__).resolve().parents[2]
# user:// 按项目名解析（project.godot 的 application/config/name=马良小世界），不是仓库名。
USERDATA = Path.home() / "Library/Application Support/Godot/app_userdata/马良小世界"
PROFILE = USERDATA / "profile.json"

# 摄影师档案：真实存在的 PROD 立绘资产（拍摄期临时玩家；正式照片里的形象验收时老板可换）。
SPRITE_ASSET = "bcbf6f596062638c"
PHOTOGRAPHER_NAME = "小马"
# 画质全开（M 系桌面随便跑）：graphics 落档 + intro_seen 跳过建造小世界 intro/benchmark。
GRAPHICS_MAX = {
    "actor_shadows": 2, "ground_shadows": 2, "hi_res": 3, "fog": 2, "outline": 2,
    "prop_anim": 2, "prop_detail": 2, "terrain_detail": 2, "xray": 2, "papercraft": 2,
}

# 镜头表：(名字, 场景, teleport 参数 dict 或 None, cam 参数 dict 或 None=跟随相机, 拍前动作)
# teleport: {"near": True}=传到第一个村民旁（相机聚焦玩家，不进村民堆拍不到村子）；
#           {"tileX","tileY"}=指定格（主题场景 POI 都撒在网格中部）。
# yaw 弧度：0=正南机位（默认朝向），±0.5≈±29°侧机位。
NEAR = dict(near=True)
MID = dict(tileX=37, tileY=37)
SHOTS = [
    # —— 村庄：主打（村民 8 人 + 点点）——
    ("village_wide",      "village", NEAR, dict(pitch=34, dist=24, yaw=0.0), None),
    ("village_side",      "village", NEAR, dict(pitch=26, dist=16, yaw=0.55), None),
    ("village_low",       "village", NEAR, dict(pitch=18, dist=12, yaw=-0.45), None),
    # —— 主题场景巡游 ——
    ("forest_wide",       "forest",  MID, dict(pitch=30, dist=24, yaw=0.35), None),
    ("forest_low",        "forest",  MID, dict(pitch=20, dist=13, yaw=-0.5), None),
    ("icesnow_wide",      "icesnow", MID, dict(pitch=32, dist=24, yaw=0.3), None),
    ("seafloor_wide",     "seafloor", MID, dict(pitch=28, dist=22, yaw=-0.3), None),
    ("ancient_china_wide", "ancient_china", MID, dict(pitch=30, dist=24, yaw=0.4), None),
    ("medieval_wide",     "medieval", MID, dict(pitch=30, dist=24, yaw=-0.35), None),
    ("jurassic_wide",     "jurassic", MID, dict(pitch=28, dist=24, yaw=0.3), None),
    ("toy_room_wide",     "toy_room", MID, dict(pitch=32, dist=22, yaw=-0.3), None),
    # —— 回村拍互动（对话构图相机自己找机位，cam=None）——
    ("village_talk_npc",  "village", NEAR, None, "talk_npc"),
    ("village_talk_npc2", "village", None, None, "wait6"),  # 同一对话隔几秒再拍（表情/说话帧）
    ("village_talk_fairy", "village", None, None, "talk_fairy"),
]

SCENE_SETTLE_SEC = 8.0   # 落地后等区块/贴图铺完
SHOT_SETTLE_SEC = 1.2    # 设机位后等一拍（黑幕淡出/HUD 隐藏都在帧内，稳一点）


def write_profile():
    USERDATA.mkdir(parents=True, exist_ok=True)
    prof = {
        "player_id": uuid.uuid4().hex,
        "device_id": uuid.uuid4().hex,
        "name": PHOTOGRAPHER_NAME,
        "sprite_asset": SPRITE_ASSET,
        "intro_seen": True,
        "graphics": {"levels": GRAPHICS_MAX, "source": "user"},
    }
    PROFILE.write_text(json.dumps(prof, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[shoot] 写摄影师档案 {PROFILE}（player_id={prof['player_id'][:8]}…）")


def wait_world(h, timeout=90.0):
    """轮询 state 直到进世界（scene_id 非空 + ws 在线 + 不在过场）。
    切场景重帧时命令口偶发掉线（实测 menu→loading 会断一次），掉了就重连接着轮。"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            st = h.send({"op": "state"})
        except (HarnessError, OSError):
            h.close()
            h.connect(retries=10, delay=0.5)
            continue
        if st.get("scene_id") and st.get("ws_open") and not st.get("transitioning"):
            return st
        time.sleep(1.0)
    raise HarnessError("等进世界超时")


def goto_scene(h, sid, timeout=60.0):
    st = h.send({"op": "state"})
    if st.get("scene_id") == sid:
        return
    r = h.send({"op": "scene", "id": sid})
    if not r.get("ok"):
        raise HarnessError(f"scene {sid} 被拒: {r}")
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            st = h.send({"op": "state"})
        except (HarnessError, OSError):
            h.close()
            h.connect(retries=10, delay=0.5)
            continue
        if st.get("scene_id") == sid and not st.get("transitioning"):
            time.sleep(SCENE_SETTLE_SEC)
            return
        time.sleep(0.5)
    raise HarnessError(f"等落地 {sid} 超时")


def snap(h, out_dir, name):
    r = h.send({"op": "screencap"})
    if not r.get("ok"):
        raise HarnessError(f"screencap 失败: {r}")
    src = Path(r["path"])
    dst = out_dir / f"{name}.png"
    shutil.copyfile(src, dst)
    print(f"[shoot] ✓ {dst.name}  ({dst.stat().st_size // 1024} KB)")


def run_shots(h, out_dir):
    h.send({"op": "photo", "hud": False})
    for name, sid, tp, cam, action in SHOTS:
        try:
            goto_scene(h, sid)
            if tp is not None:
                h.send({"op": "teleport", **tp})
                time.sleep(4.0)          # 跨图搬家后等区块重铺
            if action == "talk_npc":
                h.send({"op": "photo", "clear_cam": True})
                h.send({"op": "talk_npc"})
                time.sleep(5.0)          # 走过去 + 对话构图 + 招呼开講
            elif action == "talk_fairy":
                h.send({"op": "photo", "clear_cam": True})
                h.send({"op": "talk_fairy"})
                time.sleep(5.0)
            elif action == "wait6":
                time.sleep(6.0)
            if cam is not None:
                h.send({"op": "photo", **cam})
            time.sleep(SHOT_SETTLE_SEC)
            snap(h, out_dir, name)
        except (HarnessError, OSError) as e:
            print(f"[shoot] ✗ {name}: {e}", file=sys.stderr)
    h.send({"op": "photo", "hud": True, "clear_cam": True})
    print(f"[shoot] 完成 → {out_dir}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/menu_shoot")
    ap.add_argument("--keep-profile", action="store_true")
    ap.add_argument("--resolution", default="2560x1440")
    ap.add_argument("--attach", action="store_true",
                    help="不起进程不写档案，直接驱已经跑着的实例（假定已在世界里）")
    args = ap.parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not args.keep_profile and not args.attach:
        write_profile()

    proc = None
    if not args.attach:
        proc = subprocess.Popen(
            [GODOT, "--path", str(ROOT), "--resolution", args.resolution],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    h = Harness()
    try:
        h.connect(retries=40, delay=0.5)
        if args.attach:
            st = wait_world(h, timeout=15.0)
            print(f"[shoot] attach 到已跑实例 scene={st.get('scene_id')}")
            return run_shots(h, out_dir)
        time.sleep(2.0)                     # menu 落稳
        # 任点即进：menu 是全屏按钮，用小坐标——请求的窗口尺寸可能被屏幕钳制，
        # 按分辨率算中心可能落在窗外（踩过：2560x1440 请求实际窗口 2532x1424 逻辑点更小）。
        # tap 触发 change_scene 的那一帧命令口会掉线一次（回包可能丢），input 已注入即可，
        # 掉线交给 wait_world 里的重连兜底。
        try:
            h.send({"op": "tap", "x": 240, "y": 240})
        except (HarnessError, OSError):
            h.close()
            h.connect(retries=10, delay=0.5)
        st = wait_world(h, timeout=150.0)
        print(f"[shoot] 进世界 scene={st.get('scene_id')}")
        run_shots(h, out_dir)
    finally:
        h.close()
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    main()
