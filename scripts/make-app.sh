#!/bin/bash
# Build NotchHUD and assemble build/NotchHUD.app for local use.
#
#   VERSION=1.2.0 BUILD=42 ./scripts/make-app.sh
#
# VERSION defaults to the nearest git tag (v1.2.0 → 1.2.0), else 0.0.0-dev;
# BUILD defaults to the commit count. Signing: a Developer ID Application
# identity if one is in the keychain, else Apple Development, else ad-hoc.
# Set SIGN_IDENTITY to force one. Notarized release builds use
# scripts/release.sh, which calls this script.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
VERSION="${VERSION:-${TAG#v}}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release

APP="build/NotchHUD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchHUD "$APP/Contents/MacOS/NotchHUD"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

# Prefer a stable identity: the Accessibility grant is tied to the signature
# and survives rebuilds only with a real certificate (ad-hoc breaks it every time).
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | awk '{print $2}' || true)
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}' || true)
fi
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/NotchHUD.entitlements \
  -s "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP (version $VERSION build $BUILD)"
echo "Signed as: ${SIGN_IDENTITY:-ad-hoc}"
echo "Run with: open $(pwd)/$APP"
