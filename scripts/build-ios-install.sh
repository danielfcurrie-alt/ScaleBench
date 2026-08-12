#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/ScaleBench-Codex"
LOCAL_CONFIG="$HOME/.config/scalebench/apple-build.env"
[ -f "$LOCAL_CONFIG" ] && source "$LOCAL_CONFIG"

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
  echo "No paired iPhone is available. Pass a CoreDevice identifier or set SCALEBENCH_IOS_DEVICE_ID." >&2
  exit 2
fi

SIGNING_IDENTITY="${SCALEBENCH_CODESIGN_IDENTITY:-Apple Development}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/ScaleBench.app"

cd "$ROOT"

rm -rf "$APP_PATH"

xcodebuild \
  -project ScaleBench.xcodeproj \
  -scheme ScaleBench \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  build || XCODEBUILD_STATUS=$?

if [ ! -d "$APP_PATH" ]; then
  echo "iOS app was not produced at $APP_PATH" >&2
  exit 1
fi

if [ "${XCODEBUILD_STATUS:-0}" -ne 0 ]; then
  echo "xcodebuild exited nonzero; attempting xattr/sign recovery because the app bundle was produced." >&2
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
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Installed iOS app on device: $DEVICE_ID"
