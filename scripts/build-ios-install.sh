#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/ScaleBench-iOS-LocalBuild"
LOCAL_CONFIG="$HOME/.config/scalebench/apple-build.env"
[ -f "$LOCAL_CONFIG" ] && source "$LOCAL_CONFIG"

SIGNING_IDENTITY="${SCALEBENCH_CODESIGN_IDENTITY:-Apple Development}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/ScaleBench.app"

cd "$ROOT"

xcodebuild \
  -project ScaleBench.xcodeproj \
  -scheme ScaleBench \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [ ! -d "$APP_PATH" ]; then
  echo "iOS app was not produced at $APP_PATH" >&2
  exit 1
fi

"$ROOT/scripts/sanitize-apple-bundle-xattrs.sh" "$APP_PATH"

if [ -f "$DERIVED_DATA/Build/Intermediates.noindex/ScaleBench.build/Debug-iphoneos/ScaleBench.build/ScaleBench.app.xcent" ]; then
  for binary in \
    "$APP_PATH/ScaleBench.debug.dylib" \
    "$APP_PATH/__preview.dylib"; do
    if [ -f "$binary" ]; then
      /usr/bin/codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        --timestamp=none \
        --generate-entitlement-der \
        "$binary"
    fi
  done

  "$ROOT/scripts/sanitize-apple-bundle-xattrs.sh" "$APP_PATH"

  /usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$DERIVED_DATA/Build/Intermediates.noindex/ScaleBench.build/Debug-iphoneos/ScaleBench.build/ScaleBench.app.xcent" \
    --timestamp=none \
    --generate-entitlement-der \
    "$APP_PATH"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

DEVICE_ID="${1:-${SCALEBENCH_IOS_DEVICE_ID:-}}"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(xcrun devicectl list devices | awk '
    /available \(paired\).*iPhone/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F]+$/) {
          print $i
          exit
        }
      }
    }
  ')"
fi
if [ -z "$DEVICE_ID" ]; then
  echo "Built iOS app at $APP_PATH, but no paired iPhone is available to install." >&2
  echo "Unlock/connect the iPhone and rerun this script; the built app bundle is preserved." >&2
  exit 2
fi

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Installed iOS app on device: $DEVICE_ID"
