#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -x "./gradlew" ]]; then
  ./gradlew assembleDebug
elif command -v gradle >/dev/null 2>&1; then
  gradle assembleDebug
else
  echo "Gradle is required for the Jetpack Compose app build. Open this folder in Android Studio or install Gradle." >&2
  exit 1
fi

echo "$ROOT/app/build/outputs/apk/debug/app-debug.apk"
