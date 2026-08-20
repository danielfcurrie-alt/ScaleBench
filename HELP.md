# ScaleBench Help

## Quick start

1. Power on the scale, tap **Scan**, and connect it.
2. Choose the mode before starting. Use **Shot / Pour** for normal public comparisons.
3. Follow the procedure for that mode.
4. Tap **Start Recording**. Keep ScaleBench in the foreground; it keeps the screen awake while recording.
5. Tap **Stop and View Results**. ScaleBench saves the recording automatically; export JSON only when you want a file copy.

## Wired WMB+ on Mac and Android

Connect a WMB+ with a USB data cable, choose the USB serial source under **Wired USB**, then use **Start USB Recording**. ScaleBench configures 115200 baud, disables battery benchmark output, and starts the continuous weight stream.

USB recordings use firmware time and sequence for cadence while preserving host receive time for transport diagnostics. Results show both device cadence and received sample rate. Firmware-reported dropped rows count as USB backpressure loss; bump and glitch flags are shown without automatically discarding the sample.

USB serial recording is currently available on Mac and Android. iPhone/iPad support requires external accessory/USB host support. Bluetooth recording remains available on every supported platform.

## Official test procedures

| Mode | Minimum | Procedure | Result |
| --- | ---: | --- | --- |
| Shot / Pour | 20 s | Tare and settle before Start; stop before removing the vessel | Delivery |
| Transport Stress | 120 s | Deliberately stress the BLE link with range, motion, or interference | Delivery |
| Idle Stability | 60 s | Leave the scale untouched on a stable surface; first 5 s are settling | Idle Stability |
| Step Response | 10 s | Start empty, wait at least 2 s, add at least 5 g once, hold through the final window | Metrics only |
| Tare Latency | 5 s | Record around one tare action | Metrics only |
| Battery Logging | 60 s | Capture exposed battery telemetry | Telemetry only |

If a validity gate fails, ScaleBench keeps the diagnostics and shows the reason, but does not issue an official score.

All official tests must stay in the foreground. If the app is backgrounded or you switch apps during a recording, the JSON keeps that event and the recording remains available for diagnosis, but it cannot receive an official result.

## Delivery score

Shot / Pour and Transport Stress use:

```text
Delivery = round(100 x coverage x purity)
```

**Coverage** is the share of complete 50 ms recording slots that received at least one usable weight frame. Clean 20 Hz reaches 100%; faster streams saturate instead of earning bonus points. Clean 10 Hz scores 50% coverage, 5 Hz scores 25%, and 2 Hz scores 10%.

**Purity** is usable weight frames divided by all relevant weight frames. Status, battery, capability, and other non-weight frames are excluded. Bad weight frames are classified once, in this order:

```text
parse failure -> out of order -> stale -> implausible -> duplicate -> usable
```

The score multiplies coverage and purity, so missing time and bad frames compound. Half coverage with half purity is 25, not 50.

## What causes deductions

- Missing or late usable frames leave 50 ms slots empty and reduce coverage.
- Checksum, CRC, length, header, or unit failures reduce purity when the protocol exposes them.
- Sequence numbers can expose out-of-order frames; free-running device clocks can expose stale frames.
- Isolated implausible weight spikes reduce purity in Shot / Pour and Idle Stability. Sustained Shot / Pour motion is not treated as packet corruption.
- Avoidable duplicate weight values reduce purity in Shot / Pour only when a distinct value should have been achievable.
- A disconnect invalidates normal modes; Transport Stress records disconnects without invalidating because provoking link trouble is the point.
- Leaving ScaleBench during a recording invalidates every official mode because iOS and Android schedule background Bluetooth differently.

Available checks depend on both the scale protocol and the selected mode. Transport Stress deliberately disables weight-physics and duplicate checks, so even a full-detail protocol reports `3 of 5 available`. When every defect class is not checked, Delivery is shown as a best-case score such as `<=100`.

## Other results

Idle Stability scores detrended residual noise and drift after discarding the first 5 seconds. Noise and drift are combined geometrically so one bad term cannot be hidden by one good term.

Step Response reports onset, rise time, settling time, and overshoot. It is not a 0-100 score because real hardware data is still needed before thresholds are credible.

Tare Latency and Battery Logging are metrics-only modes.

## Saved recordings

Saved recordings are recalculated from stored raw packets and samples whenever they are loaded or exported, using the current ScaleBench Standard v1 analyzer. Open a saved recording to inspect charts, packet cadence, classifications, notes, validity reasons, and raw packet preview.

Compare only recordings made with the same mode, platform, and transport. USB and Bluetooth scores are different test conditions: USB uses the scale's firmware time and sequence, while Bluetooth uses when packets arrive at the app. Keep the `scoringModelVersion`, platform, transport, and available packet checks with any published result.

## Device Utility

Device Utility, or DU, is separate from scoring. Use it to inspect connected-device update capability and export a device report.

Android can start classic Nordic nRF5 Secure/Legacy DFU from a firmware ZIP package when the connected device exposes a compatible DFU bootloader. SMP/McuManager update support is detected but not active yet. Device Utility is not exposed in the iOS/iPadOS app.

Mac DU also scans for cabled USB serial devices. When it sees a likely `/dev/cu.*` or `/dev/tty.*` port, it can run ESP32 backup and app-binary flash through local `esptool`/`esptool.py`/`python -m esptool`. Backup reads 4 MB from address `0x00000`; flash defaults to app offset `0x10000` and requires a successful backup first. Full images still need the exact bootloader, partition, and app offsets.

Android DU can detect attached USB devices and records them in the device report. Actual cabled ESP32 backup/flash on Android needs a native Espressif `esp-serial-flasher` bridge, so the app blocks those buttons with a clear status until that backend is added.

Full firmware image backup is usually not possible over BLE. Cabled backup is possible only for devices whose bootloader/debug path permits readback. ScaleBench backup means exporting device metadata, advertised services, app/build identity, cable/tool detection, and latest telemetry unless the firmware or ESP32 serial bootloader allows readback.

## Visualizer

Use the visualizer to understand why a recording scored well or poorly.

- **Weight stream** shows parsed sample weight over time.
- **Packet cadence** shows arrival intervals and gap behavior.
- **Scorecard** shows coverage, purity, protocol detail, validity, and frame-class counts.
- **Packet inspector** lists packets by time and event. Tap one to see selectable raw hex; matching colors connect byte ranges to parser-decoded fields.
- **Signal diagnostics** compare a scale's reported flow with weight change measured across a centered 1-second window, estimate drift for genuine free-running BooKoo and WMB+ clocks, show how many weight frames occupy each 50 ms scoring slot, and summarize impossible readings, backward pour steps, frozen readings, and freeze-then-release jumps.

Signal diagnostics, color, and emphasis do not add or remove score points. They describe stream quality, not physical truth or calibration accuracy. Decent's shot timer is intentionally not treated as a free-running device clock. The official numbers always come from Standard v1.

## Exports

JSON is the complete evidence record: raw packets, parsed samples, recording boundaries, app-state events, link setup, protocol capabilities, validity, score details, and diagnostics. Scorecard images are available only for valid scored modes and always use ScaleBench Standard v1.

## Source & legal

ScaleBench is open source. The repository includes the app code, shared schemas, test fixtures, scoring documentation, privacy policy, and MIT license:

- GitHub repository: https://github.com/danielfcurrie-alt/ScaleBench
- Privacy policy: https://github.com/danielfcurrie-alt/ScaleBench/blob/main/PRIVACY.md
- MIT license: https://github.com/danielfcurrie-alt/ScaleBench/blob/main/LICENSE

## Troubleshooting

If the score is lower than expected, open the recording and check validity reasons, coverage, purity, max gap, p95 interval, frame classifications, and packet checks. Backgrounding the app invalidates an official result; low-power mode, distance, interference, and unstable Bluetooth conditions can affect the captured data.

If battery or flow is missing, the connected protocol probably did not expose it. ScaleBench records only what the scale sends.

Saved recordings are local to the device until exported as JSON.
