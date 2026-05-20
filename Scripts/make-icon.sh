#!/bin/bash
# Generates Resources/AppIcon.icns from Scripts/make-icon.swift.
set -euo pipefail

cd "$(dirname "$0")/.."

STAGE="$(mktemp -d)/AppIcon.iconset"
OUT="Resources/AppIcon.icns"

echo "==> rendering iconset to $STAGE"
mkdir -p "$STAGE"
swift Scripts/make-icon.swift "$STAGE"

echo "==> iconutil → $OUT"
iconutil -c icns "$STAGE" -o "$OUT"

echo
echo "Wrote: $OUT"
