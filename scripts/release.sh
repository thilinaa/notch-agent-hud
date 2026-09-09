#!/bin/bash
# Produce a notarized, Gatekeeper-clean DMG for a tagged release.
#
#   ./scripts/release.sh v1.2.0
#
# Requirements (one-time):
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notarization credentials stored in the keychain:
#        xcrun notarytool store-credentials notchhud --apple-id you@example.com \
#              --team-id TEAMID --password <app-specific-password>
#      Override the profile name with NOTARY_PROFILE.
#
# Output: dist/NotchHUD-<version>.dmg plus a .sha256 next to it.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-$(git describe --tags --exact-match 2>/dev/null || true)}"
[ -n "$TAG" ] || { echo "usage: $0 vX.Y.Z (or run on a tagged commit)" >&2; exit 1; }
VERSION="${TAG#v}"
PROFILE="${NOTARY_PROFILE:-notchhud}"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | awk '{print $2}' || true)
[ -n "$IDENTITY" ] || { echo "error: no 'Developer ID Application' certificate in the keychain." >&2; exit 1; }

echo "==> Building $VERSION"
VERSION="$VERSION" SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh >/dev/null
APP="build/NotchHUD.app"

echo "==> Signing with hardened runtime and secure timestamp"
codesign --force --deep --options runtime --timestamp \
  --entitlements Resources/NotchHUD.entitlements -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing the app"
mkdir -p dist
ZIP="dist/NotchHUD-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Building the DMG"
DMG="dist/NotchHUD-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "NotchHUD $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Signing and notarizing the DMG"
codesign --force --timestamp -s "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG"
