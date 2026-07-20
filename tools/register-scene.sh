#!/usr/bin/env bash
# 把导出的 .mltr（+ 可选 POI json）入库到 maliang-server：POST /admin/scenes。
# 地形二进制走 base64 传入，服务端 decodeTerrain 校验后进内容寻址资产库，scenes 表记 hash。
# 见 docs/multi-scene-design.md、server/src/server.ts 的 /admin/scenes、tools/export_terrain.gd。
#
# 用法:
#   SERVER_URL=http://127.0.0.1:8080 ADMIN_TOKEN=xxx \
#     tools/register-scene.sh <world_id> <scene_id> <name> <mltr_path> [pois_json_path] [portals_json_path]
#
# pois/portals 两个 json 由导出脚本一并产出（同名 .pois.json / .portals.json）。村庄与森林的
# 传送点互指，两张图都必须带 portals 重新入库，否则只有单向出口。
# 依赖: bash / base64 / jq / curl
set -euo pipefail

SERVER_URL="${SERVER_URL:?set SERVER_URL, e.g. http://127.0.0.1:8080}"
ADMIN_TOKEN="${ADMIN_TOKEN:?set ADMIN_TOKEN (= server MALIANG_ADMIN_TOKEN)}"
WORLD="${1:?world_id}"; SCENE="${2:?scene_id}"; NAME="${3:?display name}"; MLTR="${4:?.mltr path}"
POIS="${5:-}"; PORTALS="${6:-}"

[ -f "$MLTR" ] || { echo "找不到地形文件: $MLTR" >&2; exit 1; }
B64=$(base64 < "$MLTR" | tr -d '\n')
POIS_JSON="[]";    [ -n "$POIS" ]    && [ -f "$POIS" ]    && POIS_JSON=$(cat "$POIS")
PORTALS_JSON="[]"; [ -n "$PORTALS" ] && [ -f "$PORTALS" ] && PORTALS_JSON=$(cat "$PORTALS")

BODY=$(jq -n --arg w "$WORLD" --arg s "$SCENE" --arg n "$NAME" --arg b "$B64" \
  --argjson p "$POIS_JSON" --argjson q "$PORTALS_JSON" \
  '{worldId:$w, sceneId:$s, name:$n, terrainBase64:$b, pois:$p, portals:$q}')

curl -sS -X POST "$SERVER_URL/admin/scenes" \
  -H "content-type: application/json" -H "x-admin-token: $ADMIN_TOKEN" \
  -d "$BODY"
echo
