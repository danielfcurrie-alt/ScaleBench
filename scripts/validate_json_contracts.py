#!/usr/bin/env python3
"""Validate every shared fixture against the executable ScaleBench contracts."""

from __future__ import annotations

import copy
import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker
    from referencing import Registry, Resource
except ModuleNotFoundError:
    raise SystemExit(
        "JSON contract validation needs the development dependencies. "
        "Run: python3 -m pip install -r requirements-dev.txt"
    )


ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "shared"
SCHEMA_NAMES = (
    "recording-schema.json",
    "chart-analysis-schema.json",
    "analysis-schema.json",
    "official-scorecard-schema.json",
    "packet-fields-schema.json",
)


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def display_path(error: Any) -> str:
    result = "$"
    for part in error.absolute_path:
        result += f"[{part}]" if isinstance(part, int) else f".{part}"
    return result


def validate_case(
    name: str,
    schema: dict[str, Any],
    instance: Any,
    registry: Registry[Any],
) -> list[str]:
    validator = Draft202012Validator(
        schema,
        registry=registry,
        format_checker=FormatChecker(),
    )
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.absolute_path))
    return [f"{name} {display_path(error)}: {error.message}" for error in errors]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recording", action="append", type=Path, default=[])
    parser.add_argument("--analysis", action="append", type=Path, default=[])
    parser.add_argument("--chart-analysis", action="append", type=Path, default=[])
    parser.add_argument("--scorecard", action="append", type=Path, default=[])
    args = parser.parse_args()
    schemas = {name: load_json(SHARED / name) for name in SCHEMA_NAMES}
    for name, schema in schemas.items():
        try:
            Draft202012Validator.check_schema(schema)
        except Exception as error:
            print(f"{name}: invalid JSON Schema: {error}", file=sys.stderr)
            return 1

    registry = Registry().with_resources(
        (schema["$id"], Resource.from_contents(schema)) for schema in schemas.values()
    )
    fixtures = SHARED / "fixtures"
    official_analysis = load_json(fixtures / "official-analysis.json")
    packet_fields = load_json(fixtures / "packet-fields.json")
    bookoo_packet_fields = load_json(fixtures / "packet-fields-bookoo.json")
    cases = [
        ("iOS recording", schemas["recording-schema.json"], load_json(fixtures / "ios-recording.json")),
        ("Android recording", schemas["recording-schema.json"], load_json(fixtures / "android-recording.json")),
        ("official scorecard", schemas["official-scorecard-schema.json"], load_json(fixtures / "official-scorecard.json")),
        ("official analysis", schemas["analysis-schema.json"], official_analysis),
        ("chart analysis", schemas["chart-analysis-schema.json"], official_analysis["chartAnalysis"]),
        ("packet fields", schemas["packet-fields-schema.json"], packet_fields),
        ("BooKoo packet fields", schemas["packet-fields-schema.json"], bookoo_packet_fields),
    ]
    runtime_cases = (
        ("runtime recording", "recording-schema.json", args.recording),
        ("runtime official analysis", "analysis-schema.json", args.analysis),
        ("runtime chart analysis", "chart-analysis-schema.json", args.chart_analysis),
        ("runtime official scorecard", "official-scorecard-schema.json", args.scorecard),
    )
    for label, schema_name, paths in runtime_cases:
        for path in paths:
            cases.append((f"{label} {path}", schemas[schema_name], load_json(path)))

    failures: list[str] = []
    for name, schema, instance in cases:
        failures.extend(validate_case(name, schema, instance, registry))

    malformed_checks = []
    for name, schema, instance, required_key in (
        ("recording required fields", schemas["recording-schema.json"], cases[0][2], "id"),
        ("scorecard required fields", schemas["official-scorecard-schema.json"], cases[2][2], "score"),
        ("analysis required fields", schemas["analysis-schema.json"], official_analysis, "chartAnalysis"),
        ("chart required fields", schemas["chart-analysis-schema.json"], official_analysis["chartAnalysis"], "packetTimeline"),
        ("packet fields required fields", schemas["packet-fields-schema.json"], packet_fields, "fields"),
    ):
        malformed = copy.deepcopy(instance)
        malformed.pop(required_key)
        malformed_checks.append((name, schema, malformed))

    for name, schema, malformed in malformed_checks:
        if not validate_case(name, schema, malformed, registry):
            failures.append(f"{name}: malformed fixture was incorrectly accepted")

    compact_hex = copy.deepcopy(cases[0][2])
    compact_hex["rawPackets"][0]["bytesHex"] = "030B00"
    if not validate_case("recording spaced hex", schemas["recording-schema.json"], compact_hex, registry):
        failures.append("recording spaced hex: compact runtime hex was incorrectly accepted")

    if failures:
        print("JSON contract validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"JSON contracts passed: {len(SCHEMA_NAMES)} schemas, {len(cases)} validations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
