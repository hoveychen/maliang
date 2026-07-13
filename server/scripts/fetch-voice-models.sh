#!/usr/bin/env bash
# 拉取语音模型，幂等：已存在则跳过。
# 用法：scripts/fetch-voice-models.sh [目标目录]   默认 server/models/
#
# 两个模型的归属不同，别把 ASR 当成服务端的东西删掉：
#   - TTS(Kokoro)：服务端 LocalTTSAdapter 用（真正的服务端模型）。
#   - ASR(Zipformer)：服务端【不再使用】——识别已整条搬到客户端端侧（2026-07-13）。
#     它留在这里是因为客户端的三条构建/测试链都从 server/models 取它：
#       scripts/play-mac.sh / scripts/package-mac-app.sh（注入 .app 的 Contents/Resources/asr-models）
#       scripts/build-asr-plugin.sh（打进 Android 插件 AAR 的 assets）
#       scripts/test-headless.sh（MALIANG_ASR_MODEL_DIR 指过来跑端侧识别回测）
#     所以：服务端部署其实用不到 ASR 那一半，但开发机/打包机需要它。
set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/models}"
BASE_ASR="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
BASE_TTS="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"

ASR_DIR="sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12" # 客户端端侧用（见上）
TTS_DIR="kokoro-multi-lang-v1_1"                                   # 服务端 TTS 用

mkdir -p "$DEST"
cd "$DEST"

fetch() { # fetch <目录名> <tar.bz2 URL>
  local dir="$1" url="$2"
  if [ -d "$dir" ]; then
    echo "已存在，跳过：$dir"
    return
  fi
  echo "下载 $url ..."
  curl -fL --retry 3 -o "$dir.tar.bz2" "$url"
  tar xjf "$dir.tar.bz2"
  rm "$dir.tar.bz2"
  echo "完成：$dir"
}

fetch "$ASR_DIR" "$BASE_ASR/$ASR_DIR.tar.bz2"
fetch "$TTS_DIR" "$BASE_TTS/$TTS_DIR.tar.bz2"

echo "全部模型就绪：$DEST"
