#!/bin/bash
# Mac上で実行すると WindowResizeHUD.app を組み立てます。
set -euo pipefail
cd "$(dirname "$0")"

echo "ビルド中..."
swift build -c release

APP="WindowResizeHUD.app"
BIN=".build/release/WindowResizeHUD"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowResizeHUD"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WindowResizeHUD</string>
    <key>CFBundleDisplayName</key>
    <string>Window Resize HUD</string>
    <key>CFBundleIdentifier</key>
    <string>local.windowresizehud.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>WindowResizeHUD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 (a2cnsmr)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# アイコン (AppIcon.iconset があれば .icns 化して組み込む)
if [ -d "AppIcon.iconset" ] && command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
    echo "アイコンを組み込みました: AppIcon.icns"
fi

# 署名 (安定した証明書で署名しないと、macOS が別アプリ扱いして
# アクセシビリティ許可が起動のたびにリセットされる)
# SIGN_IDENTITY で証明書名を明示指定できる (未指定なら最初の証明書を自動検出)
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"[^"]*"' | head -n 1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "署名しました: $IDENTITY"
else
    codesign --force --deep --sign - "$APP"
    echo "注意: コード署名用の証明書が見つからないため、その場限りの署名 (ad-hoc) をしました。"
    echo "この場合、アクセシビリティ許可が毎回求められることがあります。"
    echo "解消法: キーチェーンアクセス > 証明書アシスタント > 証明書を作成... で、"
    echo "「自分で署名したルート」「コード署名」の証明書を1つ作ってから再ビルドしてください。"
    echo "(Xcode に Apple ID でサインイン済みなら Apple Development 証明書が自動で使われます)"
fi

echo ""
echo "完成: $APP"
echo "初回は アクセシビリティ許可 が必要です:"
echo "  1. $APP を起動する"
echo "  2. システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可する"
echo "  3. アプリを再起動する"
