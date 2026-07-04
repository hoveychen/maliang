#!/usr/bin/env bash
# 端侧 ASR 插件一键就绪：下 sherpa AAR + Zipformer 模型 → 构建插件 AAR（模型打进 AAR assets）→ 归位。
# 产物均 gitignore：addons/maliang_asr/bin/*.aar 与 asr_plugin/src/main/assets/。
# 模型必须放插件 AAR 的 assets 里：AGP 会把 AAR assets 合并进 APK assets；
# 而 android/assets/ 没有任何 gradle sourceSets 引用，放那里不会进 APK（曾因此端侧 ASR 静默失效）。
# 前置：android/build 里已安装 Godot gradle 模板（编辑器「安装 Android 构建模板」）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHERPA_VER="1.13.3"
SHERPA_AAR="sherpa-onnx-$SHERPA_VER.aar"
ASR_DIR="sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12"
BIN="$ROOT/addons/maliang_asr/bin"
ASSETS="$ROOT/asr_plugin/src/main/assets/asr-models"

mkdir -p "$BIN" "$ASSETS" "$ROOT/asr_plugin/libs"

# 1. sherpa AAR（推理引擎，含 4 ABI 原生库）
if [ ! -f "$BIN/$SHERPA_AAR" ]; then
  echo "下载 $SHERPA_AAR ..."
  curl -fL --retry 3 -o "$BIN/$SHERPA_AAR" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VER/$SHERPA_AAR"
fi

# 2. 编译期 classes.jar（AGP 不许 library 模块依赖本地 aar）
if [ ! -f "$ROOT/asr_plugin/libs/sherpa-onnx-classes.jar" ]; then
  unzip -o -q -j "$BIN/$SHERPA_AAR" classes.jar -d "$ROOT/asr_plugin/libs"
  mv "$ROOT/asr_plugin/libs/classes.jar" "$ROOT/asr_plugin/libs/sherpa-onnx-classes.jar"
fi
if [ ! -f "$ROOT/asr_plugin/libs/godot-lib-classes.jar" ]; then
  GODOT_LIB="$ROOT/android/build/libs/release/godot-lib.template_release.aar"
  [ -f "$GODOT_LIB" ] || { echo "缺少 $GODOT_LIB —— 先在 Godot 编辑器安装 Android 构建模板"; exit 1; }
  unzip -o -q -j "$GODOT_LIB" classes.jar -d "$ROOT/asr_plugin/libs"
  mv "$ROOT/asr_plugin/libs/classes.jar" "$ROOT/asr_plugin/libs/godot-lib-classes.jar"
fi

# 3. Zipformer 中文流式模型 → 插件 AAR assets（构建时打进 AAR，随 AAR 合并进 APK assets）
if [ ! -d "$ASSETS/$ASR_DIR" ]; then
  # 只带运行需要的：int8 encoder/joiner + fp32 decoder + tokens（省掉 fp32 大文件与测试音频，APK 少 ~250MB）
  NEED=(encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx \
        decoder-epoch-20-avg-1-chunk-16-left-128.onnx \
        joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx \
        tokens.txt)
  SRC="$ROOT/server/models/$ASR_DIR"
  TMP=""
  if [ ! -f "$SRC/tokens.txt" ]; then
    echo "下载 $ASR_DIR ..."
    TMP="$(mktemp -d)"
    curl -fL --retry 3 -o "$TMP/m.tar.bz2" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$ASR_DIR.tar.bz2"
    tar xjf "$TMP/m.tar.bz2" -C "$TMP"
    SRC="$TMP/$ASR_DIR"
  else
    echo "复用 server/models 里的同款模型（跳过下载）"
  fi
  mkdir -p "$ASSETS/$ASR_DIR"
  for f in "${NEED[@]}"; do cp "$SRC/$f" "$ASSETS/$ASR_DIR/"; done
  [ -n "$TMP" ] && rm -rf "$TMP"
fi

# 4. 构建插件 AAR 并归位
cd "$ROOT/asr_plugin"
./gradlew assembleRelease --console=plain -q
cp build/outputs/aar/maliang-asr-plugin-release.aar "$BIN/maliang-asr-plugin.aar"

echo "端侧 ASR 插件就绪："
ls -la "$BIN"
du -sh "$ASSETS/$ASR_DIR"
