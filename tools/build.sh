#!/bin/bash
#
# build.sh — generate the Xcode project and build an UNSIGNED device IPA.
#
#   ./tools/build.sh            # Release, device (iphoneos)
#   ./tools/build.sh debug      # Debug build (still unsigned)
#
# Output: build/Unsigned.ipa  (contains the app and its Share Extension)
#
set -euo pipefail
cd "$(dirname "$0")/.."
# Non-interactive ssh shells do not source the login profile; Homebrew's xcodegen
# lives in /opt/homebrew/bin.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
ROOT=$(pwd)
CONFIGURATION="${1:-Release}"
if [ "$CONFIGURATION" = "debug" ]; then CONFIGURATION="Debug"; fi

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }

echo "== xcodegen =="
xcodegen generate --quiet

echo "== xcodebuild ($CONFIGURATION, iphoneos, unsigned) =="
set -o pipefail
xcodebuild \
    -project Untracker.xcodeproj \
    -scheme Untracker \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    build 2>&1 | tee "$BUILD_DIR/build.log" | tail -40

APP="$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION-iphoneos/Untracker.app"
if [ ! -d "$APP" ]; then
    echo "✗ build produced no app at $APP" >&2
    exit 1
fi

if [ ! -d "$APP/PlugIns/UntrackerShare.appex" ]; then
    echo "✗ Share Extension missing from the app bundle" >&2
    exit 1
fi

echo "== packaging =="
rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/Unsigned.ipa"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
( cd "$BUILD_DIR" && zip -qry Unsigned.ipa Payload )
du -h "$BUILD_DIR/Unsigned.ipa" | awk '{print "   ipa: " $1}'
echo "✓ $BUILD_DIR/Unsigned.ipa"
