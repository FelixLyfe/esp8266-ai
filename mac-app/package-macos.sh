#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="AIClockBridge"

if [[ -n "${1:-}" ]]; then
  VERSION="$1"
else
  VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
fi

FILE_VERSION="${VERSION//\//-}"
MARKETING_VERSION="${VERSION#v}"
MARKETING_VERSION="${MARKETING_VERSION%%-*}"
if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  MARKETING_VERSION="0.0.0"
fi
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf '1')"

# Keep SwiftPM's module caches writable in restricted build environments. The
# installed Command Line Tools on macOS 14 may also default to a newer SDK than
# this Swift compiler can import, so prefer the matching 14.5 SDK when present.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/aiclock-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${TMPDIR:-/tmp}/aiclock-swiftpm-cache}"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk
fi
SWIFT_BUILD_ARGS=(--package-path "$SCRIPT_DIR" --disable-sandbox -c release)

echo "Building $APP_NAME $VERSION..."
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"

APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$FILE_VERSION-macOS.dmg"
CONTENTS="$APP_PATH/Contents"

rm -rf "$APP_PATH" "$DMG_PATH"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$BIN_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
install -m 644 "$SCRIPT_DIR/Packaging/Info.plist" "$CONTENTS/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"

# AppResources prefers the standard signed-app location and falls back to
# Bundle.module when running directly through SwiftPM.
RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$CONTENTS/Resources/$(basename "$RESOURCE_BUNDLE")"

# Render the repository's vector logo directly at every standard macOS icon
# size. The same SVG is also the menu-bar icon source.
ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aiclock-icon.XXXXXX")"
DMG_TMP=""
cleanup() {
  rm -rf "$ICON_TMP"
  if [[ -n "$DMG_TMP" ]]; then rm -rf "$DMG_TMP"; fi
}
trap cleanup EXIT
ICONSET="$ICON_TMP/$APP_NAME.iconset"
mkdir -p "$ICONSET"
SOURCE_ICON="$ROOT_DIR/docs/images/logo.svg"
for size in 16 32 128 256 512; do
  "$BIN_DIR/$APP_NAME" --render-icon "$SOURCE_ICON" "$ICONSET/icon_${size}x${size}.png" "$size"
  retina=$((size * 2))
  "$BIN_DIR/$APP_NAME" --render-icon "$SOURCE_ICON" "$ICONSET/icon_${size}x${size}@2x.png" "$retina"
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/$APP_NAME.icns"

codesign --force --deep --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

DMG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aiclock-dmg.XXXXXX")"
ditto "$APP_PATH" "$DMG_TMP/$APP_NAME.app"
ln -s /Applications "$DMG_TMP/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo
echo "Created:"
echo "  $APP_PATH"
echo "  $DMG_PATH"
