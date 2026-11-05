#!/bin/bash
#
# sim.sh — build for the iOS Simulator, install and screenshot (fast UI iteration).
#
#   ./tools/sim.sh              # build + install + launch + screenshot
#   ./tools/sim.sh screenshot   # screenshot only
#
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
ROOT=$(pwd)
BUILD_DIR="$ROOT/build"
SIM_NAME="${UNTRAKER_SIM:-iPhone 18 Pro}"
BUNDLE_ID="moe.mgt.untracker"

case "${1:-build}" in
screenshot)
    mkdir -p "$BUILD_DIR/screenshots"
    OUT="$BUILD_DIR/screenshots/$(date +%H%M%S).png"
    xcrun simctl io booted screenshot "$OUT"
    echo "✓ $OUT"
    exit 0
    ;;
esac

xcodegen generate --quiet

echo "== booting simulator =="
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
open -a Simulator || true
sleep 3

echo "== building for simulator =="
set -o pipefail
xcodebuild \
    -project Untracker.xcodeproj \
    -scheme Untracker \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="-" \
    build 2>&1 | tee "$BUILD_DIR/build-sim.log" | tail -25

APP="$BUILD_DIR/DerivedData/Build/Products/Debug-iphonesimulator/Untracker.app"
[ -d "$APP" ] || { echo "✗ no simulator app at $APP" >&2; exit 1; }

echo "== installing =="
xcrun simctl install booted "$APP"
xcrun simctl launch booted "$BUNDLE_ID" || true
sleep 2

mkdir -p "$BUILD_DIR/screenshots"
OUT="$BUILD_DIR/screenshots/$(date +%H%M%S).png"
xcrun simctl io booted screenshot "$OUT"
echo "✓ $OUT"
