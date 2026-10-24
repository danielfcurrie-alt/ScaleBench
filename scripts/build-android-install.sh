#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/ScaleBenchAndroid/app/build/outputs/apk/debug/app-debug.apk"

cd "$ROOT/ScaleBenchAndroid"
if ! ./gradlew --no-daemon --console=plain :app:assembleDebug; then
  echo "Android build failed; cleaning generated build artifacts and retrying once." >&2
  ./gradlew --no-daemon --console=plain clean :app:assembleDebug
fi

if [ ! -f "$APK" ]; then
  echo "Android APK was not produced at $APK" >&2
  exit 1
fi

adb devices -l
if ! adb get-state >/dev/null 2>&1; then
  echo "No Android device is visible to adb. Unlock the Pixel, enable USB debugging, and accept the authorization prompt." >&2
  exit 2
fi

adb install -r "$APK"
echo "Installed Android app: $APK"
