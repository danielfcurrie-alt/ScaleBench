# ScaleBench

ScaleBench is an open iOS Swift app for measuring Bluetooth espresso-scale quality.

It records raw scale packets, parses supported protocols, scores transport and measurement behavior, and exports sessions as JSON for external analysis.

## Current scope

- BLE scan/connect/recording workflow
- Bookoo packet parsing
- WeighMyBru stock packet parsing
- WeighMyBru+ capability and extended packet parsing
- Standard BLE Battery Service support
- Session metrics:
  - effective sample rate
  - packet interval p50/p95/max
  - long gaps
  - missing sequence count
  - rejected packet count
  - idle noise peak-to-peak
  - idle standard deviation
  - drift grams/minute
  - battery update stability
  - firmware-reported scale quality where available
- JSON export of raw packets, parsed samples, capabilities, and metrics

## Scoring

ScaleBench has one default scoring method named **Standard**. It produces a 0-100 overall score from three sub-scores:

- transport: sample cadence, long gaps, missing sequences, timestamp ordering, rejected packets
- stability: idle noise peak-to-peak, idle standard deviation, drift
- metadata: battery coverage, firmware quality coverage, diagnostic/capability coverage

The scoring algorithm is configurable through a `ScoringProfile`. The app currently ships with:

- Standard
- Strict
- Transport Focused

Every exported JSON recording includes the exact scoring profile used, so scores can be reproduced or recomputed later.

## Test modes

The first version supports manual recording modes:

- Idle stability
- Shot / pour
- Tare latency
- Transport stress
- Battery stability

The app does not try to be a brewing app. It is a measurement tool.

## Supported protocols

| Scale family | Status |
| --- | --- |
| Bookoo | Initial packet parser |
| WeighMyBru stock | Initial 20-byte and Float32 parser |
| WeighMyBru+ | Initial capabilities + extended packet parser |
| Eureka/Solo Barista | Planned |
| Acaia | Planned |

## JSON export

Exported recordings include:

- app/schema version
- device identity
- recording mode
- start/end timestamps
- raw packet bytes
- parsed scale samples
- parser rejection reasons
- capability payloads
- computed quality metrics

This is intended to make hardware and firmware comparisons reproducible.

## Development

Open `ScaleBench.xcodeproj` in Xcode 26 or newer.

Build from command line:

```bash
xcodebuild -project ScaleBench.xcodeproj -scheme ScaleBench -destination 'generic/platform=iOS Simulator' build
```

Run tests:

```bash
xcrun simctl list devices available
xcodebuild -project ScaleBench.xcodeproj -scheme ScaleBench -destination 'id=<SIMULATOR-UDID>' CODE_SIGNING_ALLOWED=NO test
```
