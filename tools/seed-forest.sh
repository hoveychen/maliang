#!/usr/bin/env bash
# 把森林村民种进 maliang-server：POST /admin/worlds/<world>/seed-forest。
# 角色定义在 server/src/forest_characters.ts（FOREST_CHARACTER_SEEDS）；服务端走生图管线
# （image→cutout→朝向兜底→trim）落库 sceneId=forest，并后台补 idle 动画。
# 幂等：同名角色已存在则跳过，重跑安全。立绘不满意用 regen-sprite 端点原地重生成，别重种。
#
# 用法:
#   SERVER_URL=http://127.0.0.1:8080 ADMIN_TOKEN=xxx tools/seed-forest.sh [world_id] [only]
#   world_id 缺省 default；only 形如 "果果,露露"（只种指定名字，低成本单个验证）。
# 依赖: bash / curl >= 7.87（--url-query，中文名字自动 URL 编码）
set -euo pipefail

SERVER_URL="${SERVER_URL:?set SERVER_URL, e.g. http://127.0.0.1:8080}"
ADMIN_TOKEN="${ADMIN_TOKEN:?set ADMIN_TOKEN (= server MALIANG_ADMIN_TOKEN)}"
WORLD="${1:-default}"
ONLY="${2:-}"

ARGS=(-sS -X POST "$SERVER_URL/admin/worlds/$WORLD/seed-forest" -H "x-admin-token: $ADMIN_TOKEN")
[ -n "$ONLY" ] && ARGS+=(--url-query "only=$ONLY")
curl "${ARGS[@]}"
echo
