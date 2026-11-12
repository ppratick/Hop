#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hop-build.XXXXXX")
trap 'rm -rf "$BUILD_TMP"' EXIT
DESTINATION="${HOP_APP_PATH:-/Applications/Hop.app}"
BUILD_VERSION=$(date +%Y%m%d%H%M%S)
xcrun xcodebuild -project "$PROJECT_DIR/Hop.xcodeproj" -scheme Hop \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_TMP/DerivedData" \
    CURRENT_PROJECT_VERSION="$BUILD_VERSION" build
APP="$BUILD_TMP/DerivedData/Build/Products/Release/Hop.app"
codesign --verify --deep --strict "$APP"
# Use Hop's staged installer so updates also remove obsolete bundle files.
"$APP/Contents/MacOS/Hop" --install-mac-app "$APP" "${DESTINATION:h}" "${DESTINATION:t}"
print "Built $DESTINATION"
