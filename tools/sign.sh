#!/bin/bash
#
# sign.sh — re-sign an unsigned IPA so it can be installed on a personal device,
# using an existing Apple Distribution (Ad Hoc) certificate and provisioning
# profile. This project does not ship or assume any certificate: point the
# environment variables below at your own.
#
# Required:
#   UNTRACKER_SIGN_IDENTITY     codesign identity, e.g. "Apple Distribution: Jane Doe (AB12CD34EF)"
#   UNTRACKER_PROFILE           path to the .mobileprovision (must list your device)
#   UNTRACKER_BASE_ENTITLEMENTS path to an entitlements plist exported from that profile
#   UNTRACKER_APP_GROUP         app group id listed in the profile, e.g. group.example.shared
#   UNTRACKER_KEYCHAIN_GROUP    keychain access group, e.g. AB12CD34EF.untracker
#
# Optional:
#   UNTRACKER_KEYCHAIN               keychain holding the identity (default: login)
#   UNTRACKER_KEYCHAIN_PASSWORD_FILE file containing that keychain's password
#
# Usage:
#   ./tools/sign.sh build/Unsigned.ipa build/Untracker-signed.ipa
#
set -euo pipefail
cd "$(dirname "$0")/.."

IN="${1:-build/Unsigned.ipa}"
OUT="${2:-build/Untracker-signed.ipa}"

require() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo "error: $name is not set" >&2
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 2
    fi
}

require UNTRACKER_SIGN_IDENTITY
require UNTRACKER_PROFILE
require UNTRACKER_BASE_ENTITLEMENTS
require UNTRACKER_APP_GROUP
require UNTRACKER_KEYCHAIN_GROUP

[ -f "$IN" ] || { echo "error: input ipa not found: $IN" >&2; exit 1; }
[ -f "$UNTRACKER_PROFILE" ] || { echo "error: profile not found: $UNTRACKER_PROFILE" >&2; exit 1; }
[ -f "$UNTRACKER_BASE_ENTITLEMENTS" ] || {
    echo "error: base entitlements not found: $UNTRACKER_BASE_ENTITLEMENTS" >&2
    exit 1
}

# Resolve to absolute paths: packaging runs from a staging directory.
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

if [ -n "${UNTRACKER_KEYCHAIN:-}" ]; then
    if [ -n "${UNTRACKER_KEYCHAIN_PASSWORD_FILE:-}" ] && [ -f "${UNTRACKER_KEYCHAIN_PASSWORD_FILE}" ]; then
        echo "== unlocking signing keychain =="
        security unlock-keychain -p "$(cat "$UNTRACKER_KEYCHAIN_PASSWORD_FILE")" "$UNTRACKER_KEYCHAIN"
    fi
fi

WORK=$(mktemp -d /tmp/untracker-sign.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "== building entitlements (profile base + app group + keychain group) =="
# NOTE: never edit these keys with PlistBuddy — it treats dots in the key as a
# path separator and corrupts the array. plistlib handles them literally.
ENTS="$WORK/entitlements.plist"
python3 - "$UNTRACKER_BASE_ENTITLEMENTS" "$ENTS" "$UNTRACKER_APP_GROUP" "$UNTRACKER_KEYCHAIN_GROUP" <<'PY'
import plistlib
import sys

base, out, app_group, keychain_group = sys.argv[1:5]

with open(base, "rb") as handle:
    entitlements = plistlib.load(handle)

entitlements["com.apple.security.application-groups"] = [app_group]

groups = [g for g in entitlements.get("keychain-access-groups", []) if g != keychain_group]
groups.append(keychain_group)
entitlements["keychain-access-groups"] = groups

with open(out, "wb") as handle:
    plistlib.dump(entitlements, handle)

print("   app-group:", app_group)
print("   keychain :", ", ".join(groups))
PY

echo "== unpacking =="
unzip -q "$IN" -d "$WORK/unpacked"
APP=$(find "$WORK/unpacked/Payload" -maxdepth 1 -name '*.app' -type d | head -1)
[ -n "$APP" ] || { echo "error: no Payload/*.app in $IN" >&2; exit 1; }
echo "   app: $(basename "$APP")"
echo "   bundle: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

cp "$UNTRACKER_PROFILE" "$APP/embedded.mobileprovision"

echo "== signing nested code (innermost first) =="
SIGNED=0
while IFS= read -r -d '' item; do
    /usr/bin/codesign --force --sign "$UNTRACKER_SIGN_IDENTITY" --timestamp=none \
        --entitlements "$ENTS" "$item" || { echo "error: failed to sign $item" >&2; exit 1; }
    SIGNED=$((SIGNED + 1))
done < <(/usr/bin/find "$APP" -depth \( -name '*.framework' -o -name '*.appex' -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
echo "   nested signatures: $SIGNED"

echo "== signing main app =="
/usr/bin/codesign --force --sign "$UNTRACKER_SIGN_IDENTITY" --timestamp=none --entitlements "$ENTS" "$APP"

echo "== verifying =="
/usr/bin/codesign --verify --deep --strict "$APP" 2>&1 | tail -2 | sed 's/^/   /'

echo "== packaging =="
rm -f "$OUT"
( cd "$WORK/unpacked" && zip -qry "$OUT" Payload )
du -h "$OUT" | awk '{print "   ipa: " $1}'
echo "OK: $OUT"
