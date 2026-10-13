#!/bin/bash
# Builds dist/Phonogrify.app: compiles, assembles the bundle, draws the icon, signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Phonogrify"

APP="dist/Phonogrify.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Phonogrify"
cp Support/Info.plist "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Signed for this Mac only. To give it to someone else, sign with a Developer ID and notarise.
codesign --force --sign - --options runtime --entitlements Support/Phonogrify.entitlements "$APP"
echo "Built $APP"
