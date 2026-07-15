#!/bin/bash
# P1 取证批量截图：每主题 1-2 机位（室外=mound+水体，室内=中央台+抬高区）。
# 机位参数=修好 look_at 后实测可用的 PITCH=40/DIST=38（室内 42/30 更近看墙内）。
set -u
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
WT=/Users/hoveychen/workspace/maliang/.worktrees/pokopia-themes
OUT=$WT/shots_themes
shoot() { # theme focus pitch dist name
  THEME=$1 FOCUS=$2 PITCH=$3 DIST=$4 SHOT=$OUT/$5.png "$GODOT" --path "$WT" --script res://test/test_visual_theme.gd 2>&1 | grep -E "^截图|注入失败" || echo "FAIL $5"
}
shoot village       45,33 38 42 village
shoot village       37,40 40 38 village_b
shoot forest        37,40 40 38 forest
shoot seafloor      50,28 40 38 seafloor
shoot seafloor      37,40 40 38 seafloor_b
shoot icesnow       28,50 40 38 icesnow
shoot icesnow       14,30 40 38 icesnow_b
shoot jurassic      50,28 40 38 jurassic
shoot jurassic      37,40 40 38 jurassic_b
shoot medieval      50,28 40 38 medieval
shoot medieval      60,28 40 38 medieval_b
shoot roman         50,28 40 38 roman
shoot roman         37,40 40 38 roman_b
shoot ancient_china 50,28 40 38 ancient_china
shoot ancient_china 37,40 40 38 ancient_china_b
shoot modern_city   50,28 40 38 modern_city
shoot modern_city   18,55 40 38 modern_city_b
shoot toy_room      37,37 42 30 toy_room
shoot toy_room      28,46 42 30 toy_room_b
shoot kitchen       37,37 42 30 kitchen
shoot kitchen       28,46 42 30 kitchen_b
shoot hospital      37,37 42 30 hospital
shoot hospital      28,46 42 30 hospital_b
shoot future_robot  37,37 42 30 future_robot
shoot future_robot  28,46 42 30 future_robot_b
echo ALL_DONE
