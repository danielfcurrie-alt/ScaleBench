#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SCHEMA_PYTHON="${SCALEBENCH_PYTHON:-python3}"

"$ROOT/gradlew" --no-daemon --console=plain -p "$ROOT" \
  :app:testDebugUnitTest --tests app.scalebench.android.CoreSmokeTest
"$SCHEMA_PYTHON" "$REPO_ROOT/scripts/validate_json_contracts.py" \
  --recording "$REPO_ROOT/build/contract-output/android-recording.json" \
  --analysis "$REPO_ROOT/build/contract-output/android-analysis.json" \
  --chart-analysis "$REPO_ROOT/build/contract-output/android-chart-analysis.json" \
  --scorecard "$REPO_ROOT/build/contract-output/android-scorecard.json"
