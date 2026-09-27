#!/bin/zsh
# Builds HidiPi.app and packages a DMG: swift build → icns → .app → codesign (ad-hoc) → .dmg
# Requires only Command Line Tools (no Xcode). Usage: scripts/build-app.sh
set -euo pipefail
cd "${0:A:h}/.."

readonly APP_NAME="HidiPi"
readonly BUNDLE_ID="local.hidipi.app"
# CI (the release workflow) overrides the version from the tag; local builds use this default.
readonly VERSION="${HIDIPI_VERSION:-0.3.5}"

echo "▸ swift build -c release"
swift build -c release

# Label the artifact from the compiled executable, not the build host.
readonly BINARY_ARCHS="$(lipo -archs .build/release/HidiPi)"
case "$BINARY_ARCHS" in
  arm64) ARTIFACT_ARCH="arm64" ;;
  x86_64) ARTIFACT_ARCH="x86_64" ;;
  "arm64 x86_64"|"x86_64 arm64") ARTIFACT_ARCH="universal" ;;
  *) echo "Unsupported executable architectures: $BINARY_ARCHS" >&2; exit 1 ;;
esac
readonly ARTIFACT_ARCH
readonly DMG_NAME="hidipi-${VERSION:l}-${ARTIFACT_ARCH}.dmg"

echo "▸ Render iconset → icns"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
.build/release/render-icon "$ICONSET"
mkdir -p "build/${APP_NAME}.app/Contents/Resources"
iconutil -c icns -o "build/${APP_NAME}.app/Contents/Resources/AppIcon.icns" "$ICONSET"

echo "▸ Assemble ${APP_NAME}.app"
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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc codesign"
codesign --force --sign - "build/${APP_NAME}.app"

echo "▸ Package DMG"
DMG_DIR="build/dmg"
rm -rf "$DMG_DIR" dist
mkdir -p "$DMG_DIR" dist
cp -R "build/${APP_NAME}.app" "$DMG_DIR/"
ln -sfn /Applications "$DMG_DIR/Applications"
hdiutil create -volname "${APP_NAME}" -fs HFS+ -format UDZO \
    -srcfolder "$DMG_DIR" -ov "dist/${DMG_NAME}"

echo "✓ Done: dist/${DMG_NAME}"
echo "  Install: open the DMG and drag ${APP_NAME}.app to Applications."
