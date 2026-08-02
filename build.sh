#!/bin/bash
# VoicePaste.app をビルドして build/ に組み立てる
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 非対話シェルで日本語を正しく扱う
cd "$(dirname "$0")"

swift build -c release

APP=build/VoicePaste.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VoicePaste "$APP/Contents/MacOS/VoicePaste"
cp Info.plist "$APP/Contents/Info.plist"

# 固定した自己署名証明書で署名する（署名が毎回同じ→アクセシビリティ許可が外れない）。
# 証明書が無ければ setup-signing.sh を一度実行するよう促し、暫定でad-hoc署名する。
IDENTITY="VoicePaste Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/voicepaste-signing.keychain-db"
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
  echo "🔏 署名: ${IDENTITY}（固定・許可は維持されます）"
else
  codesign --force --sign - "$APP"
  echo "⚠️  ad-hoc署名です。許可を外れなくするには一度 ./setup-signing.sh を実行してください。"
fi

echo "✅ Built: $(pwd)/$APP"
echo "   起動: open $APP"
