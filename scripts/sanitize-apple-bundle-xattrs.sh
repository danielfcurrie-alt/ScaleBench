#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/App.app" >&2
  exit 64
fi

APP_PATH="$1"

if [ ! -d "$APP_PATH" ]; then
  echo "sanitize: bundle not found: $APP_PATH" >&2
  exit 66
fi

/usr/bin/xattr -cr "$APP_PATH" 2>/dev/null || true
/usr/bin/xattr -c "$APP_PATH" 2>/dev/null || true
/usr/bin/xattr -crs "$APP_PATH" 2>/dev/null || true
/usr/bin/xattr -cs "$APP_PATH" 2>/dev/null || true

remove_attr() {
  attr="$1"
  /usr/bin/xattr -d "$attr" "$APP_PATH" 2>/dev/null || true
  /usr/bin/find "$APP_PATH" -depth -exec /usr/bin/xattr -d "$attr" {} \; 2>/dev/null || true
}

remove_attr com.apple.FinderInfo
remove_attr com.apple.ResourceFork
remove_attr com.apple.macl
remove_attr com.apple.provenance
remove_attr 'com.apple.fileprovider.fpfs#P'

/usr/bin/xattr -c "$APP_PATH" 2>/dev/null || true

/usr/sbin/dot_clean -m "$APP_PATH" 2>/dev/null || true

remove_attr com.apple.FinderInfo
remove_attr com.apple.ResourceFork
remove_attr com.apple.macl
remove_attr com.apple.provenance
remove_attr 'com.apple.fileprovider.fpfs#P'
