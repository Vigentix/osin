#!/usr/bin/env bash
# Builds a universal release of Osin and packages it as a DMG (and a ZIP for Sparkle).
#
#   scripts/release.sh <version> [build-number]
#
# Optional environment (see docs/RELEASING.md):
#   DEVELOPER_ID              "Developer ID Application: Name (TEAMID)". Without it the app is ad-hoc signed.
#   NOTARY_PROFILE            notarytool keychain profile. Requires DEVELOPER_ID.
#   SPARKLE_PUBLIC_KEY        EdDSA public key embedded in Info.plist; enables in-app updates.
#   SPARKLE_PRIVATE_KEY_FILE  EdDSA private key file used to sign the appcast.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-$(git rev-list --count HEAD)}"
OUT="build/release"
APP="build/Build/Products/Release/Osin.app"
DMG="$OUT/Osin-$VERSION.dmg"
ZIP="$OUT/Osin-$VERSION.zip"

rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Building Osin $VERSION ($BUILD_NUMBER)"
xcodegen generate --quiet
xcodebuild -project Osin.xcodeproj -scheme Osin -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" \
  CODE_SIGNING_ALLOWED=NO -quiet build

lipo "$APP/Contents/MacOS/Osin" -verify_arch x86_64
lipo "$APP/Contents/MacOS/Osin" -verify_arch arm64

echo "==> Signing"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  # Sign inside-out with the hardened runtime, as Sparkle's documentation describes.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  for item in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    [[ -e "$item" ]] && codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$item"
  done
  codesign --force --timestamp --options runtime --entitlements Osin/Osin.entitlements --sign "$DEVELOPER_ID" "$APP"
else
  echo "    DEVELOPER_ID not set: ad-hoc signature (users must right-click › Open on first launch)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> Packaging"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Osin $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  echo "==> Generating appcast"
  GENERATE_APPCAST="$(find build/SourcePackages/artifacts -name generate_appcast -type f -perm -u+x | head -1)"
  # generate_appcast rejects two archives of the same version, so give it only the ZIP.
  APPCAST_DIR="$(mktemp -d)"
  cp "$ZIP" "$APPCAST_DIR/"
  "$GENERATE_APPCAST" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --download-url-prefix "https://github.com/Vigentix/osin/releases/download/v$VERSION/" "$APPCAST_DIR"
  cp "$APPCAST_DIR/appcast.xml" "$OUT/appcast.xml"
  rm -rf "$APPCAST_DIR"
fi

echo "==> Done"
ls -lh "$OUT"
echo "DMG sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
