#!/bin/zsh
# Builds the DMG and a Sparkle appcast for one GitHub release.
# Output: dist/release-<version>/ with the DMG and appcast.xml, ready to upload.
set -euo pipefail
cd "$(dirname "$0")"
source ./release.conf

if [[ -z "$GITHUB_REPO" ]]; then
    echo "✗ Előbb írd be a GitHub repó nevét a release.conf fájlba (GITHUB_REPO=\"felhasznalo/repo\")."
    exit 1
fi

./make-dmg.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
OUT="dist/release-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "dist/STEMEKI-$VERSION.dmg" "$OUT/"

echo "→ appcast.xml (EdDSA aláírással a kulcskarikából)"
.vendor/Sparkle-*/bin/generate_appcast \
    --account exe-futtato \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/$TAG/" \
    --link "https://github.com/$GITHUB_REPO" \
    -o "$OUT/appcast.xml" \
    "$OUT"

cat <<EOF

✓ Kiadás előkészítve: $OUT

Feltöltés a GitHubra:
  1. https://github.com/$GITHUB_REPO/releases/new
  2. Tag: $TAG   Cím: STEMEKI $VERSION
  3. Húzd be MINDKÉT fájlt:  $OUT/STEMEKI-$VERSION.dmg  és  $OUT/appcast.xml
  4. „Set as the latest release” legyen bejelölve → Publish release

A meglévő felhasználók appja 24 órán belül felajánlja a frissítést.
EOF
