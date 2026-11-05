#!/bin/bash
#
# device.sh — install / launch / pull diagnostics / uninstall on a paired iPhone.
#
# Required:
#   UNTRACKER_UDID        device UDID, see `xcrun devicectl list devices`
#
# Optional:
#   UNTRACKER_APP_GROUP   app group container to pull, e.g. group.example.shared
#   UNTRACKER_BUNDLE_ID   defaults to moe.mgt.untracker
#
# Usage:
#   ./tools/device.sh install build/Untracker-signed.ipa
#   ./tools/device.sh launch
#   ./tools/device.sh pull [output-dir]
#   ./tools/device.sh uninstall
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${UNTRACKER_BUNDLE_ID:-moe.mgt.untracker}"
COMMAND="${1:-help}"
ARGUMENT="${2:-}"

if [ -z "${UNTRACKER_UDID:-}" ] && [ "$COMMAND" != "help" ]; then
    echo "error: UNTRACKER_UDID is not set (see 'xcrun devicectl list devices')" >&2
    exit 2
fi
UDID="${UNTRACKER_UDID:-}"

case "$COMMAND" in
install)
    IPA="${ARGUMENT:-build/Untracker-signed.ipa}"
    [ -f "$IPA" ] || { echo "error: ipa not found: $IPA" >&2; exit 1; }
    WORK=$(mktemp -d /tmp/untracker-install.XXXXXX)
    trap 'rm -rf "$WORK"' EXIT
    unzip -q "$IPA" -d "$WORK/unpacked"
    APP=$(find "$WORK/unpacked/Payload" -maxdepth 1 -name '*.app' -type d | head -1)
    xcrun devicectl device install app --device "$UDID" "$APP"
    ;;

launch)
    xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" || \
        xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID"
    ;;

selftest)
    # Runs the bundled 78-case suite on device and pulls the JSON report.
    xcrun devicectl device process launch --device "$UDID" --terminate-existing \
        "$BUNDLE_ID" -- --run-selftest
    sleep 10
    "$0" pull
    ;;

uninstall)
    xcrun devicectl device uninstall app --device "$UDID" "$BUNDLE_ID"
    ;;

pull)
    OUT="${ARGUMENT:-build/device-pull}"
    mkdir -p "$OUT/app" "$OUT/group"
    xcrun devicectl device copy from --device "$UDID" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source Documents --destination "$OUT/app" || true
    if [ -n "${UNTRACKER_APP_GROUP:-}" ]; then
        xcrun devicectl device copy from --device "$UDID" \
            --domain-type appGroupDataContainer --domain-identifier "$UNTRACKER_APP_GROUP" \
            --source . --destination "$OUT/group" || true
    fi
    echo "pulled into $OUT"
    find "$OUT" -type f | head -20
    ;;

*)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
