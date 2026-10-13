#!/bin/bash
# Builds dist/Phonogrify.app, for Apple Silicon and Intel Macs alike, and
# dist/Phonogrify.zip to hand to someone: compiles, assembles the bundle, adds
# the icon, signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Phonogrify"

APP="dist/Phonogrify.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Phonogrify"
cp Support/Info.plist "$APP/Contents/Info.plist"

# The icon is one 1024 picture, Support/AppIcon.png, scaled to every size macOS asks for.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for POINTS in 16 32 128 256 512; do
    sips -z "$POINTS" "$POINTS" Support/AppIcon.png --out "$ICONSET/icon_${POINTS}x${POINTS}.png" >/dev/null
    DOUBLE=$((POINTS * 2))
    sips -z "$DOUBLE" "$DOUBLE" Support/AppIcon.png --out "$ICONSET/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Signed for this Mac only. To give it to someone else, sign with a Developer ID and notarise.
codesign --force --sign - --options runtime --entitlements Support/Phonogrify.entitlements "$APP"

rm -f dist/Phonogrify.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Phonogrify.zip
echo "Built $APP and dist/Phonogrify.zip"
