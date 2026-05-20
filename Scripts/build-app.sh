#!/bin/bash
# Build ContextSnap.app from the SwiftPM executable.
# Usage: ./Scripts/build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
NAME="ContextSnap"
BUILD_DIR=".build/$([ "$CONFIG" = "release" ] && echo release || echo debug)"
APP_DIR="$BUILD_DIR/$NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$NAME" "$APP_DIR/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Sign with a stable self-signed dev cert if available, otherwise ad-hoc.
# A stable signature lets macOS preserve TCC permissions (Screen Recording etc.)
# across rebuilds. See Scripts/create-dev-cert.md for one-time setup.
DEV_IDENTITY="ContextSnap Dev"
BUNDLE_ID="app.contextsnap.ContextSnap"

if security find-identity -p codesigning | grep -q "$DEV_IDENTITY"; then
    echo "==> codesign with '$DEV_IDENTITY'"
    codesign --force --sign "$DEV_IDENTITY" --timestamp=none "$APP_DIR" >/dev/null
else
    echo "==> codesign ad-hoc (no '$DEV_IDENTITY' cert found)"
    codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
    # Ad-hoc signatures change every build → TCC won't recognize the app.
    # Reset its Screen Recording grant so the next launch re-prompts cleanly.
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo
echo "Built: $APP_DIR"
echo "Run:   open $APP_DIR"
