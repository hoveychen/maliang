#!/usr/bin/env bash
# 导出 Android APK，并在产物上把「端侧 ASR 是否真打进去了」验一遍。
#
# 为什么要这个脚本：端侧 ASR 依赖的东西【全是 gitignored 的产物】——
#   - android/                     (.gitignore:3，Godot Android 构建模板 + 插件)
#   - asr_plugin/src/main/assets/  (.gitignore:22，AAR 里内嵌的 sherpa 模型)
# 干净 checkout / git worktree 里这些统统不存在。而 Godot 导出时缺了它们【不报错】，
# 只吐一条 warning，exit code 照样是 0。
#
# 运行期还有 AsrGuard 兜底（缺 ASR 会全屏阻断拒进游戏），所以坏包不会流到小朋友手里；
# 但那是装到真机、启动、撞红字之后才知道。这里在【导出当场】就用产物里的 ASR 资产把它拦下。
#
# 注意：不拿包体当判据。debug 模板比 release 大 20MB+，体积会随构建类型漂移；
# 直接数 onnx / tokens.txt / sherpa 库才是「ASR 在不在」的硬证据。
#
# 用法：scripts/export-apk.sh [输出路径=build/maliang.apk] [--release]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-build/maliang.apk}"
[[ "$OUT" == --* ]] && OUT="build/maliang.apk"
MODE="--export-debug"
for a in "$@"; do [ "$a" = "--release" ] && MODE="--export-release"; done

# Godot 版本必须与 Android 构建模板一致。PATH 里的 godot 可能是别的版本（本机是 4.6.1-mono），
# 版本对不上导出直接失败——所以优先用 /Applications/Godot.app。
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$(command -v godot || true)"
[ -n "$GODOT" ] || { echo "找不到 Godot，可用 GODOT=/path/to/Godot 指定"; exit 1; }
echo "== Godot: $("$GODOT" --version | head -1)"

# 导出前先拦一道：源头缺了就别浪费十分钟导一个坏包
[ -d "$ROOT/android" ] || { echo "✘ android/ 不存在——这是 gitignored 的构建模板，worktree 里没有。请在主 checkout 导出。"; exit 1; }

# 导出前拦一道并发：同一项目上并发的 Godot 会互相干扰导出的文件系统扫描，导致
# "Project export ... failed / _fs_changed" 反复失败。实测真凶是另一个会话在同一 checkout 跑
# scripts/test-headless.sh（每条测试都起一个 headless Godot），不是本脚本的 bug——导出得独占项目。
# 检测到就直接拦下、让你先停掉那个会话或等它跑完，别浪费十分钟导一个被打断的包。
others="$(pgrep -f "Godot.*--headless.*--path" 2>/dev/null | grep -vx "$$" || true)"
if [ -n "$others" ]; then
  echo "✘ 检测到同一机器上还有别的 headless Godot 在跑（PID: $(echo "$others" | tr '\n' ' ')）。"
  echo "  多半是另一个会话在跑 test-headless.sh；并发会让导出反复 _fs_changed 失败。"
  echo "  导出需独占项目——请先停掉它（或等它跑完）再导。"
  exit 1
fi

echo "== 导出 $MODE → $OUT"
"$GODOT" --headless --path "$ROOT" "$MODE" "Android" "$ROOT/$OUT" 2>&1 | grep -viE "^Godot Engine|^$" | tail -5

[ -f "$ROOT/$OUT" ] || { echo "✘ 导出没产出文件"; exit 1; }

# ── 产物体检：坏包的唯一可靠信号是「ASR 资产在不在包里」，不是 exit code ──
echo "== 体检 $OUT"
fails=0
check() { # 名字 实得 期望
  if [ "$2" = "$3" ]; then echo "  ✔ $1: $2"; else echo "  ✘ $1: 实得 $2，应为 $3"; fails=$((fails+1)); fi
}
listing="$(unzip -l "$ROOT/$OUT" 2>/dev/null)"
check "onnx 模型数"        "$(echo "$listing" | grep -c '\.onnx')"                 3
check "tokens.txt"         "$(echo "$listing" | grep -c 'asr-models/.*tokens\.txt')" 1
check "sherpa arm64 库"    "$(echo "$listing" | grep -c 'lib/arm64-v8a/libsherpa')"  3

size=$(stat -f%z "$ROOT/$OUT" 2>/dev/null || stat -c%s "$ROOT/$OUT")
# 包体只报不判：debug 模板比 release 大 20MB+，拿它当闸会误伤 release 包。
echo "  ℹ 包体: $((size / 1024 / 1024))MiB（仅供参考，不作判据——debug/release 天然差 20MB+）"

echo
if [ "$fails" -eq 0 ]; then
  echo "APK 完好 ✔  md5=$(md5 -q "$ROOT/$OUT" 2>/dev/null || md5sum "$ROOT/$OUT" | cut -d' ' -f1)"
  echo "装机：adb install -r $OUT   （装完核一下设备端 md5，华为有装回旧包的前科）"
else
  echo "APK 体检不合格 ✘ —— $fails 项不过。别装这个包。"
  echo "多半是在 git worktree 里导的：android/ 和 asr_plugin 的产物都是 gitignored，worktree 里没有。"
  exit 1
fi
