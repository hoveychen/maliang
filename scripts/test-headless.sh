#!/usr/bin/env bash
# maliang headless 回测：单元测试 + 带断言的视觉测试，全程无窗口、无截图。
# 用法：scripts/test-headless.sh
# 说明：
#   - 先跑 --import 重建 .godot 类缓存——headless --script 不刷新全局 class_name，
#     新增脚本类后不 import 会直接解析错误（FairyVoice/PlayerProfile 都踩过）。
#   - 视觉测试里 test_visual_terrain / test_visual_pathfinding 是无断言的纯截图脚本，
#     只服务人眼 QA，不进本回测；要截图请按各文件头部注释带窗跑 --write-movie。
#   - 每个测试 quit(失败数) 作为退出码，任一非零则整体失败。
# 前置：Godot 4.x（默认 /Applications/Godot.app，可用 GODOT 环境变量覆盖）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$(command -v godot || true)"
[ -n "$GODOT" ] || { echo "找不到 Godot，可用 GODOT=/path/to/Godot 指定"; exit 1; }

# 离线模式：指向一个必然连不上的地址，世界走本地占位逻辑，不依赖后端。
export MALIANG_API_BASE="${MALIANG_API_BASE:-http://127.0.0.1:1}"
# 回测离线约定：关掉 edge-tts 真网探活（协议单测/真网冒烟见 test_edge_tts.gd）。
export MALIANG_EDGE_TTS="${MALIANG_EDGE_TTS:-0}"
# harness 命令口走回测专用端口：8577 常被 iproxy/adb forward 转发到真机调试设备占走，
# 会让 test_harness_wire 环境性挂掉（backpack/menu 两条线都撞过）。
export MALIANG_HARNESS_PORT="${MALIANG_HARNESS_PORT:-8579}"
# user:// 沙箱：回测和真游戏共用 user://，多个测试会 clear()/整写 profile.json——开发机档案的
# 角色字段（name/sprite_asset）被抹过两次（游戏被错误分流进 onboarding 才暴露）。macOS/Linux 的
# user:// 都从 $HOME 解析，整套回测换一次性 HOME，测试怎么写档都碰不到真档案。
export HOME="$(mktemp -d "${TMPDIR:-/tmp}/maliang-test-home.XXXXXX")"
export XDG_DATA_HOME="$HOME/.local/share"

echo "== import（刷新类缓存）=="
"$GODOT" --headless --import --path "$ROOT" >/dev/null 2>&1

# 名字 | 额外参数（--script 之前）
UNIT_TESTS=(
  test_char_anim_lod
  test_sdf_math
  test_sdf_prop
  test_placeholder_specs
  test_sdf_animator
  test_world_grid
  test_terrain_map
  test_terrain_atlas
  test_scifi_items
  test_pack_registry
  test_item_thumbnailer
  test_item_3d_viewer
  test_autotile
  test_occupancy_map
  test_pathfinder
  test_mover
  test_ball_body
  test_ball_ownership
  test_ball_replication_buffer
  test_behavior_executor
  test_edge_tts
  test_tts_prebuffer
  test_fairy_voice
  test_npc_wish_voice
  test_npc_greeter
  test_prebaked_voice
  test_onboarding_bgm_mute
  test_onboarding_asr_gate
  test_onboarding_vad
  test_onboarding_avatar_chat
  test_voice_vad
  test_voice_capture
  test_voice_confirm
  test_voice_wave
  test_name_voice
  test_scripted_asr
  test_debug_cmd_server
  test_harness_access
  test_harness_do
  test_confirm_bar
  test_game_audio
  test_sdf_static_baker
  test_sdf_bake_swap
  test_paper_idle
  test_paper_clips
  test_video_lod
  test_task_chip_portrait
  test_anim_clip_pick
  test_atlas_compress
  test_player_profile
  test_my_world_api
  test_bootstrap_world_select
  test_stamp_ceremony
  test_composed_prop
  test_build_parts
  test_menu_gate
  test_menu_album
  test_cjk_font
  test_graphics_settings
  test_papercraft_toggle
  test_frame_sampler
  test_backend_player_id
  test_backend_reconnect
  test_pos_codec
  test_stage_agent
  test_screenplay_replay
  test_remote_actor_buffer
  test_positions_report
  test_presence
  test_player_talk
  test_terrain_export
  test_terrain_village_forest
  test_home_interior
  test_home_interior_portal
  test_room_stage
  test_room_render_branch
  test_spawn_anchor
  test_terrain_load
  test_terrain_v2
  test_terrain_v3_crosscheck
  test_matrix_skin
  test_prop_animation
  test_terrain_patch
  test_terrain_rebuild
  test_grid_presets
  test_terrain_layers
  test_terrain_deco
  test_sticker_edges
  test_sticker_asset_render
  test_character_anchors
  test_self_stickers
  test_fairy_anchors
  test_enter_scene_client
  test_poi_serve
  test_position_restore
  test_webp_load
  test_asset_cache
  test_char_prefetch
  test_loading_progress
  test_dialog_camera
  test_phone_menu
  test_wish_board
  test_story_voice
  test_paper_phone
  test_paper_book
  test_asr_guard
  test_mic_permission
  test_interaction_fsm
  test_paper_xray_gate
  test_scatter_shadows
  test_actor_shadow
)
fails=0

run_test() {
  local name="$1"; shift
  echo "== $name =="
  "$GODOT" --headless --path "$ROOT" "$@" --script "res://test/${name}.gd" 2>&1 \
    | grep -vE "^Godot Engine|ObjectDB instances leaked|resources still in use|^\s+at: (cleanup|clear)" \
    | grep -vE "^\s*$"
  local code=${PIPESTATUS[0]}
  if [ "$code" -ne 0 ]; then
    echo "-- $name FAILED (exit=$code)"
    fails=$((fails + 1))
  fi
}

# 主场景已改 village_forest（s1-hood-activate P2）。少数视觉/地形回测锚定退役 village 的地貌特征
# （8 级演示山 @ (37,6)、池塘 @ chunk(0,0)、风车、village scene_compose 的 7 只 SDF、village stub 村民）——
# 这些验的是渲染/引导管线本身，用 village 当稳定 fixture。经 MALIANG_BOOT_SCENE=village 把它们 pin 回
# village 单独跑；其余测试默认 boot village_forest，天然覆盖「新主场景进得去不崩」。
run_test_village() {
  MALIANG_BOOT_SCENE=village run_test "$@"
}

for t in "${UNIT_TESTS[@]}"; do
  run_test "$t"
done

run_test test_scene_unload         --fixed-fps 10 --quit-after 40
run_test test_boot_scene_filter    --fixed-fps 10 --quit-after 40
run_test test_stage_camera        --fixed-fps 10 --quit-after 110
run_test_village test_stage_staging       --fixed-fps 10 --quit-after 130
run_test test_stage_ball          --fixed-fps 10 --quit-after 90
run_test test_visual_menu          --fixed-fps 10 --quit-after 60
run_test test_visual_loading       --fixed-fps 10 --quit-after 90
run_test test_visual_fairy         --fixed-fps 10 --quit-after 100
run_test test_visual_click_move    --fixed-fps 10 --quit-after 140
run_test test_sfx_mic_guard        --fixed-fps 10 --quit-after 60
run_test test_fairy_guide          --fixed-fps 10 --quit-after 115
run_test test_fairy_guide_hint     --fixed-fps 10 --quit-after 95
run_test test_visual_fairy_poi     --fixed-fps 10 --quit-after 130
run_test test_visual_fairy_poi_hold --fixed-fps 10 --quit-after 90
run_test_village test_visual_camera_height --fixed-fps 10 --quit-after 80
run_test test_visual_sky           --fixed-fps 10 --quit-after 40
run_test test_visual_home_env      --fixed-fps 10 --quit-after 40
run_test test_visual_paper         --fixed-fps 10 --quit-after 110
run_test test_visual_hold_move     --fixed-fps 10 --quit-after 90
run_test_village test_visual_sdf           --fixed-fps 10 --quit-after 140
run_test_village test_visual_water         --fixed-fps 10 --quit-after 60
run_test test_visual_camera_gesture --fixed-fps 10 --quit-after 160
run_test test_visual_dialog_stage  --fixed-fps 10 --quit-after 60
run_test test_visual_dialog_stage_blocked --fixed-fps 10 --quit-after 30
run_test test_visual_dialog_anim   --fixed-fps 10 --quit-after 40
run_test test_npc_idle_anim        --fixed-fps 10 --quit-after 80
run_test test_villager_assets      --fixed-fps 10 --quit-after 40
run_test_village test_bootstrap_split      --fixed-fps 10 --quit-after 60
run_test test_intro_director       --fixed-fps 10 --quit-after 600
run_test test_intro_tutorial       --fixed-fps 10 --quit-after 1200
run_test test_intro_skip           --fixed-fps 10 --quit-after 60
run_test test_intro_benchmark      --fixed-fps 60 --quit-after 3600
run_test test_world_notice         --fixed-fps 10 --quit-after 40
run_test test_player_anchors       --fixed-fps 10 --quit-after 30
run_test test_remote_player_anchors --fixed-fps 10 --quit-after 30
run_test test_visual_greeting      --fixed-fps 10 --quit-after 60
run_test test_visual_interactions  --fixed-fps 10 --quit-after 420
run_test test_paper_actions        --fixed-fps 10 --quit-after 60
run_test test_visual_rewards       --fixed-fps 10 --quit-after 260
run_test test_task_hint_ask        --fixed-fps 10 --quit-after 60
run_test_village test_visual_props         --fixed-fps 10 --quit-after 120
run_test test_placement            --fixed-fps 10 --quit-after 40
run_test test_item_voice           --fixed-fps 10 --quit-after 60
run_test test_casting_placeholder  --fixed-fps 10 --quit-after 120
run_test test_prop_creation_cards  --fixed-fps 10 --quit-after 90
run_test test_build_cards           --fixed-fps 10 --quit-after 90
run_test test_remix                 --fixed-fps 10 --quit-after 90
run_test test_refine                --fixed-fps 10 --quit-after 90
run_test test_creation_stage       --fixed-fps 10 --quit-after 150
run_test test_visual_settings      --fixed-fps 10 --quit-after 80
run_test test_graphics_toggles     --fixed-fps 10 --quit-after 40
run_test test_benchmark_greedy     --fixed-fps 10 --quit-after 60
run_test test_harness_wire         --fixed-fps 30 --quit-after 120
run_test test_device_profile_boot
run_test_village test_visual_landmark_rebuild --fixed-fps 10 --quit-after 60
run_test test_home_portal           --fixed-fps 10 --quit-after 30
run_test test_home_walk             --fixed-fps 10 --quit-after 40
run_test test_home_input_lock       --fixed-fps 10 --quit-after 40
run_test test_home_cross            --fixed-fps 10 --quit-after 90
run_test test_home_soft             --fixed-fps 10 --quit-after 90
run_test test_home_edge             --fixed-fps 10 --quit-after 90

# ── macOS 端侧 ASR 端到端真识别（GDExtension 在 headless 也加载）──────────────
# 喂真中文 wav 给 sherpa 识别器，断言识别文本含「研究」。framework 与模型都是 gitignored，
# 干净 checkout / 非 macOS 没有 → 显式 SKIP（不静默丢、不误报失败）。
run_macos_asr_test() {
  local name="macos_asr_recognize"
  if [ "$(uname)" != "Darwin" ]; then
    echo "== $name SKIP（非 macOS）=="; return
  fi
  local fw="$ROOT/addons/maliang_asr_native/bin/libmaliang_asr.macos.editor.framework"
  if [ ! -d "$fw" ]; then
    echo "== $name SKIP（GDExtension 未构建：$fw 不存在）=="; return
  fi
  # 模型允许外部指路：worktree 里没有 server/models（那是主 checkout 的下载物，
  # 且 .gitignore 的 "server/models/" 带尾斜杠不匹配软链——软链过来会被 git add 吞进仓库）。
  # 在 worktree 跑回测时：MALIANG_ASR_MODEL_DIR=<主 checkout>/server/models/<模型目录> 即可。
  local model_dir="${MALIANG_ASR_MODEL_DIR:-$ROOT/server/models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12}"
  if [ ! -f "$model_dir/tokens.txt" ]; then
    echo "== $name SKIP（缺模型：$model_dir/tokens.txt 不存在）=="; return
  fi
  echo "== $name =="
  local out; out="$(mktemp)"
  MALIANG_ASR_MODEL_DIR="$model_dir" MALIANG_ASR_CHECK_OUT="$out" \
    "$GODOT" --headless --path "$ROOT" --script "res://test/${name}.gd" >/dev/null 2>&1
  local code=$?
  local result; result="$(cat "$out" 2>/dev/null)"; rm -f "$out"
  echo "  $result"
  if [ "$code" -ne 0 ]; then
    echo "-- $name FAILED (exit=$code)"
    fails=$((fails + 1))
  fi
}
run_macos_asr_test

# ── e2e 驱动 SDK 自测（纯 python，假 TCP 服务端回放/纯函数，不起游戏，<1s）─────────
echo "== test_harness_sdk (python) =="
if ! python3 "$ROOT/test/e2e/test_harness_sdk.py" >/dev/null 2>&1; then
  echo "-- test_harness_sdk FAILED"
  fails=$((fails + 1))
fi
echo "== test_harness_delta (python) =="
if ! python3 "$ROOT/test/e2e/test_harness_delta.py" >/dev/null 2>&1; then
  echo "-- test_harness_delta FAILED"
  fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "全部通过 ✔"
else
  echo "$fails 个测试失败 ✘"
  exit 1
fi
