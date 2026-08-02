#!/bin/bash
# VoicePaste用の「固定した自己署名コード署名証明書」を一度だけ作る。
# これで署名が毎回同じになり、再ビルドしてもmacOSのアクセシビリティ許可が外れなくなる。
# ログインキーチェーンのパスワードには触れず、専用キーチェーンを使う。
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 非対話シェルで日本語を正しく扱う
cd "$(dirname "$0")"

IDENTITY="VoicePaste Self-Signed"
KEYCHAIN="voicepaste-signing.keychain-db"
KEYCHAIN_PASS="voicepaste"   # ローカル専用キーチェーンのパスワード（機密ではない）
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 既に証明書があれば何もしない（冪等）
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✅ 署名証明書「$IDENTITY」は既に存在します。セットアップ不要。"
  exit 0
fi

echo "▶ 自己署名コード署名証明書を作成中…"

# 1. コード署名用の拡張を持つ自己署名証明書を openssl で生成
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/cert.cnf" 2>/dev/null

# -legacy + SHA1系: openssl 3系のデフォルト暗号はApple Securityが読めないため旧形式で書き出す
openssl pkcs12 -export -legacy \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY" -out "$WORK/identity.p12" -passout pass:voicepaste 2>/dev/null

# 2. 専用キーチェーンを作成（既存なら作り直し）
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # 自動ロック無効化
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

# 3. p12をインポート（codesignが鍵を使えるよう -T 指定）
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P voicepaste \
  -T /usr/bin/codesign -T /usr/bin/security

# 4. codesignが非対話で鍵を使えるようにする（GUIパスワードプロンプト回避）
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1

# 5. 検索リストに専用キーチェーンを追加（codesignが -s で見つけられるように）
EXISTING=$(security list-keychains -d user | sed 's/[",]//g' | xargs)
if ! echo "$EXISTING" | grep -q "$KEYCHAIN"; then
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo
echo "✅ 署名証明書「$IDENTITY」を作成しました。"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
echo "   次回以降 ./build.sh はこの証明書で署名します（許可が外れなくなります）。"
