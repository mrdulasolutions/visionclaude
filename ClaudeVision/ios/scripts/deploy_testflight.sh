#!/usr/bin/env bash
#
# Build, archive, and upload ClaudeVision to TestFlight.
#
# Prerequisites (one-time setup):
#   1. Paid Apple Developer Program membership.
#   2. An app record for the bundle ID (com.claudevision.app) in App Store Connect.
#   3. An App Store Connect API key (App Store Connect > Users and Access >
#      Integrations > App Store Connect API > Team Keys) with "App Manager" role.
#      Download the .p8 file — it can only be downloaded once.
#
# Required environment variables:
#   TEAM_ID        Apple Developer Team ID (e.g. AB12CD34EF)
#   ASC_KEY_ID     App Store Connect API key ID (e.g. 2X9R4HXF34)
#   ASC_ISSUER_ID  App Store Connect API issuer ID (UUID)
#   ASC_KEY_PATH   Path to the AuthKey_<KEY_ID>.p8 file
#
# Optional:
#   BUILD_NUMBER   Overrides the auto-generated build number (default: UTC timestamp)
#   DEVELOPER_DIR  Path to Xcode (auto-detected if unset)
#
# Usage:
#   TEAM_ID=AB12CD34EF ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/keys/AuthKey.p8 \
#     ./scripts/deploy_testflight.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$IOS_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeVision.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

SCHEME="ClaudeVision"
PROJECT="$IOS_DIR/ClaudeVision.xcodeproj"

# --- Validate inputs -------------------------------------------------------

fail() { echo "error: $1" >&2; exit 1; }

[[ -n "${TEAM_ID:-}" ]]       || fail "TEAM_ID is not set (Apple Developer Team ID)"
[[ -n "${ASC_KEY_ID:-}" ]]    || fail "ASC_KEY_ID is not set (App Store Connect API key ID)"
[[ -n "${ASC_ISSUER_ID:-}" ]] || fail "ASC_ISSUER_ID is not set (App Store Connect issuer ID)"
[[ -n "${ASC_KEY_PATH:-}" ]]  || fail "ASC_KEY_PATH is not set (path to .p8 API key)"
[[ -f "$ASC_KEY_PATH" ]]      || fail "ASC_KEY_PATH does not exist: $ASC_KEY_PATH"

# --- Locate Xcode ----------------------------------------------------------

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if xcodebuild -version >/dev/null 2>&1; then
        : # xcode-select already points at a full Xcode
    elif [[ -d "/Applications/Xcode.app" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif [[ -d "$HOME/Downloads/Xcode-beta.app" ]]; then
        export DEVELOPER_DIR="$HOME/Downloads/Xcode-beta.app/Contents/Developer"
    else
        fail "no usable Xcode found; set DEVELOPER_DIR or run: sudo xcode-select -s /path/to/Xcode.app"
    fi
fi

echo "==> Using $(xcodebuild -version | head -1) (${DEVELOPER_DIR:-xcode-select default})"

# --- Build number ----------------------------------------------------------

# TestFlight requires each upload to have a unique, increasing build number.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
echo "==> Build number: $BUILD_NUMBER"

# --- Archive ---------------------------------------------------------------

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $SCHEME (Release)..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# --- Export & upload -------------------------------------------------------

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> Uploading to App Store Connect (TestFlight)..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Upload complete."
echo "    The build will appear in App Store Connect > TestFlight after Apple"
echo "    finishes processing (typically 5-30 minutes). First-time uploads may"
echo "    need export compliance answered before testers can install it."
