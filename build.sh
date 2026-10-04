#!/bin/zsh
# Builds "STEMEKI.app" (Apple Silicon) into dist/.
# Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="STEMEKI"
APP="dist/$APP_NAME.app"
ICON_DIR=".icon"
BUILD_DIR=".build"

# App icon (generated once).
if [[ ! -f "$ICON_DIR/AppIcon.icns" ]]; then
    echo "→ Ikon készítése"
    mkdir -p "$ICON_DIR/AppIcon.iconset"
    swift Tools/MakeIcon.swift "$ICON_DIR/icon-1024.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_DIR/icon-1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$ICON_DIR/icon-1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICON_DIR/AppIcon.icns"
fi

echo "→ Fordítás (arm64)"
mkdir -p "$BUILD_DIR"
swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos14.0 \
    -o "$BUILD_DIR/$APP_NAME" \
    Sources/*.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ICON_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/*.py "$APP/Contents/Resources/"

echo "→ Aláírás (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    echo "→ Telepítés: $DEST"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
fi

echo "✓ Kész: $APP"
