#!/usr/bin/env bash
# maliang Mac 一键试玩。
# 用法：scripts/play-mac.sh [--local] [--cache]
#   (默认)   每次重新导出并启动 app（打包路线），连线上 maliang-api.muveeai.com。
#            导出会自动注入端侧 ASR 模型并 ad-hoc 签名（否则扩展加载不出/无模型）；
#            SIGN_IDENTITY 可覆盖为 Developer ID。分发级（公证）包走 package-mac-app.sh。
#   --cache  复用已有 build/maliang.app、跳过导出（改动不会生效，只图快开旧包）。
#   --local  改连本机后端：起 Node 后端在 :8090，用 MALIANG_API_BASE 让 app 指向它。
#            （宿主 8080 常被 Docker 等占用，故本地固定用 8090。）
# 说明：客户端启动时从 api.base 推导后端地址（world.gd），api.gd 支持 MALIANG_API_BASE
#       环境变量覆盖，故本地/远程切换无需改任何代码。
# 前置：Godot 导出模板已装；--local 时 server/.env 已配密钥。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/maliang.app"
PORT=8090
LOCAL=0
CACHE=0
for a in "$@"; do
  case "$a" in
    --local)  LOCAL=1;;
    --remote) LOCAL=0;;
    --cache)  CACHE=1;;
    --build)  ;;  # 兼容旧习惯：现在默认就重导，--build 为空操作
    *) echo "未知参数：${a}（支持 --local / --cache）"; exit 1;;
  esac
done

# 选一个与已装导出模板匹配的 Godot：默认 /Applications/Godot.app（非 mono，4.6.3 模板已装），
# 可用 GODOT 环境变量覆盖为任意 Godot 可执行文件路径。
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$(command -v godot || true)"
[ -n "$GODOT" ] || { echo "找不到 Godot，可用 GODOT=/path/to/Godot 指定"; exit 1; }

# 1. 默认每次重新导出（打包路线）；--cache 且已有包时复用、跳过导出。
if [ "$CACHE" = 1 ] && [ -d "$APP" ]; then
  echo "复用已有包 $APP（--cache，源码改动不会生效）。"
else
  [ "$CACHE" = 1 ] && echo "指定了 --cache 但 $APP 不存在，仍需导出一次。"
  echo "导出 macOS app（$("$GODOT" --version)）..."
  rm -rf "$APP"
  "$GODOT" --headless --path "$ROOT" --export-debug macOS "$APP"

  # 端侧 ASR：注入模型 + 整包签名。
  # 模型 73MB 要在签名前放进 .app（Godot 内联签盖不住后加的模型，故 export preset
  # codesign=0，这里手动签）。本机自测默认 ad-hoc（不依赖证书/公证）；
  # 要做分发级包用 scripts/package-mac-app.sh（Developer ID + 公证）。
  ASR_DIR="sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12"
  # 模型源：优先本 checkout 的 server/models；worktree 里没有则回主 checkout 取。
  MODEL_SRC="${MODEL_SRC:-$ROOT/server/models}"
  if [ ! -f "$MODEL_SRC/$ASR_DIR/tokens.txt" ]; then
    MODEL_SRC="$(cd "$(git -C "$ROOT" rev-parse --git-common-dir)/.." && pwd)/server/models"
  fi
  [ -f "$MODEL_SRC/$ASR_DIR/tokens.txt" ] \
    || { echo "缺 ASR 模型：$MODEL_SRC/$ASR_DIR（先跑 server/scripts/fetch-voice-models.sh）"; exit 1; }

  echo "注入端侧 ASR 模型 ..."
  DST="$APP/Contents/Resources/asr-models/$ASR_DIR"
  mkdir -p "$DST"
  for f in encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx \
           decoder-epoch-20-avg-1-chunk-16-left-128.onnx \
           joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx tokens.txt; do
    cp "$MODEL_SRC/$ASR_DIR/$f" "$DST/"
  done

  # 整包签名（从内到外：dylib/framework → 主程序带 entitlements）。
  # SIGN_IDENTITY 默认 "-"（ad-hoc）；disable-library-validation 允许加载 sherpa dylib。
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
  ENT="$ROOT/gdextension_asr/maliang.entitlements"
  FW="$APP/Contents/Frameworks/libmaliang_asr.macos.template_debug.framework"
  echo "codesign（identity=${SIGN_IDENTITY}）..."
  codesign --force --options runtime -s "$SIGN_IDENTITY" \
    "$FW/libonnxruntime.1.24.4.dylib" "$FW/libsherpa-onnx-c-api.dylib" \
    "$FW/libmaliang_asr.macos.template_debug"
  codesign --force --options runtime --entitlements "$ENT" -s "$SIGN_IDENTITY" "$APP"
fi

# 2a. 远程模式：双击式启动，连线上服务器，不起本地后端。
if [ "$LOCAL" = 0 ]; then
  echo "启动 ${APP}（连远程 maliang-api.muveeai.com）..."
  open -W "$APP"
  exit 0
fi

# 2b. 本地模式：起后端 :8090，并让 app 通过 MALIANG_API_BASE 指向它。
API_BASE="http://127.0.0.1:$PORT"

# maliang 后端的应答签名：GET /worlds/default 返回含 "id":"default" 的世界 JSON。
# 用来判断 :$PORT 上的服务是不是 maliang（而非 Docker 等别的监听者，后者对未知路径回 404）。
is_maliang() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/worlds/default" 2>/dev/null \
    | grep -q '"id":"default"'
}

SRV_PGID=""
if lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  if is_maliang; then
    echo "检测到 :$PORT 已是 maliang 后端，复用。"
  else
    echo ":$PORT 被非 maliang 服务占用（可能是 Docker），先停掉它再试。"; exit 1
  fi
else
  echo "启动后端 server (:$PORT) ..."
  set -m                                       # 让后台任务独立成进程组，便于整组收尾
  ( cd "$ROOT/server" && PORT=$PORT npm start ) &
  SRV_PGID=$!                                  # 监控模式下 job pid == pgid
  set +m
  for _ in $(seq 1 20); do                     # 等端口起来（最多 ~10s）
    lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.5
  done
  lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    || { echo "后端未能在 :$PORT 起来，看上面的日志"; exit 1; }
fi

# 退出时收尾（仅收我们起的后端；复用现有后端时不动它）。
cleanup() {
  if [ -n "$SRV_PGID" ]; then
    kill -TERM -"$SRV_PGID" 2>/dev/null || true
    echo "已停后端 (pgid $SRV_PGID)。"
  fi
}
trap cleanup EXIT INT TERM

# 直接跑 app 内可执行文件：open 经 launchd 启动、不继承 shell 环境变量，无法传 MALIANG_API_BASE。
# 直跑既能传环境变量、又能看到 stdout 日志，且前台阻塞到窗口关闭，随后触发上面的收尾。
# 可执行文件名跟着导出预设里的产品名走（现为「马良小世界」），别写死——从 Info.plist 读。
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[ -x "$BIN" ] || { echo "找不到 app 可执行文件：$BIN"; exit 1; }
echo "启动 app（连本地 ${API_BASE}，关窗口或 Ctrl-C 收尾）..."
MALIANG_API_BASE="$API_BASE" "$BIN"
