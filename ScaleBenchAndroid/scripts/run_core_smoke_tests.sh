#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/core-smoke"

rm -rf "$OUT"
mkdir -p "$OUT/classes"

javac --release 17 \
  -d "$OUT/classes" \
  "$ROOT/app/src/main/java/app/scalebench/android/CoreModels.java" \
  "$ROOT/app/src/main/java/app/scalebench/android/ScaleParsers.java" \
  "$ROOT/app/src/main/java/app/scalebench/android/ScaleQualityAnalyzer.java" \
  "$ROOT/app/src/test/java/app/scalebench/android/CoreSmokeTest.java"

java -cp "$OUT/classes" app.scalebench.android.CoreSmokeTest
