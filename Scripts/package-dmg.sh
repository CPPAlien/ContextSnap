#!/bin/bash
# Build ContextSnap.app and package it into a distributable .dmg.
# Usage: ./Scripts/package-dmg.sh [version]
#   version defaults to the value in Resources/Info.plist (CFBundleShortVersionString).
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="ContextSnap"
PLIST="Resources/Info.plist"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo 0.1.0)}"

DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/stage"
DMG_PATH="$DIST_DIR/${NAME}-${VERSION}.dmg"

./Scripts/build-app.sh release
APP_DIR=".build/release/${NAME}.app"
[ -d "$APP_DIR" ] || { echo "missing $APP_DIR"; exit 1; }

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> creating $DMG_PATH"
hdiutil create \
    -volname "$NAME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo
echo "Built: $DMG_PATH"
echo "SHA256: $SHA256"
