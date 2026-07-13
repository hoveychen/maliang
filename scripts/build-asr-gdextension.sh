#!/usr/bin/env bash
# macOS/iOS 端侧 ASR GDExtension 一键构建。
# 产出 addons/maliang_asr_native/bin/ 下的 .framework（macOS）或 .a（iOS），供 Godot 4.6 加载出
# MaliangAsr 单例——与 Android 的 asr_plugin 同名同接口，客户端零改动（见 docs/macos-asr-feasibility.md）。
#
# macOS 动态链接（framework 里自带 sherpa/onnxruntime dylib）；
# iOS 静态链接（Godot 的 iOS 导出把扩展静态链进 Xcode 工程，见 docs/ios-asr-design.md）。
#
# 依赖：git、python3+scons（pip install scons）、Xcode CLT（clang++）。
# 前置产物均 gitignore、可由本脚本重新生成：
#   - gdextension_asr/godot-cpp/            godot-cpp master（v10，锁 4.6 API）
#   - gdextension_asr/extension_api.json    从本机 Godot 4.6 dump（锁定 ABI）
#   - gdextension_asr/sherpa-onnx/          macOS 库 + c-api 头文件（iOS 也复用这份头文件）
#   - gdextension_asr/sherpa-onnx-ios/      iOS 静态 xcframework（sherpa + onnxruntime）
#   - addons/maliang_asr_native/bin/*
#
# 用法：scripts/build-asr-gdextension.sh [editor|template_debug|template_release] [arm64|x86_64|universal] [macos|ios]
#   默认 editor / arm64 / macos（本机冒烟与 headless 测试用）。
#   打包 .app 用 template_release + universal + macos。
#   导 iOS 用 template_debug|template_release + arm64 + ios。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/gdextension_asr"
TARGET="${1:-editor}"
ARCH="${2:-arm64}"
PLATFORM="${3:-macos}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

case "$PLATFORM" in
  macos|ios) ;;
  *) echo "platform 只能是 macos 或 ios（收到：$PLATFORM）"; exit 1 ;;
esac
if [ "$PLATFORM" = "ios" ]; then
  [ "$TARGET" != "editor" ] || { echo "iOS 没有 editor target，用 template_debug 或 template_release"; exit 1; }
  ARCH="arm64"   # iOS 真机只有 arm64（模拟器路线走不通：官方模板的 simulator 切片链不出 arm64 _main）
fi

[ -x "$GODOT" ] || GODOT="$(command -v godot || true)"
[ -n "$GODOT" ] || { echo "找不到 Godot（GODOT=/path/to/Godot 覆盖）"; exit 1; }
command -v scons >/dev/null || { echo "缺 scons：pip install scons"; exit 1; }

# 1. godot-cpp（master/v10 支持 api_version 独立于引擎，可锁 4.6）
if [ ! -d "$EXT/godot-cpp" ]; then
  echo "clone godot-cpp master ..."
  git clone --depth 1 -b master https://github.com/godotengine/godot-cpp.git "$EXT/godot-cpp"
fi

# 2. 从本机 Godot dump 4.6 的 extension_api.json（master 默认跟 4.7，必须显式锁）
if [ ! -f "$EXT/extension_api.json" ]; then
  echo "dump extension_api.json（$("$GODOT" --version)）..."
  ( cd "$EXT" && "$GODOT" --headless --dump-extension-api --dump-gdextension-interface >/dev/null 2>&1 )
fi

# 2b. sherpa-onnx macOS universal2（shared，含 c-api 头文件 + dylib + onnxruntime）。
#     与 Android AAR、服务端 sherpa-onnx-node 同一版本 v1.13.3。
SHERPA_VER="1.13.3"
ORT_VER="1.26.0"   # sherpa iOS 包内 onnxruntime.xcframework 的版本目录名
SHERPA_PKG="sherpa-onnx-v$SHERPA_VER-osx-universal2-shared-no-tts"
if [ ! -f "$EXT/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h" ]; then
  echo "下载 sherpa-onnx macOS 库 ..."
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/s.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VER/$SHERPA_PKG.tar.bz2"
  tar xjf "$TMP/s.tar.bz2" -C "$TMP"
  mkdir -p "$EXT/sherpa-onnx"
  cp -R "$TMP/$SHERPA_PKG/include" "$EXT/sherpa-onnx/"
  cp -R "$TMP/$SHERPA_PKG/lib" "$EXT/sherpa-onnx/"
  rm -rf "$TMP"
fi

# 2c. sherpa-onnx iOS：官方发布包只有库、没有头文件——头文件复用上面那份 macOS 包（同版本）。
#     包内是 **静态** xcframework：sherpa-onnx.xcframework/ios-arm64/libsherpa-onnx.a + onnxruntime.xcframework。
if [ "$PLATFORM" = "ios" ] && [ ! -d "$EXT/sherpa-onnx-ios/sherpa-onnx.xcframework" ]; then
  echo "下载 sherpa-onnx iOS 静态库 ..."
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/s.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VER/sherpa-onnx-v$SHERPA_VER-ios.tar.bz2"
  tar xjf "$TMP/s.tar.bz2" -C "$TMP"
  mkdir -p "$EXT/sherpa-onnx-ios"
  cp -R "$TMP/build-ios/sherpa-onnx.xcframework" "$EXT/sherpa-onnx-ios/"
  cp -R "$TMP/build-ios/ios-onnxruntime/$ORT_VER/onnxruntime.xcframework" "$EXT/sherpa-onnx-ios/"
  rm -rf "$TMP"
fi

# 3. 构建
echo "scons platform=$PLATFORM target=$TARGET arch=$ARCH ..."
if [ "$PLATFORM" = "ios" ]; then
  ( cd "$EXT" && scons platform=ios target="$TARGET" arch="$ARCH" ios_simulator=no )
else
  ( cd "$EXT" && scons target="$TARGET" arch="$ARCH" )
fi

BIN="$ROOT/addons/maliang_asr_native/bin"

if [ "$PLATFORM" = "ios" ]; then
  # 3a-ios. 合并 godot-cpp 的静态库进来。
  # scons 产出的 .a 只含本扩展的目标文件；Godot 的 iOS 导出只链 .gdextension 里声明的这一个
  # 库，godot-cpp 不会被单独链进去——不合并的话 Xcode 链接期会一片 godot::* 未定义符号。
  STAGED="$EXT/bin_ios/libmaliang_asr.ios.$TARGET.arm64.a"   # scons 产物：只含本扩展
  CPPLIB="$EXT/godot-cpp/bin/libgodot-cpp.ios.$TARGET.arm64.a"
  OURS="$BIN/libmaliang_asr.ios.$TARGET.arm64.a"             # 合并产物：交给 Godot
  [ -f "$STAGED" ] || { echo "scons 没产出 $STAGED"; exit 1; }
  [ -f "$CPPLIB" ] || { echo "找不到 godot-cpp 静态库：$CPPLIB"; exit 1; }
  mkdir -p "$BIN"
  echo "libtool 合并 godot-cpp 符号 ..."
  libtool -static -o "$OURS" "$STAGED" "$CPPLIB"   # 每次从暂存重新合并，幂等

  # 3b-ios. sherpa/onnxruntime 的 xcframework 放到 bin/ 下，供 .gdextension 的
  # [dependencies] 引用——Godot 的 iOS 导出会把它们拷进 Xcode 工程并链接。
  rm -rf "$BIN/sherpa-onnx.xcframework" "$BIN/onnxruntime.xcframework"
  cp -R "$EXT/sherpa-onnx-ios/sherpa-onnx.xcframework" "$BIN/"
  cp -R "$EXT/sherpa-onnx-ios/onnxruntime.xcframework" "$BIN/"

  echo "完成：$OURS（$(du -h "$OURS" | cut -f1)）+ sherpa/onnxruntime xcframework"
  exit 0
fi

# 3b. sherpa/onnxruntime dylib 放进 .framework 内（rpath=@loader_path 自包含，
#     framework 走到哪 dylib 跟到哪；P3 打包 .app 时随 framework 一起进 Frameworks/）。
FW="$BIN/libmaliang_asr.macos.$TARGET.framework"
if [ -d "$FW" ]; then
  cp "$EXT/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib" "$FW/"
  cp "$EXT/sherpa-onnx/lib/libonnxruntime.1.24.4.dylib" "$FW/"
fi

# 4. 让 Godot 把 .gdextension 写进 .godot/extension_list.cfg（headless --script 只读此清单，
#    否则单例加载不出来——踩过：--import 不登记扩展，必须 --editor 扫一次）
echo "editor 扫描登记扩展 ..."
"$GODOT" --headless --editor --path "$ROOT" --quit >/dev/null 2>&1 || true

echo "完成：$(ls "$BIN" 2>/dev/null)"
