#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/ScaleBench-Mac-LocalBuild"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-maccatalyst/ScaleBench.app"
DESKTOP_APP="$HOME/Desktop/ScaleBench.app"
LOCAL_CONFIG="$HOME/.config/scalebench/apple-build.env"
[ -f "$LOCAL_CONFIG" ] && source "$LOCAL_CONFIG"

SIGNING_IDENTITY="${SCALEBENCH_CODESIGN_IDENTITY:-Apple Development}"

clear_top_level_xattrs() {
  local path="$1"
  for _ in 1 2 3 4 5; do
    /usr/bin/xattr -c "$path" 2>/dev/null || true
    /usr/bin/xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
    /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$path" 2>/dev/null || true
    if ! /usr/bin/xattr -p com.apple.FinderInfo "$path" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
}

cd "$ROOT"

rm -rf "$APP_PATH"

xcodebuild \
  -project ScaleBench.xcodeproj \
  -scheme ScaleBench \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  build || XCODEBUILD_STATUS=$?

if [ ! -d "$APP_PATH" ]; then
  echo "Mac app was not produced at $APP_PATH" >&2
  exit 1
fi

if [ "${XCODEBUILD_STATUS:-0}" -ne 0 ]; then
  echo "xcodebuild exited nonzero; attempting xattr/sign recovery because the app bundle was produced." >&2
fi

"$ROOT/scripts/sanitize-apple-bundle-xattrs.sh" "$APP_PATH"

if [ -f "$DERIVED_DATA/Build/Intermediates.noindex/ScaleBench.build/Debug-maccatalyst/ScaleBench.build/ScaleBench.app.xcent" ]; then
  for binary in \
    "$APP_PATH/Contents/MacOS/ScaleBench.debug.dylib" \
    "$APP_PATH/Contents/MacOS/__preview.dylib"; do
    if [ -f "$binary" ]; then
      /usr/bin/codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        -o runtime \
        --timestamp=none \
        "$binary"
    fi
	  done
	  "$ROOT/scripts/sanitize-apple-bundle-xattrs.sh" "$APP_PATH"
	  /usr/bin/codesign \
	    --force \
	    --sign "$SIGNING_IDENTITY" \
	    -o runtime \
	    --entitlements "$DERIVED_DATA/Build/Intermediates.noindex/ScaleBench.build/Debug-maccatalyst/ScaleBench.build/ScaleBench.app.xcent" \
	    --timestamp=none \
	    "$APP_PATH"
	  clear_top_level_xattrs "$APP_PATH"
	fi

	/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -rf "$DESKTOP_APP"
/usr/bin/ditto --noextattr --noqtn "$APP_PATH" "$DESKTOP_APP"
"$ROOT/scripts/sanitize-apple-bundle-xattrs.sh" "$DESKTOP_APP"
clear_top_level_xattrs "$DESKTOP_APP"

# Desktop may be backed by FileProvider/iCloud and immediately reattach root-only
# metadata such as com.apple.macl/FinderInfo. The source bundle is strict-verified
# above; the Desktop copy is a convenience install location for local testing.
if ! /usr/bin/codesign --verify --deep --verbose=2 "$DESKTOP_APP"; then
  echo "Warning: Desktop copy verification was blocked by Desktop metadata; source app was verified before copying." >&2
fi

echo "Installed Mac app: $DESKTOP_APP"
