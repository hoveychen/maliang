#!/usr/bin/env bash
# 拉取本地语音模型（LocalASR/LocalTTS adapter 用），幂等：已存在则跳过。
# 用法：scripts/fetch-voice-models.sh [目标目录]   默认 server/models/
set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/models}"
BASE_ASR="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
BASE_TTS="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"

ASR_DIR="sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12"
TTS_DIR="kokoro-multi-lang-v1_1"

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
