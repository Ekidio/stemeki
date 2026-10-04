#!/bin/zsh
# Builds the app and packs it into dist/STEMEKI-<version>.dmg, ready to upload to a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP="dist/STEMEKI.app"
DMG="dist/STEMEKI-$VERSION.dmg"
BG=".dmg"

if [[ ! -x .venv/bin/dmgbuild ]]; then
    echo "→ dmgbuild telepítése (.venv)"
    # dmgbuild >= 1.6.7 is needed for backgrounds on macOS 26, and it requires Python >= 3.10.
    PY=$( (command -v python3.14 python3.13 python3.12 python3.11 python3.10 2>/dev/null || true) | head -1)
    "${PY:?Python 3.10+ szükséges a DMG készítéséhez: brew install python}" -m venv .venv
    .venv/bin/pip install -q "dmgbuild>=1.6.7"
fi

echo "→ DMG háttér"
mkdir -p "$BG"
swift Tools/MakeDmgBackground.swift "$BG/background.png" 1
swift Tools/MakeDmgBackground.swift "$BG/background@2x.png" 2
tiffutil -cathidpicheck "$BG/background.png" "$BG/background@2x.png" -out "$BG/background.tiff" 2>/dev/null

echo "→ DMG készítése"
rm -f "$DMG"
.venv/bin/dmgbuild -s Tools/dmg-settings.py \
    -D app="$APP" -D background="$BG/background.tiff" \
    "STEMEKI" "$DMG"

echo "✓ Kész: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
