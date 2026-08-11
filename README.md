# ScaleBench

<p align="center">
  <img src="ScaleBench/Assets.xcassets/AppIcon.appiconset/AppIcon-180.png" alt="ScaleBench app icon" width="120" height="120">
</p>

ScaleBench is an open iOS and MacOS Bluetooth scale analyzer for coffee-scale transport quality. It records raw BLE packets, parses supported scale protocols into a canonical sample stream, scores transport/stability/metadata quality, and exports a JSON recording for external analysis.

The main goal is protocol and hardware comparison: WMB vs BooKoo standard vs BooKoo native, Bookoo/Eureka/DiFluid/etc. against the same scoring model.

For basic usage, recording modes, scorecards, and packet visualizer help, see [HELP.md](HELP.md).

## Requirements

- iPhone/iPad: iOS/iPadOS 17.0 or newer
- Mac: macOS 14.0 Sonoma or newer through Mac Catalyst
- Bluetooth access is required for live scale recording

## Project intent and provenance

ScaleBench is a diagnostic and benchmarking tool, not a brew logger clone. It is meant to answer concrete hardware/protocol questions:

- how fast a scale actually notifies under real conditions
- how much packet jitter, long-gap behavior, and rejection noise each protocol produces
- whether firmware extensions such as timestamps, sequence numbers, battery, flow, and scale-quality diagnostics improve the data stream
- whether the same physical scale behaves differently through legacy, compatibility, and native/extended transports

Protocol support necessarily includes exact BLE UUIDs, command bytes, packet lengths, checksums, and field offsets. Those values are interoperability facts required to communicate with existing devices. ScaleBench's Bluetooth manager, parser layout, canonical sample model, recording format, scoring model, and scorecard/export behavior are ScaleBench-native Swift implementations.

Where protocol details come from public protocol documentation, upstream firmware behavior, or observed behavior from user-owned test hardware, keep that visible in code comments or README notes. Do not copy application architecture, control flow, comments, or implementation code from other apps.

## Current protocol support

ScaleBench has broad protocol coverage and keeps protocol-specific fields in the exported raw packet stream.

| Family | BLE support | Parsed data |
| --- | --- | --- |
| WeighMyBru | `6E400001...` Float32 and 20-byte/GaggiMate characteristics | weight, packet rejection diagnostics |
| WeighMyBru+ | optional `6E400005...` capabilities plus extended 20-byte packets | weight, timestamp, sequence, flow, battery, status flags, diagnostics, firmware quality |
| BooKoo Standard | `0FFE` / `FF11` / `FF12` | weight, 24-bit ms timestamp, flow, battery |
| BooKoo Mini Native | official OpenSourceBooKoo Mini packet layout | weight, timestamp, flow, battery, standby, buzzer/smoothing bytes in raw export |
| BooKoo Ultra Native | official OpenSourceBooKoo Ultra packet layout | weight, timestamp, flow, battery, smoothing, auto-stop status byte in raw export |
| Acaia | modern `1820/2A80` and legacy `49535343-*` | weight |
| Decent / Espressi | `FFF0` / `FFF4` / `36F5` | weight and v1.2 timer timestamp when present |
| DiFluid Microbalance / Ti | `00EE` or `00DD`, characteristic `AA01` | weight, device timestamp, hardware flow, battery status |
| Eureka Precisa / Solo Barista / LSJ | `FFF0` / `FFF1` / `FFF2` | weight |
| Felicita | `FFE0` / `FFE1` | weight |
| Futula / LFSmart / Lefu | `FFF0` / `FFF4` / `FFF1` | weight |
| Skale2 | `FF08` / `EF81` / `EF80` | weight |
| Timemore Black Mirror Dot | `FFF0` / `FFF1` / `FFF2` | weight, battery, CRC rejection diagnostics |

BooKoo Mini/Ultra details are based on the public OpenSourceBooKoo protocol docs: https://github.com/patrlean/OpenSourceBooKoo

## Recording modes

ScaleBench records the same raw packet stream in every mode; the mode labels what kind of test you are running and affects which metrics are most meaningful.

- **Shot / Pour**: normal public comparison mode. Record one real espresso shot or pour from tare through finish.
- **Idle Stability**: leave the scale untouched for 30–60 seconds. This is the mode where idle noise and drift fields are scored directly.
- **Tare Latency**: record around a tare action. This is for testing how quickly app/scale tare behavior settles.
- **Transport Stress**: intentionally stress Bluetooth by changing distance, moving the phone, or adding interference. Useful for gap/jitter/rejection testing.
- **Battery Logging**: capture battery values over time. This currently logs exposed battery telemetry; it is not yet a calibrated runtime estimator.

## Scoring

The default score is **ScaleBench Standard v1**. Treat that as the public benchmark profile for apples-to-apples tester comparisons.

The app also includes configurable scoring profiles so the same recording can be judged with different weights and thresholds:

- ScaleBench Standard v1
- Strict
- Transport Focused
- locally saved custom profiles

The selected scoring profile is embedded into every exported JSON recording so results can be reproduced. Custom profiles are useful for experimentation, but scores from custom profiles should not be compared directly against Standard v1 claims.

The score explanation screen shows the active profile, benchmark/custom status, transport/stability/metadata weights, and the metrics feeding each subscore.

## Saved recordings and comparison

Recordings can be saved in-app with:

- raw BLE packets
- parsed samples
- score snapshot
- scoring profile
- free-text notes
- device/protocol identity

Saved recordings are stored as JSON under app support storage and are shown in the comparison section. This makes it possible to save one WMB run, one WMB+ run, one BooKoo standard run, and one BooKoo native run, then compare scores, sample rate, p95 interval, max gap, long-gap count, rejection count, and notes.

## Accessibility and system settings

ScaleBench should follow platform defaults wherever possible: semantic SwiftUI fonts, Dynamic Type, system color roles, Dark Mode, high contrast, and user text-size choices. Avoid fixed typography or layout assumptions that make score sharing harder for testers using larger text.

## Export

The JSON export includes:

- app/schema version
- device identity and advertised services
- recording mode
- free-text notes
- WMB+ capability payload when present
- raw BLE packets with characteristic UUID and rejection reason
- parsed canonical samples
- scoring profile
- calculated metrics

The scorecard PNG export always creates a shareable **official ScaleBench Standard v1** image, even when the current recording is being inspected with a custom scoring profile. It includes the official overall score, sub-scores, sample-rate/gap/rejection metrics, protocol identity, recording mode, notes, and the `Standard v1` badge.

## Build

Open `ScaleBench.xcodeproj` in Xcode 26+ or run:

```sh
xcodebuild -project ScaleBench.xcodeproj -scheme ScaleBench -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
