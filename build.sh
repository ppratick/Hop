#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hop-build.XXXXXX")
trap 'rm -rf "$BUILD_TMP"' EXIT
APP="$BUILD_TMP/Hop.app"
DESTINATION="${HOP_APP_PATH:-/Applications/Hop.app}"
BUILD_VERSION=$(date +%Y%m%d%H%M%S)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -module-cache-path "$BUILD_TMP/modules" -framework AppKit -framework SwiftUI "$PROJECT_DIR/Sources/Hop/"*.swift -o "$APP/Contents/MacOS/Hop"
"$APP/Contents/MacOS/Hop" --write-icon "$BUILD_TMP/icon.png"
mkdir -p "$BUILD_TMP/AppIcon.iconset"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$BUILD_TMP/icon.png" --out "$BUILD_TMP/AppIcon.iconset/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    DOUBLE_SIZE=$((ICON_SIZE * 2))
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$BUILD_TMP/icon.png" --out "$BUILD_TMP/AppIcon.iconset/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/HopIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Hop</string>
<key>CFBundleIdentifier</key><string>com.pratick.hop</string>
<key>CFBundleName</key><string>Hop</string>
<key>CFBundleIconFile</key><string>HopIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Open Terminal in your selected project folder.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "${DESTINATION:h}"
if [[ -e "$DESTINATION" ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
    [[ "$EXISTING_ID" == "com.pratick.hop" ]] || { print -u2 "Destination belongs to another app: $DESTINATION"; exit 1; }
fi
ditto --norsrc "$APP" "$DESTINATION"
codesign --force --sign - "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
print "Built $DESTINATION"
