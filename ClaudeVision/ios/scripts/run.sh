#!/usr/bin/env bash
#
# Build and run ClaudeVision.
#
# By default builds for the iOS Simulator, boots one, installs the app, and
# launches it. Note the Ray-Ban glasses features (Meta Wearables SDK, camera)
# require a physical iPhone — use --device for those.
#
# Usage:
#   ./scripts/run.sh                     # run in a simulator (default: iPhone 17 Pro)
#   ./scripts/run.sh --sim "iPhone Air"  # run in a specific simulator
#   ./scripts/run.sh --device            # run on a connected iPhone (needs TEAM_ID)
#   ./scripts/run.sh --build-only        # just build, don't install/launch
#
# Optional environment variables:
#   TEAM_ID        Apple Developer Team ID (required for --device)
#   DEVELOPER_DIR  Path to Xcode (auto-detected if unset)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$IOS_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"

SCHEME="ClaudeVision"
PROJECT="$IOS_DIR/ClaudeVision.xcodeproj"
BUNDLE_ID="com.claudevision.app"

SIMULATOR_NAME="iPhone 17 Pro"
TARGET="simulator"
BUILD_ONLY=0

fail() { echo "error: $1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sim)        SIMULATOR_NAME="${2:?--sim requires a simulator name}"; shift 2 ;;
        --device)     TARGET="device"; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        -h|--help)    sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            fail "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Locate Xcode ----------------------------------------------------------

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if xcodebuild -version >/dev/null 2>&1; then
        : # xcode-select already points at a full Xcode
    elif [[ -d "/Applications/Xcode.app" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        fail "no usable Xcode found; set DEVELOPER_DIR or run: sudo xcode-select -s /path/to/Xcode.app"
    fi
fi

echo "==> Using $(xcodebuild -version | head -1)"

# --- Regenerate the Xcode project from project.yml -------------------------

if command -v xcodegen >/dev/null 2>&1; then
    echo "==> Regenerating Xcode project (xcodegen)..."
    (cd "$IOS_DIR" && xcodegen generate --quiet)
else
    echo "==> xcodegen not installed, using existing $PROJECT"
fi

# --- Build & run -----------------------------------------------------------

APP_PATH_FOR() { echo "$DERIVED_DATA/Build/Products/Debug-$1/ClaudeVision.app"; }

if [[ "$TARGET" == "simulator" ]]; then
    UDID="$(xcrun simctl list devices available | grep -F "$SIMULATOR_NAME (" | head -1 \
        | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    [[ -n "$UDID" ]] || fail "no available simulator named '$SIMULATOR_NAME' (see: xcrun simctl list devices available)"

    echo "==> Building $SCHEME for $SIMULATOR_NAME..."
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "id=$UDID" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO

    [[ "$BUILD_ONLY" == 1 ]] && { echo "==> Build complete: $(APP_PATH_FOR iphonesimulator)"; exit 0; }

    echo "==> Booting $SIMULATOR_NAME..."
    xcrun simctl bootstatus "$UDID" -b >/dev/null

    # Xcode <=26 ships Simulator.app; Xcode 27 replaced it with DeviceHub.app
    # (and moved it from Contents/Developer/Applications to Contents/Applications).
    XCODE_CONTENTS="$(dirname "$(xcode-select -p)")"
    for SIM_APP in \
        "$(xcode-select -p)/Applications/Simulator.app" \
        "$XCODE_CONTENTS/Applications/DeviceHub.app"; do
        if [[ -d "$SIM_APP" ]]; then open "$SIM_APP"; break; fi
    done

    echo "==> Installing and launching $BUNDLE_ID..."
    xcrun simctl install "$UDID" "$(APP_PATH_FOR iphonesimulator)"
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID"
    echo "==> Running. Logs: xcrun simctl spawn $UDID log stream --predicate 'subsystem CONTAINS \"claudevision\"'"
else
    [[ -n "${TEAM_ID:-}" ]] || fail "TEAM_ID is required for --device (your Apple Developer Team ID)"

    DEVICE_ID="$(xcrun devicectl list devices --hide-headers 2>/dev/null \
        | awk '/available \(paired\)|connected/ {print $NF; exit}')"
    [[ -n "$DEVICE_ID" ]] || fail "no connected iPhone found (see: xcrun devicectl list devices)"

    echo "==> Building $SCHEME for device $DEVICE_ID..."
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic

    [[ "$BUILD_ONLY" == 1 ]] && { echo "==> Build complete: $(APP_PATH_FOR iphoneos)"; exit 0; }

    echo "==> Installing and launching on device..."
    xcrun devicectl device install app --device "$DEVICE_ID" "$(APP_PATH_FOR iphoneos)"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
    echo "==> Running on device."
fi
