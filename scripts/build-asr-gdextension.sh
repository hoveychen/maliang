#!/usr/bin/env bash
# macOS/桌面端侧 ASR GDExtension 一键构建。
# 产出 addons/maliang_asr_native/bin/ 下的 .framework（gitignore），供 Godot 4.6 加载出
# MaliangAsr 单例——与 Android 的 asr_plugin 同名同接口，客户端零改动（见 docs/macos-asr-feasibility.md）。
#
# 依赖：git、python3+scons（pip install scons）、Xcode CLT（clang++）。
# 前置产物均 gitignore、可由本脚本重新生成：
#   - gdextension_asr/godot-cpp/            godot-cpp master（v10，锁 4.6 API）
#   - gdextension_asr/extension_api.json    从本机 Godot 4.6 dump（锁定 ABI）
#   - addons/maliang_asr_native/bin/*.framework
#
# 用法：scripts/build-asr-gdextension.sh [editor|template_debug|template_release] [arm64|x86_64|universal]
#   默认 editor / arm64（本机冒烟与 headless 测试用）。
#   P3 打包 .app 用 template_release + universal。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/gdextension_asr"
TARGET="${1:-editor}"
ARCH="${2:-arm64}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

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

# 3. 构建 framework
echo "scons target=$TARGET arch=$ARCH ..."
( cd "$EXT" && scons target="$TARGET" arch="$ARCH" )

# 4. 让 Godot 把 .gdextension 写进 .godot/extension_list.cfg（headless --script 只读此清单，
#    否则单例加载不出来——踩过：--import 不登记扩展，必须 --editor 扫一次）
echo "editor 扫描登记扩展 ..."
"$GODOT" --headless --editor --path "$ROOT" --quit >/dev/null 2>&1 || true

echo "完成：$(ls "$ROOT"/addons/maliang_asr_native/bin/ 2>/dev/null)"
