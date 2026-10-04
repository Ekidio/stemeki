#!/bin/zsh
# Builds "STEMEKI.app" (Apple Silicon) into dist/.
# Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

source ./release.conf

APP_NAME="STEMEKI"
APP="dist/$APP_NAME.app"
ICON_DIR=".icon"
BUILD_DIR=".build"

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_DIR=".vendor/Sparkle-$SPARKLE_VERSION"

# Sparkle (auto-update framework), downloaded once and checksum-verified (same as EXEKI).
if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
    echo "→ Sparkle $SPARKLE_VERSION letöltése"
    mkdir -p "$SPARKLE_DIR"
    ARCHIVE="$SPARKLE_DIR.tar.xz"
    curl -sSL -o "$ARCHIVE" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $ARCHIVE" | shasum -a 256 -c --status || { echo "✗ Sparkle ellenőrzőösszeg hibás"; rm -rf "$SPARKLE_DIR" "$ARCHIVE"; exit 1; }
    tar -xf "$ARCHIVE" -C "$SPARKLE_DIR"
    rm "$ARCHIVE"
fi

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
    -F "$SPARKLE_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$BUILD_DIR/$APP_NAME" \
    Sources/*.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"
cp Info.plist "$PLIST"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(cat sparkle-public-key.txt)" "$PLIST"
if [[ -n "$GITHUB_REPO" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml" "$PLIST"
else
    echo "  (release.conf: GITHUB_REPO üres → automatikus frissítés kikapcsolva)"
fi
cp "$ICON_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/*.py Resources/engine-requirements.txt "$APP/Contents/Resources/"

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
