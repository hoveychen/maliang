#!/usr/bin/env bash
# 导 iOS：Godot 导出 Xcode 工程 → 把 ASR 模型挪进 Resources → 校验 → 交给 Xcode 编真机包。
#
# 为什么要这个脚本而不是直接 `godot --export-debug "iOS"`：
#
# 1. **Godot 版本**：PATH 里的 godot 是 4.6.1-mono，和 4.6.3 的 iOS 导出模板对不上。必须用 /Applications/Godot.app。
#
# 2. **模型会被静默丢掉**。.gdextension 的 [dependencies] 能把 sherpa/onnxruntime 的
#    xcframework 搬进工程并链接，但同一机制搬模型目录时，Godot 把它塞进了 pbxproj 的
#    **Frameworks** build phase——Xcode 对着一个普通目录不报错、不链接、也不打进包。
#    实测：导出 exit 0、xcodebuild BUILD SUCCEEDED、.app 里连 tokens.txt 都没有。
#    所以导出后必须把这个文件引用从 Frameworks 挪到 Resources（见 _patch_pbxproj）。
#
# 3. 端侧 ASR 是**唯一**的识别路径（服务端 ASR 2026-07-13 已退役）。模型丢了就是个哑巴包，
#    而且 iOS 上 AsrGuard 会拦下来硬报错——但那要装到真机、启动、撞红字才知道。
#    本脚本在导出当场数模型/库，缺了就 exit 1。
#
# 用法：scripts/export-ios.sh [debug|release]
#   产出 build/ios/maliang.xcodeproj，然后：
#     open build/ios/maliang.xcodeproj   # Xcode 里选真机 → Run（签名用 team 6HU93XQG5B）
#   或命令行编：
#     xcodebuild -project build/ios/maliang.xcodeproj -scheme maliang -sdk iphoneos build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-debug}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
BIN="$ROOT/addons/maliang_asr_native/bin"
ASR_DIR="sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12"
MODEL_SRC="${MODEL_SRC:-$ROOT/server/models}"
OUT="$ROOT/build/ios/maliang.xcodeproj"

case "$MODE" in
  debug)   TARGET="template_debug"; EXPORT_FLAG="--export-debug" ;;
  release) TARGET="template_release"; EXPORT_FLAG="--export-release" ;;
  *) echo "用法：scripts/export-ios.sh [debug|release]"; exit 1 ;;
esac

[ -x "$GODOT" ] || { echo "找不到 /Applications/Godot.app（GODOT=... 覆盖）"; exit 1; }

# 1. 前置产物：GDExtension 静态库 + sherpa/onnxruntime xcframework
LIB="$BIN/libmaliang_asr.ios.$TARGET.arm64.a"
if [ ! -f "$LIB" ] || [ ! -d "$BIN/sherpa-onnx.xcframework" ]; then
  echo "==> 构建 iOS ASR GDExtension（$TARGET）"
  "$ROOT/scripts/build-asr-gdextension.sh" "$TARGET" arm64 ios
fi

# 2. 模型就位（.gdextension 的 [dependencies] 靠它把目录拷进工程）
MODELS="$BIN/asr-models/$ASR_DIR"
if [ ! -f "$MODELS/tokens.txt" ]; then
  echo "==> 拷入 ASR 模型"
  SRC="$MODEL_SRC/$ASR_DIR"
  [ -f "$SRC/tokens.txt" ] || { echo "缺模型：$SRC（先跑 server/scripts/fetch-voice-models.sh）"; exit 1; }
  mkdir -p "$MODELS"
  for f in encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx \
           decoder-epoch-20-avg-1-chunk-16-left-128.onnx \
           joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx tokens.txt; do
    cp "$MODEL_SRC/$ASR_DIR/$f" "$MODELS/"
  done
fi

# 3. 导出 Xcode 工程
echo "==> Godot 导出（$MODE）"
rm -rf "$ROOT/build/ios"
mkdir -p "$ROOT/build/ios"
"$GODOT" --headless --path "$ROOT" $EXPORT_FLAG "iOS" "$OUT"

# 4. 把模型从 Frameworks phase 挪到 Resources phase（见文件头第 2 条）
echo "==> 修补 pbxproj：模型 → Resources"
python3 - "$OUT/project.pbxproj" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()

m = re.search(r'(\w+) = \{isa = PBXFileReference;[^}]*name = "asr-models";[^}]*\};', s)
if not m:
    sys.exit("pbxproj 里找不到 asr-models 的 PBXFileReference——.gdextension 的 [dependencies] 是不是没带模型？")
file_ref = m.group(1)

# 目录要当文件夹引用拷贝，否则 Xcode 只当不透明文件
s = s.replace(m.group(0), m.group(0).replace("lastKnownFileType = file;", "lastKnownFileType = folder;"))

bm = re.search(r'(\w+) = \{isa = PBXBuildFile; fileRef = %s;[^}]*\};' % file_ref, s)
if not bm:
    sys.exit("找不到引用 asr-models 的 PBXBuildFile")
build_id = bm.group(1)

# 从 Frameworks phase 摘掉
def strip_from(phase, text):
    mm = re.search(r'isa = %s;.*?files = \((.*?)\);' % phase, text, re.S)
    if not mm or build_id not in mm.group(1):
        return text, False
    files = "\n".join(l for l in mm.group(1).split("\n") if build_id not in l)
    return text[:mm.start(1)] + files + text[mm.end(1):], True

s, moved = strip_from("PBXFrameworksBuildPhase", s)
if not moved:
    sys.exit("asr-models 不在 Frameworks phase 里——Godot 的行为变了，重新核对本脚本的假设")

# 挂进 Resources phase
rm = re.search(r'isa = PBXResourcesBuildPhase;.*?files = \(', s, re.S)
if not rm:
    sys.exit("找不到 PBXResourcesBuildPhase")
s = s[:rm.end()] + "\n\t\t\t\t%s /* asr-models in Resources */," % build_id + s[rm.end():]

open(p, "w").write(s)
print("   asr-models: Frameworks → Resources ✓")
PY

# 5. 护栏：数工程里的模型和库，缺了当场 exit 1（别等装到真机撞红字）
echo "==> 校验工程"
PROJ_MODELS="$ROOT/build/ios/maliang/addons/maliang_asr_native/bin/asr-models/$ASR_DIR"
ONNX=$(find "$PROJ_MODELS" -name "*.onnx" 2>/dev/null | wc -l | tr -d ' ')
[ "$ONNX" = "3" ] || { echo "❌ 模型 onnx 数不对：$ONNX（应为 3）"; exit 1; }
[ -f "$PROJ_MODELS/tokens.txt" ] || { echo "❌ 缺 tokens.txt"; exit 1; }
[ -f "$ROOT/build/ios/maliang/addons/maliang_asr_native/bin/libmaliang_asr.ios.$TARGET.arm64.a" ] || \
  { echo "❌ 工程里没有 ASR 静态库"; exit 1; }
grep -q "asr-models in Resources" "$OUT/project.pbxproj" || { echo "❌ pbxproj 修补没生效"; exit 1; }
echo "   onnx×$ONNX + tokens.txt + libmaliang_asr.ios.$TARGET.arm64.a ✓"

# 6. 真正的红绿灯：编一遍（不签名），看 **.app 里** 有没有模型和 ASR 符号。
#    工程里有 ≠ 包里有——上面第 2 条就是栽在这：Xcode 把 Frameworks phase 里的模型目录
#    静默丢了，工程、导出、构建三处全绿，只有 .app 里是空的。SKIP_VERIFY=1 可跳过。
if [ "${SKIP_VERIFY:-0}" != "1" ]; then
  echo "==> 试编真机包并核查 .app（SKIP_VERIFY=1 可跳过）"
  DD="$ROOT/build/ios/.dd"
  xcodebuild -project "$OUT" -scheme maliang -configuration "$([ "$MODE" = release ] && echo Release || echo Debug)" \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build > "$ROOT/build/ios/xcodebuild.log" 2>&1 || {
      echo "❌ xcodebuild 失败，见 build/ios/xcodebuild.log"; tail -5 "$ROOT/build/ios/xcodebuild.log"; exit 1; }
  APP="$(find "$DD/Build/Products" -maxdepth 2 -name "maliang.app" | head -1)"
  [ -n "$APP" ] || { echo "❌ 没找到构建出的 .app"; exit 1; }
  APP_ONNX=$(find "$APP/asr-models" -name "*.onnx" 2>/dev/null | wc -l | tr -d ' ')
  [ "$APP_ONNX" = "3" ] || { echo "❌ .app 里 onnx 数不对：$APP_ONNX（应为 3）——模型被静默丢了"; exit 1; }
  [ -f "$APP/asr-models/$ASR_DIR/tokens.txt" ] || { echo "❌ .app 里缺 tokens.txt"; exit 1; }
  # 用 grep -c 而不是 grep -q：pipefail 下 grep -q 一命中就退出，会给 nm 一个 SIGPIPE，
  # 整条管道被判失败——护栏会对着一个好包狂喊坏包（踩过）。
  ENTRY=$(nm "$APP/maliang" 2>/dev/null | grep -c " _maliang_asr_library_init$" || true)
  [ "$ENTRY" -ge 1 ] || { echo "❌ .app 二进制里没有 ASR 入口符号——GDExtension 没静态链进去"; exit 1; }
  echo "   .app：onnx×$APP_ONNX + tokens.txt + _maliang_asr_library_init ✓（$(du -sh "$APP" | cut -f1)）"
fi

echo
echo "完成：$OUT"
echo "  open $OUT   # Xcode 选真机 → Run（签名 team 6HU93XQG5B）"
