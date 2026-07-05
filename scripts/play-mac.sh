#!/usr/bin/env bash
# maliang Mac 一键试玩。
# 用法：scripts/play-mac.sh [--local] [--build]
#   (默认)   导出(缺失时)并启动 app，连线上 maliang-api.muveeai.com。
#   --local  改连本机后端：起 Node 后端在 :8090，用 MALIANG_API_BASE 让 app 指向它。
#            （宿主 8080 常被 Docker 等占用，故本地固定用 8090。）
#   --build  强制重新导出 app（否则仅在 build/maliang.app 缺失时导出）。
# 说明：客户端启动时从 api.base 推导后端地址（world.gd），api.gd 支持 MALIANG_API_BASE
#       环境变量覆盖，故本地/远程切换无需改任何代码。
# 前置：Godot 导出模板已装；--local 时 server/.env 已配密钥。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/maliang.app"
BIN="$APP/Contents/MacOS/maliang"
PORT=8090
LOCAL=0
BUILD=0
for a in "$@"; do
  case "$a" in
    --local)  LOCAL=1;;
    --remote) LOCAL=0;;
    --build)  BUILD=1;;
    *) echo "未知参数：$a（支持 --local / --build）"; exit 1;;
  esac
done

# 选一个与已装导出模板匹配的 Godot：默认 /Applications/Godot.app（非 mono，4.6.3 模板已装），
# 可用 GODOT 环境变量覆盖为任意 Godot 可执行文件路径。
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$(command -v godot || true)"
[ -n "$GODOT" ] || { echo "找不到 Godot，可用 GODOT=/path/to/Godot 指定"; exit 1; }

# 1. 需要时导出 app（缺失或 --build）
if [ ! -d "$APP" ] || [ "$BUILD" = 1 ]; then
  echo "导出 macOS app（$("$GODOT" --version)）..."
  rm -rf "$APP"
  "$GODOT" --headless --path "$ROOT" --export-debug macOS "$APP"
fi

# 2a. 远程模式：双击式启动，连线上服务器，不起本地后端。
if [ "$LOCAL" = 0 ]; then
  echo "启动 $APP（连远程 maliang-api.muveeai.com）..."
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
echo "启动 app（连本地 $API_BASE，关窗口或 Ctrl-C 收尾）..."
MALIANG_API_BASE="$API_BASE" "$BIN"
