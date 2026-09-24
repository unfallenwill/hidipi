#!/bin/zsh
# 构建 HidiPi.app 并打包 DMG：swift build → icns → .app → codesign(ad-hoc) → .dmg
# 仅需 Command Line Tools（无需 Xcode）。用法：scripts/build-app.sh
set -euo pipefail
cd "${0:A:h}/.."

readonly APP_NAME="HidiPi"
readonly BUNDLE_ID="local.hidipi.app"
# CI（release workflow）用 tag 覆盖；本地构建用此默认值。
readonly VERSION="${HIDIPI_VERSION:-0.3.1}"

echo "▸ swift build -c release"
swift build -c release

echo "▸ 渲染图标 iconset → icns"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
.build/release/render-icon "$ICONSET"
mkdir -p "build/${APP_NAME}.app/Contents/Resources"
iconutil -c icns -o "build/${APP_NAME}.app/Contents/Resources/AppIcon.icns" "$ICONSET"

echo "▸ 组装 ${APP_NAME}.app"
mkdir -p "build/${APP_NAME}.app/Contents/MacOS"
cp .build/release/HidiPi "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

cat > "build/${APP_NAME}.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ ad-hoc 签名"
codesign --force --sign - "build/${APP_NAME}.app"

echo "▸ 打包 DMG"
DMG_DIR="build/dmg"
rm -rf "$DMG_DIR" dist
mkdir -p "$DMG_DIR" dist
cp -R "build/${APP_NAME}.app" "$DMG_DIR/"
ln -sfn /Applications "$DMG_DIR/Applications"
hdiutil create -volname "${APP_NAME}" -fs HFS+ -format UDZO \
    -srcfolder "$DMG_DIR" -ov "dist/${APP_NAME}-${VERSION}.dmg"

echo "✓ 完成：dist/${APP_NAME}-${VERSION}.dmg"
echo "  安装：打开 DMG，将 ${APP_NAME}.app 拖入 Applications。"
