#!/bin/bash
# VoicePaste をログイン時に自動起動させる（launchd のユーザーエージェントとして登録する）
#
#   ./install-autostart.sh              登録して、いますぐ起動する
#   ./install-autostart.sh --uninstall  登録を解除する
#
# 登録内容そのものはアプリ側（Sources/VoicePasteCore/LoginItem.swift）が持っている。
# メニューバーの「ログイン時に起動」と同じ登録を読み書きするので、両方が食い違うことはない。
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 非対話シェルで日本語を正しく扱う
cd "$(dirname "$0")"

APP_BIN="$(pwd)/build/VoicePaste.app/Contents/MacOS/VoicePaste"
if [ ! -x "$APP_BIN" ]; then
  echo "❌ ${APP_BIN} が見つかりません。先に ./build.sh を実行してください。"
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  exec "$APP_BIN" --uninstall-autostart
fi

# 手で起動している分があれば止める（launchd が起動する分と二重になり、ホットキーを奪い合うため）
pkill -f "VoicePaste.app/Contents/MacOS/VoicePaste" 2>/dev/null || true
sleep 1

"$APP_BIN" --install-autostart
echo "   解除:         ./install-autostart.sh --uninstall"
