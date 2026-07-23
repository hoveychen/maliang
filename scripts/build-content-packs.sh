#!/usr/bin/env bash
# 内容包分发 P5：构建全部可分发 .pck（主题模型 + 语音 + bgm）到 build/packs/。
# 预设由 scripts/gen-content-pack-presets.py 从 pack.json 生成（单一真相来源）。
#
# 用法：scripts/build-content-packs.sh
#   先重跑生成器（保证 cfg/registry 与 pack.json 同步），再逐包 --export-pack。
#   ⚠️ 内容包不含 ASR，故 worktree 里也能安全构建（不像 APK）。校验走 tools/verify_pack.gd。
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || { echo "Godot 不在 $GODOT（用 GODOT=... 覆盖）"; exit 1; }

echo "== 重新生成预设 =="
python3 scripts/gen-content-pack-presets.py

mkdir -p build/packs
names=$(python3 -c "import json;print(' '.join(sorted(json.load(open('build/packs/registry.json')))))")
echo "== 构建 $(echo $names | wc -w | tr -d ' ') 个内容包 =="
for p in $names; do
  out="build/packs/$p.pck"
  # ASR dlopen warning 在 worktree 属预期（gitignored），非致命；只看导出是否落盘。
  "$GODOT" --headless --path "$PWD" --export-pack "$p" "$PWD/$out" >/dev/null 2>&1 || true
  if [ -s "$out" ]; then
    printf "  %-24s %8s\n" "$p" "$(du -h "$out" | cut -f1)"
  else
    echo "  FAIL: $p 未产出 $out"; exit 1
  fi
done

echo "== 校验包内容 =="
"$GODOT" --headless --path "$PWD" --script tools/verify_pack.gd 2>&1 | grep -iE 'ok |FAIL|MISS|verify_pack' || true
echo "== 完成：build/packs/ =="
ls -1 build/packs/*.pck | wc -l | xargs echo "共 .pck 数："