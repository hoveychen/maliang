#!/usr/bin/env bash
# maliang macOS .app 打包：导出 → 注入端侧 ASR 模型 → 整包签名 → 公证 → staple。
# 产出分发级（Gatekeeper accepted）的 build/maliang.app。
#
# 为何手动签而非 Godot 内联签：模型（73MB）要放进 .app 后再签，Godot 导出时的
# 内联签名盖不住后加的模型（会破坏封印）。故 export preset 里 codesign=0，本脚本
# 在装配完成后一次性 codesign 整包。
#
# 前置：
#   - scripts/build-asr-gdextension.sh template_release universal（framework 已就位）
#   - Godot 4.6 导出模板已装
#   - keychain 有 "Developer ID Application: ..." 身份 + notarytool profile（见下）
#   - 模型在 $MODEL_SRC（默认 <repo>/server/models，由 server/scripts/fetch-voice-models.sh 拉）
# 环境变量：
#   SIGN_IDENTITY   codesign 身份（默认 "Developer ID Application: Yuheng Chen (6HU93XQG5B)"）
#   NOTARY_PROFILE  notarytool keychain profile 名（默认 maliang-notary）
#                   建一次：xcrun notarytool store-credentials maliang-notary \
#                     --key <AuthKey.p8> --key-id <id> --issuer <issuer>
#   MODEL_SRC       模型源目录（默认 <repo>/server/models）
#   SKIP_NOTARIZE=1 只签不公证（本机自测用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$(command -v godot || true)"
APP="$ROOT/build/maliang.app"
ASR_DIR="sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Yuheng Chen (6HU93XQG5B)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-maliang-notary}"
MODEL_SRC="${MODEL_SRC:-$ROOT/server/models}"
ENT="$ROOT/gdextension_asr/maliang.entitlements"
FW_REL="Contents/Frameworks/libmaliang_asr.macos.template_release.framework"

MODEL_DIR="$MODEL_SRC/$ASR_DIR"
[ -f "$MODEL_DIR/tokens.txt" ] || { echo "缺模型：$MODEL_DIR（先跑 server/scripts/fetch-voice-models.sh）"; exit 1; }
[ -d "$ROOT/addons/maliang_asr_native/bin/$(basename "$FW_REL")" ] || \
  { echo "缺 release framework：先跑 scripts/build-asr-gdextension.sh template_release universal"; exit 1; }

# 1. 导出（未签名；codesign 在 preset 里为 0）
echo "==> 导出 macOS app"
mkdir -p "$ROOT/build"; rm -rf "$APP"
"$GODOT" --headless --path "$ROOT" --export-release macOS "$APP"

# 2. 注入端侧模型（只带运行需要的 4 个文件，与 Android/服务端同款权重）
echo "==> 注入 ASR 模型"
DST="$APP/Contents/Resources/asr-models/$ASR_DIR"
mkdir -p "$DST"
for f in encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx \
         decoder-epoch-20-avg-1-chunk-16-left-128.onnx \
         joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx tokens.txt; do
  cp "$MODEL_DIR/$f" "$DST/"
done

# 3. 整包签名（从内到外：dylib/framework → 主程序带 entitlements）
echo "==> codesign"
codesign --force --timestamp --options runtime -s "$SIGN_IDENTITY" \
  "$APP/$FW_REL/libonnxruntime.1.24.4.dylib" \
  "$APP/$FW_REL/libsherpa-onnx-c-api.dylib" \
  "$APP/$FW_REL/libmaliang_asr.macos.template_release"
codesign --force --timestamp --options runtime --entitlements "$ENT" -s "$SIGN_IDENTITY" "$APP"
codesign -vvv --strict "$APP"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> SKIP_NOTARIZE=1，跳过公证（本机自测）"; exit 0
fi

# 4. 公证 + staple
echo "==> 公证（走 Apple notary，几分钟）"
ZIP="$ROOT/build/maliang.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"
spctl -a -vvv "$APP"
echo "==> 完成：$APP（Notarized Developer ID）"
