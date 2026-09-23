#!/bin/bash
#
# MakeiOSDeploy.sh — build the tech-pomodoro iOS app (Release) and install it on a paired iPhone.
#
#   ./MakeiOSDeploy.sh                  build, then install on the one reachable paired iPhone and launch it
#   ./MakeiOSDeploy.sh --device <UDID>  install on that device (needed when more than one iPhone is paired)
#   ./MakeiOSDeploy.sh --no-build       skip the build and install the last one (e.g. after an install timeout)
#
# Development install straight from Xcode's toolchain: no App Store Connect record, no TestFlight. A
# paid-team development profile lasts a year. Build and install are separate steps, so a phone that is
# locked or unplugged costs only a re-run with --no-build, never a rebuild.
#
# Per-project settings are the block below; the rest is generic. Called by /dev-deploy for Apps projects.
set -euo pipefail
cd "$(dirname "$0")"

# --- project settings --------------------------------------------------------------------------------
PROJECT_FILE="TechPomodoro.xcodeproj"
SCHEME="TechPomodoroiOS"
PRODUCT="TechPomodoro.app"
BUNDLE_ID="com.jsglazer.tech-pomodoro.ios"
TEAM="PWGXN26URQ"
DERIVED=".build/xcode-device"
# ------------------------------------------------------------------------------------------------------

DEVICE=""
BUILD=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="${2:?--device needs a UDID}"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

APP="$DERIVED/Build/Products/Release-iphoneos/$PRODUCT"
LOG="$DERIVED/ios-build.log"

# Paired physical iPhones that are reachable right now (wired or over the local network), one
# "UDID<TAB>name" per line.
reachable_iphones() {
    local json
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
    python3 - "$json" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if (hw.get("reality") == "physical" and hw.get("deviceType") == "iPhone"
            and conn.get("pairingState") == "paired" and conn.get("transportType")):
        print(f'{hw.get("udid")}\t{d.get("deviceProperties", {}).get("name", "?")}')
EOF
    rm -f "$json"
}

# --- build --------------------------------------------------------------------------------------------
if [[ $BUILD -eq 1 ]]; then
    # project.yml is the source of truth; regenerate so the build can never use a stale .xcodeproj.
    if [[ -f project.yml ]]; then
        echo "==> xcodegen generate"
        xcodegen generate >/dev/null
    fi
    VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
    echo "==> building $SCHEME $VERSION (Release, team $TEAM)"
    mkdir -p "$DERIVED"
    if ! xcodebuild -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
            -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build >"$LOG" 2>&1; then
        grep -E "error:" "$LOG" | sort -u | head -20 >&2 || true
        echo "BUILD FAILED — full log: $LOG" >&2
        exit 1
    fi
    echo "    built $APP"
fi
[[ -d "$APP" ]] || { echo "no build at $APP — run without --no-build first" >&2; exit 1; }

# --- pick the device ----------------------------------------------------------------------------------
if [[ -z "$DEVICE" ]]; then
    echo "==> looking for a paired iPhone (connect and unlock it)"
    for _ in $(seq 1 12); do
        FOUND="$(reachable_iphones)"
        [[ -n "$FOUND" ]] && break
        sleep 5
    done
    if [[ -z "$FOUND" ]]; then
        echo "No reachable paired iPhone after ~1 minute. The build succeeded; connect and unlock the phone, then re-run: $0 --no-build" >&2
        exit 2
    fi
    if [[ "$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')" -gt 1 ]]; then
        echo "More than one iPhone is paired; choose one with --device <UDID>:" >&2
        printf '    %s\n' "$FOUND" | tr '\t' ' ' >&2
        exit 3
    fi
    DEVICE="$(cut -f1 <<<"$FOUND")"
    echo "    using $(cut -f2 <<<"$FOUND") ($DEVICE)"
fi

# --- install and launch -------------------------------------------------------------------------------
echo "==> installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
echo "==> launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null
echo "Done: $PRODUCT installed and launched on $DEVICE"
