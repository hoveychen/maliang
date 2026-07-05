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

echo "== import（刷新类缓存）=="
"$GODOT" --headless --import --path "$ROOT" >/dev/null 2>&1

# 名字 | 额外参数（--script 之前）
UNIT_TESTS=(
  test_sdf_math
  test_sdf_prop
  test_sdf_animator
  test_world_grid
  test_terrain_map
  test_terrain_atlas
  test_autotile
  test_occupancy_map
  test_pathfinder
  test_mover
  test_behavior_executor
  test_fairy_voice
  test_voice_vad
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

for t in "${UNIT_TESTS[@]}"; do
  run_test "$t"
done

run_test test_visual_fairy         --fixed-fps 10 --quit-after 100
run_test test_visual_click_move    --fixed-fps 10 --quit-after 130
run_test test_visual_fairy_poi     --fixed-fps 10 --quit-after 130
run_test test_visual_camera_height --fixed-fps 10 --quit-after 80
run_test test_visual_sky           --fixed-fps 10 --quit-after 40
run_test test_visual_paper         --fixed-fps 10 --quit-after 110
run_test test_visual_hold_move     --fixed-fps 10 --quit-after 90

echo
if [ "$fails" -eq 0 ]; then
  echo "全部通过 ✔"
else
  echo "$fails 个测试失败 ✘"
  exit 1
fi
