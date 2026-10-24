#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/swift-scoring-conformance"
SCHEMA_PYTHON="${SCALEBENCH_PYTHON:-python3}"

"$SCHEMA_PYTHON" "$ROOT/scripts/validate_json_contracts.py"

mkdir -p "$OUT"

xcrun swiftc \
  -module-cache-path "$OUT/module-cache" \
  "$ROOT/ScaleBench/Models/ScaleProtocolModels.swift" \
  "$ROOT/ScaleBench/Protocols/WeighMyBruParser.swift" \
  "$ROOT/ScaleBench/Protocols/BookooParser.swift" \
  "$ROOT/ScaleBench/Protocols/PacketFieldDecoder.swift" \
  "$ROOT/ScaleBench/Analysis/ScaleQualityAnalyzer.swift" \
  "$ROOT/ScaleBench/Models/ChartAnalysis.swift" \
  "$ROOT/scripts/swift-scoring-conformance/main.swift" \
  -o "$OUT/runner"

"$OUT/runner" "$ROOT/scoring/vectors"
