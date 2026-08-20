# ScaleBench Scoring Specification

**Public profile:** `ScaleBench Standard v1`
**`scoringModelVersion`: `standard-1.0.0`**
Status: **draft - constants provisional pending calibration (§10)**

This document is normative. Where an implementation and this document disagree, this document is correct and the implementation is a bug. Where this document and `reference/scalebench_scoring.py` disagree, **this document is correct** — the reference exists to make the spec executable and to generate the golden vectors, not to define behaviour.

---

## 1. Design axioms

1. **Captured evidence only.** Every scored quantity derives from a captured weight frame, its transport metadata, and the explicit recording boundaries. BLE cadence uses host callback arrival time. WMB+ USB Serial cadence uses its 32-bit firmware clock and sequence because a serial driver may batch several complete rows into one host read; explicit firmware-reported USB drops are counted as transport loss. Battery, firmware quality, status flags, HX711 cadence, and link setup remain diagnostics rather than independent score terms.
2. **No composite across domains.** Delivery, Idle Stability and Step Response are three separate results. They are never combined.
3. **No component can be bought back.** Delivery is the *product* of coverage and purity, not a weighted sum. Half the slots served with half the frames good is a quarter of the value, not three-quarters.
4. **Every frame receives one integrity class.** Classification order is fixed and a frame is never reclassified. An unusable frame may also leave its delivery slot empty; purity and coverage therefore compound by design.
5. **Below the validity gate there is no score.** Metrics are still shown; the score is `null` (§8).
6. **Where a property could not be verified, say so.** A protocol that cannot expose a defect must not appear to be free of it (§7).

### 1.1 What axiom 1 costs on BLE

For BLE, ScaleBench cannot distinguish "the scale never sent the frame" from "the link dropped it." Sequence numbers can classify order and freshness but do not add a separate missing-frame penalty: doing so would penalise a scale for *reporting* its own losses while a silent scale looks perfect.

WMB+ USB Serial is a narrower case. Its `dropped` counter specifically reports rows skipped by serial backpressure after the app selected that transport. Those rows are direct evidence of loss on the measured path, so each positive `usbDroppedDelta` adds lost frames to the USB purity denominator as defined in §4.4.

*Delivery* is the accurate name for what remains: what reached the phone, fit to use, and on time. Deliberately not why.

---

## 2. Inputs

A recording presented for scoring contains:

| Field | Type | Notes |
|---|---|---|
| `mode` | enum | `shot`, `transportStress`, `idleStability`, `stepResponse`, `tareLatency`, `batteryStability` |
| `recordingStartMonotonicSeconds` | double | Captured when the user starts the recording. Required for an official result. |
| `recordingEndMonotonicSeconds` | double | Captured when recording stops, including a stop caused by disconnect. Required for an official result. |
| `source` | enum | `bluetooth` when absent; `usbSerial` for WMB+ USB Serial. |
| `frames[]` | array | Transport frames in callback/read completion order. |
| `events[]` | array | Connection and app-state events with `type` (`disconnect`, `reconnect`, `appBackgrounded`, or `appForegrounded`) and `monotonicSeconds`. |

Frames outside `[recordingStartMonotonicSeconds, recordingEndMonotonicSeconds)` are excluded. If either boundary is absent, first/last frame times may be used for diagnostics only; validity includes `recordingBoundariesMissing` and no official score is produced.

Frames MUST appear in non-decreasing `monotonicSeconds` order after source-specific timing normalization. A recording with any frame earlier than the preceding bounded frame is invalid with `framesOutOfChronologicalOrder`; diagnostics may still be shown, but no official score is produced. Implementations MUST NOT sort frames before this check because capture order is part of the evidence.

### 2.1 Frames

Scoring operates on **frames**, not parsed samples. The distinction matters: a frame that failed its checksum never becomes a sample, and if the score only ever sees samples it can never charge for it.

| Field | Type | Notes |
|---|---|---|
| `monotonicSeconds` | double | Host monotonic clock. See §2.3. |
| `kind` | enum | `weight`, `status`, `battery`, `capability`, `unhandled`. Default `weight`. |
| `weightGrams` | double | Present unless `parseFailed`. |
| `parseFailed` | bool | Frame failed validation — length, header, checksum, CRC. |
| `sequence` | int? | Protocol sequence byte, when exposed. |
| `deviceTimestampMs` | int? | Device clock, when exposed. |
| `firmwareMillis` | uint32? | WMB+ USB firmware clock. Required on parsed USB weight rows. |
| `sequenceNumber` | uint32? | WMB+ USB sample sequence. Required on parsed USB weight rows. |
| `usbDroppedDelta` | uint32? | Newly skipped serial rows reported by this USB row. |

**Only `kind: "weight"` frames enter either the numerator or the denominator.** Status, battery, capability and unhandled frames are excluded entirely — they are not defects and must not dilute purity. This is also the fix for the old behaviour where an unhandled notification counted as a rejected packet, penalising Acaia for emitting status frames and penalising any scale that exposes a DFU or vendor service.

### 2.2 Protocol capabilities

```json
"protocolCapabilities": {
  "hasChecksum": true,
  "hasSequence": true,
  "sequenceModulus": 256,
  "hasDeviceClock": true,
  "deviceClockSemantics": "freeRunning",
  "deviceClockModulus": 16777216
}
```

Drives §4 and §7. `deviceClockSemantics` is `freeRunning`, `shotTimer`, or `none`. Only a free-running clock may classify freshness. A shot timer such as Decent's is exported but never used for stale detection. If capabilities are omitted, sequence and clock presence may be inferred for diagnostics; `hasChecksum` defaults to false. If a free-running device clock is present but `deviceClockModulus` is absent, stale classification MUST default to `2^24`, matching the device-clock skew diagnostic default.

### 2.3 The host clock

`monotonicSeconds` MUST be sampled **at the moment the BLE stack delivers the notification, on the callback thread, before any dispatch to the UI thread.**

- iOS/macOS: `CACurrentMediaTime()` as the first statement of `peripheral(_:didUpdateValueFor:error:)`, with `CBCentralManager` on a dedicated serial queue — **not** `.main`.
- Android: `SystemClock.elapsedRealtimeNanos()` at the top of the notification callback, with `BleManager(Context, Handler)` bound to a dedicated `HandlerThread` — **not** the single-argument constructor, which dispatches on the main looper.

Wall-clock time (`Date()`, `System.currentTimeMillis()`) MUST NOT be used for any interval or slot computation. It is NTP-adjustable and can step mid-recording.

A recording whose timestamps were taken on the UI thread measures the app's own rendering jitter and is not conformant.

### 2.4 WMB+ USB Serial timing

For `source: "usbSerial"`, every parsed `WMBP_WEIGHT_V1` row preserves both host receive time and the device's unsigned 32-bit `firmwareMillis` and `sequenceNumber`. USB scoring normalises each accepted device timestamp onto the host monotonic axis:

```
usbTime[i] = firstHostReceiveTime + unwrap32(firmwareMillis[i] - firmwareMillis[0]) / 1000
```

`unwrap32` accepts forward movement of at most half the `2^32` modulus and handles wrap. Repeated or backward values remain available for stale/out-of-order classification and never move the accepted high-water mark. Explicit start and stop boundaries remain host monotonic times, so silence before the first row and after the last row remains visible.

The transformed USB time is authoritative for cadence, intervals, slots, and effective rate. Host receive time is retained for serial batching and backpressure diagnostics. `sequenceNumber` uses the same `2^32` forward-delta rule. A positive `usbDroppedDelta` is transport-loss evidence. Recent-bump and recent-glitch status bits are diagnostic evidence only and do not reject an otherwise usable sample.

---

## 3. Pinned arithmetic

Three conventions that silently differ between languages. All three caused, or would have caused, divergence between the two apps.

### 3.1 Percentiles

Linear interpolation between closest ranks (R-7 / `PERCENTILE.INC`).

```
percentile(sorted, p):
    n = len(sorted); if n == 0: return null; if n == 1: return sorted[0]
    h = (n - 1) * p;  lo = floor(h)
    if lo + 1 > n - 1: return sorted[n - 1]
    return sorted[lo] + (h - lo) * (sorted[lo + 1] - sorted[lo])
```

Verify: `percentile([1,2,3,4], 0.25) == 1.75`, `0.50 == 2.5`, `0.75 == 3.25`.

### 3.2 Rounding

Round **half away from zero**.

```
round(x) = x >= 0 ? floor(x + 0.5) : ceil(x - 0.5)
```

Swift's `.rounded()` and Java's `Math.round()` agree for non-negative values. **Python's built-in `round()` does not** — `round(2.5) == 2`, banker's rounding. Applied once, to the final score. Intermediates are never rounded.

### 3.3 Slot indexing

```
SLOT_MS      = 50
SLOT_EPSILON = 1e-9
slotIndex(secondsSinceStart, slotCount) =
    clamp(floor(secondsSinceStart * 1000 / SLOT_MS + SLOT_EPSILON), 0, slotCount - 1)
```

The epsilon is not defensive padding. `0.35 * 1000` evaluates to `349.99999999999994` in IEEE-754 double, so an unguarded `floor` places that frame in slot 6 instead of slot 7 — leaving a genuinely served slot marked empty and costing coverage. The error surfaces at different inputs in Swift and Java, so an implementation that omits the epsilon will diverge on real recordings while passing casual inspection. `shot-clean-20hz` pins this: without the epsilon it scores 99.8, not 100.

---

## 4. Delivery Score

Applies to `shot` and `transportStress`. Range 0–100, or `null` when invalid.

```
DeliveryScore = round( 100 × coverage × purity )
```

### 4.1 Frame classification

Every relevant weight frame receives **exactly one** class, evaluated in this fixed order. First match wins; a frame is never reclassified.

```
parseFailure → outOfOrder → stale → implausible → duplicate → usable
```

| Class | Test |
|---|---|
| `parseFailure` | `parseFailed == true` |
| `outOfOrder` | sequence delta from the accepted high-water value is 0 or exceeds half the declared modulus |
| `stale` | free-running device-clock delta from the accepted high-water value is 0 or exceeds half the declared modulus |
| `implausible` | fails a physics test — §4.2 |
| `duplicate` | weight unchanged within tolerance from the last usable frame **and** a distinct value was achievable — §4.3 |
| `usable` | none of the above |

**`implausible` is evaluated before `duplicate`** because a corrupted value is never a duplicate.

Rejected sequence and clock values never move their high-water marks backwards. For example, timestamps `100, 90, 95` classify both `90` and `95` stale. Wrap is handled with the protocol's declared modulus. A sequence jump larger than half the modulus is ambiguous and classified out of order; this limitation is reported in protocol diagnostics.

**Why `implausible` exists.** The other five classes do not catch the failure that motivated this model: a frame that parses cleanly, carries a fresh sequence number, has an advancing device clock, and reports a physically impossible weight. Under parseFailure/outOfOrder/stale/duplicate alone, an 80 Hz stream with three garbage readings per good one classifies every frame `usable` and scores **100**. `shot-80hz-corrupt-values` exists to pin that.

### 4.2 Mode-aware physics tests

All host-observable and protocol-agnostic — every scale in the matrix can exhibit these and every scale can be measured for them.

Structural checks (`parseFailure`, `outOfOrder`, `stale`) apply in every mode. Weight-physics checks are deliberately mode-aware:

| Mode | Impulse | Rate | Retrograde | Duplicate gate |
|---|---:|---:|---:|---:|
| `shot` | yes | no | no | yes |
| `idleStability` | yes | yes | no | no |
| `transportStress` | no | no | no | no |
| `stepResponse` | no | no | no | no |
| `tareLatency` | no | no | no | no |
| `batteryStability` | no | no | no | no |

This prevents the intended pour, vessel settling, mass step, tare, scale movement, or transport-stress disturbance from being labelled corrupt.

1. **Impulse.** With both adjacent neighbours parseable, `|w[i] − median3(w[i−1], w[i], w[i+1])| > 0.5 g`.
2. **Non-physical idle rate.** In `idleStability` only, `|Δw| / Δt > 25 g/s` against the last usable frame.

For an official Shot / Pour run, tare and settle the vessel before pressing Start, and stop before removing it. Sustained motion inside the shot/pour window is user/test behavior, not packet corruption. Isolated impulses are still classified as implausible.

### 4.3 Duplicates need a resolution gate

A repeated value is a defect only when a distinct one was **achievable**:

```
resolution   = max(0.01, p10(non-zero |Δw| across parseable frames))
sameWeight   = |w[i] − lastUsableWeight| <= max(0.005 g, resolution × 0.25)
achievable   = trailingFlow × (time since last usable frame) >= resolution
```

Without this the formula punishes correct behaviour. A 0.1 g scale at 2 g/s flow reporting at 80 Hz changes by 0.025 g per frame — a quarter of one quantum — so fifteen of every sixteen frames legitimately repeat. Classifying those as impure gives purity 0.06 and a score near 6 for a scale doing nothing wrong. `shot-clean-80hz` pins the excusable case; `shot-avoidable-duplicates` pins the opposite, where the scale demonstrably resolves 0.01 g and still freezes for 200 ms at a time.

Note the honest limit: from the host, "a 1 g-resolution scale" and "a 0.01 g scale that only ever emits 1 g steps" are indistinguishable. The gate therefore excuses the ambiguous case, and the detector is conservative by design.

### 4.4 Coverage and purity

```
coverage      = slots containing at least one USABLE frame / total slots in span
BLE purity    = usable frames / relevant weight frames
USB purity    = usable frames / (relevant weight frames + sum(usbDroppedDelta))
```

Slots are 50 ms, laid from `recordingStartMonotonicSeconds`. `slotCount = floor((recordingEnd − recordingStart) × 1000 / 50 + ε)`. Only complete slots are scored. Recording boundaries, rather than first/last frame times, ensure startup silence, trailing silence, and disconnect outages remain visible.

Coverage answers *how much of the recording had fresh, usable data*; purity answers *how much of what arrived was fit to use*. They are independent: a scale can be punctual and corrupt, or clean and slow.

For USB, firmware-declared dropped rows are denominator-only virtual losses. They do not become synthetic packets, do not alter observed frame-rate counts, and do not receive a frame class. Sequence-gap diagnostics report the greater of inferred sequence loss and summed `usbDroppedDelta`, avoiding double-counting the same loss in that diagnostic. BLE has no equivalent declared-loss term.

**Coverage is linear in rate below the reference.** Clean 20 Hz → 1.0. Clean 10 Hz → 0.5. Clean 5 Hz → 0.25. It saturates by construction — a slot cannot be more than served, so 80 Hz and 20 Hz both reach 1.0 and no scale is rewarded for exceeding the reference rate.

That linearity is the single largest open decision in this spec — see §10.

### 4.5 What Delivery deliberately does not weight

- **Run length.** Coverage counts unserved slots; it does not care whether they were consecutive. One 5 s freeze and 100 scattered misses score identically. This is a real loss — a freeze is worse than scatter — but weighting runs would charge the same unserved slots twice and would amplify score variance, which is the thing §10 criterion 2 exists to protect. `longestUnservedRunMs` is reported instead. Flagged for calibration.
- **Sub-slot jitter.** If every 50 ms window carries fresh usable data, where inside the window it landed is not something the user experiences. `robustCoefficientOfVariation` is reported as a diagnostic.

### 4.6 The reconstruction limit

Above ~30% impulse corruption a 3-point median filter can no longer separate signal from noise — the good frames disagree with their neighbours as much as the bad ones do, and everything classifies `implausible`. `signalUnreconstructable` is set when the implausible fraction exceeds 0.30.

This is an epistemic limit, not a detector bug, but it is diagnostic only. Delivery still comes from `coverage × purity`, so a stream with visible corruption is penalized by purity rather than forced to zero.

Contrast the two vectors deliberately:

| Vector | Loss | Detectable per frame? | Score |
|---|---|---|---|
| `shot-80hz-quarter-parseable` | 3 in 4 fail checksum | yes — parse failure | **25** |
| `shot-80hz-corrupt-values` | 3 in 4 carry garbage that parses | no — past the limit | **0** |

Same nominal loss rate, different answers, both right.

### 4.7 Reference distribution

| Vector | Coverage | Purity | **Delivery** |
|---|---|---|---|
| `shot-clean-20hz` | 1.000 | 1.000 | **100** |
| `shot-clean-80hz` | 1.000 | 1.000 | **100** |
| `shot-unverifiable-protocol` | 1.000 | 1.000 | **100** (upper bound — §7) |
| `shot-out-of-order-sequence` | 0.975 | 0.975 | **95** |
| `shot-single-stall` | 0.952 | 1.000 | **95** |
| `shot-stale-device-clock` | 0.968333 | 0.968333 | **94** |
| `shot-80hz-corrupt-sparse` | 1.000 | 0.900 | **90** |
| `shot-avoidable-duplicates` | 0.940 | 0.929 | **87** |
| `shot-clean-10hz` | 0.500 | 1.000 | **50** |
| `shot-clean-5hz` | 0.250 | 1.000 | **25** |
| `shot-80hz-quarter-parseable` | 1.000 | 0.250 | **25** |
| `shot-half-coverage-half-purity` | 0.500 | 0.500 | **25** |
| `shot-clean-2hz` | 0.100 | 1.000 | **10** |
| `shot-80hz-corrupt-values` | 0.003 | 0.001 | **0** |

---

## 5. Idle Stability Score

Applies to `idleStability`. Computed from **usable frames only**.

1. Discard the first 5.0 s (settling).
2. OLS fit `w(t) = a + b·t`. `driftGramsPerMinute = b × 60`.
3. `residual[i] = w[i] − (a + b·t[i])`.
4. `residualStandardDeviation` = sample SD (denominator `n−1`) of the residuals.
5. `residualPeakToPeak` = `p99.5(residual) − p0.5(residual)` — diagnostic.
6. `resolutionGrams` = smallest non-zero `|Δw|` — diagnostic; exposes quantisation and over-smoothing.

```
noiseScore = 100 × clamp01( (0.20 − residualSD)   / (0.20 − 0.02) )     weight 0.50
driftScore = 100 × clamp01( (1.00 − |drift|)      / (1.00 − 0.05) )     weight 0.50

idleStabilityScore = round( exp( 0.5·ln(floored(noiseScore)) + 0.5·ln(floored(driftScore)) ) )
where floored(v) = 5 + 0.95·v
```

**Noise is measured on detrended residuals.** Computing it on the raw series lets drift inflate both terms, charging one physical defect twice. OLS across every sample also replaces the old two-point endpoint estimate, which was maximally sensitive to noise on exactly the two least reliable samples. `idle-drift-and-noise` pins this: its `noiseScore` must be independent of the superimposed drift.

The SD is deliberately **not** robust here: at rest, an occasional 0.5 g jump is a genuine defect and should count. An external disturbance therefore degrades the result sharply; `residualPeakToPeak` is reported so the tester can see what happened and decide whether to rerun the test.

---

## 6. Step Response

Applies to `stepResponse`. **Metrics only — not scored.**

Nothing in Delivery measures *delay*. A perfectly punctual, perfectly pure 20 Hz stream that is 400 ms behind physical reality scores 100. For stopping a shot at a target weight, lag is arguably the most user-relevant property of a scale.

Procedure: settle the empty scale, start recording, wait ≥ 2 s, place a mass of ≥ 5 g in one motion, wait for it to settle, stop.

```
baseline  = median of usable frames in the first 2.0 s
final     = median of usable frames in the last  2.0 s
amplitude = final − baseline                          // require >= 5 g, else stepDetected = false

onset = first frame with w >= baseline + 0.05 × amplitude
t10   = first frame with w >= baseline + 0.10 × amplitude
t90   = first frame with w >= baseline + 0.90 × amplitude

riseTime10To90   = t90 − t10
settlingTime     = (first t >= onset where |w − final| <= 0.1 g and remains observed
                    inside that band for 1.0 s, with no sample gap > 0.25 s) − onset
overshootPercent = max(0, (max w after onset − final) / amplitude × 100)
```

Onset is emitted as seconds relative to the authoritative recording start. A settling candidate is accepted only after a sample at or beyond the full one-second hold; reaching the end of the recording early never counts as settled.

**Can measure:** relative comparison between scales. `step-fast` and `step-sluggish` have identical coverage, purity and every delivery diagnostic, and differ only here — 0.2 s vs 2.0 s rise, 0.6 s vs 4.7 s settling. That is the property Delivery structurally cannot see.

**Cannot measure:** absolute end-to-end latency, which needs an external trigger with a known time origin. `onset` is the first *reported* departure from baseline, so any delay before the scale reports anything is invisible.

Scoring is deferred until there is real-hardware data to place the thresholds (§10).

---

## 7. Protocol Verification — and why it must be on screen

Purity is measured with different instruments on different protocols.

| Class | Requires |
|---|---|
| `parseFailure` | a checksum or CRC in the frame format |
| `outOfOrder` | sequence numbers |
| `stale` | a device clock |
| `duplicate` | Shot / Pour mode (the check is disabled elsewhere) |
| `implausible` | Shot / Pour or Idle Stability mode (the check is disabled elsewhere) |

Futula and Skale2 validate only length, so they can never register a parse failure. Only WeighMyBru+ exposes sequence numbers, so only WeighMyBru+ can register out-of-order.

Verification is the intersection of what the protocol exposes and what the selected mode actually checks. A class disabled by the mode MUST be listed as unverifiable even when the protocol provides every field needed to run it. For example, Transport Stress deliberately disables duplicate and implausible-weight checks, so a full-detail protocol reports `3 of 5 available` (60%), not 100%.

**When every class is not verified, purity is an upper bound rather than a fully observed measurement.** Moving the unverifiable classes out of the score does not make the asymmetry disappear; it relocates it. So it must be reported:

```json
"protocolVerification": {
  "verifiableClasses":   ["duplicate", "implausible", "stale"],
  "unverifiableClasses": ["outOfOrder", "parseFailure"],
  "verificationCoveragePercent": 60,
  "purityIsUpperBound":  true
}
```

This percentage is observability coverage, not a statistical confidence level and not a probability that the score is correct.

**Requirement:** available checks MUST render adjacent to the Delivery Score on the scorecard, comparison table, and every leaderboard row, for example `2 of 5 available`. When `purityIsUpperBound` is true, render the result as an upper bound, for example `≤100`, and do not rank it as equivalent to a fully verified 100. `shot-unverifiable-protocol` pins protocol-limited verification; `stress-mode-disabled-checks` pins mode-limited verification.

---

## 8. Validity gates

| Mode | Min span | Min usable frames | Additional gate | Disconnect | App backgrounded |
|---|---:|---:|---|---|---|
| `shot` | 20 s | 2 | authoritative boundaries | invalidates | invalidates |
| `transportStress` | 120 s | 2 | authoritative boundaries | recorded, does **not** invalidate | invalidates |
| `idleStability` | 60 s | 100 after the 5 s settling discard | authoritative boundaries | invalidates | invalidates |
| `stepResponse` | 10 s | 30 | at least 5 usable baseline and 5 usable final-window frames | invalidates | invalidates |
| `tareLatency` | 5 s | 10 | metrics only | invalidates | invalidates |
| `batteryStability` | 60 s | 0 | telemetry only | invalidates | invalidates |

Below gate: report every metric, set the score to `null`, populate `validity.reasons`, refuse to render an official scorecard.

Reason codes: `recordingBoundariesMissing`, `framesOutOfChronologicalOrder`, `durationBelowMinimum`, `usableFrameCountBelowMinimum`, `idleAnalysedFrameCountBelowMinimum`, `stepBaselineFrameCountBelowMinimum`, `stepFinalFrameCountBelowMinimum`, `disconnectDuringRecording`, `appLeftForeground`, `unknownMode`.

**Why a disconnect gates rather than scores.** In a 20 s foreground recording at arm's length the base rate of disconnects is near zero, so a disconnect component would read 100 for almost every recording — carrying no information and compressing the range, which is the defect being removed from the old metadata and dynamic-stability terms. Link reliability is real but it is a **fleet statistic**: report `disconnectsPerConnectedHour` accumulated across all recordings for a scale model, never folded into a score. `transportStress` is exempt because provoking disconnects is the point of the mode.

**Why leaving the foreground always gates.** Mobile operating systems may suspend, defer, or coalesce Bluetooth callbacks when an app is backgrounded. ScaleBench keeps the screen awake while recording, records any app background/foreground transition, and withholds an official result if the app leaves the foreground. This keeps iOS and Android captures under an explicit, auditable condition instead of relying on different background-execution policies.

---

## 9. Diagnostics — reported, never scored

`relevantWeightFrames`, `excludedFrames`, `usableSampleCount`, `spanSeconds`, `frameRateHz`, `usableRateHz`, `estimatedResolutionGrams`, `slotCount`, `servedSlots`, `longestUnservedRunMs`, `intervalP50Ms`, `robustCoefficientOfVariation`, `intervalMaxMs`, `disconnectCount`, `signalUnreconstructable`, full `frameClassification` counts.

`frameRateHz` is relevant weight frames divided by the explicit recording boundary span. `usableRateHz` is usable frames divided by the first-to-last usable-frame span, so setup/stop dead time does not make a clean stream look slower in diagnostics.

Plus, from the protocol layer: sequence-derived loss, device-vs-host clock skew in ppm, coalescing factor, battery, firmware flags and self-reported quality, negotiated MTU, requested connection priority, USB host receive timing, HX711 cadence, and USB backpressure drops.

### 9.1 Shared signal-diagnostic contract

Reported-flow validation, device-clock skew, packet coalescing, and stream-quality diagnostics are normative diagnostics but are never score inputs. They MUST NOT change validity, Delivery, Idle Stability, or Step Response results. They are calculated only for a completed recording with an explicit `recordingEndMonotonicSeconds`; otherwise these diagnostics are unavailable.

The input sample stream is parser-accepted weight samples, including samples later classified as duplicate, stale, out of order, or implausible by the scorer. Discard samples with non-finite monotonic time or weight. Sort by monotonic time while preserving input order for ties; flow validation keeps only the first sample at a repeated time. Golden-vector decimal outputs are rounded to six places and platform conformance uses an absolute tolerance of `1e-6`.

### 9.2 Reported-flow validation

This diagnostic compares a scale's reported flow with flow derived from its weight stream:

1. Require at least five strictly increasing samples spanning at least one second and at least five finite reported-flow values.
2. At each sample time `t`, linearly interpolate weight at `t - 0.5 s` and `t + 0.5 s`. When both exist, derived flow is `(weight(t + 0.5) - weight(t - 0.5)) / 1.0 s`.
3. Search lag candidates from `-1.00 s` through `+1.00 s` in `0.05 s` increments. For each lag `L`, pair reported flow at `t` with linearly interpolated derived flow at `t - L`. Require at least eight pairs and calculate Pearson correlation.
4. Select the highest correlation. Correlations within `1e-6` tie; choose the smaller absolute lag, retaining the earlier negative candidate if absolute lags also tie.
5. If no correlation exists or the best correlation is below `0.25`, report lag and correlation as unavailable and calculate errors at zero lag. Otherwise a positive lag means reported flow trails weight-derived flow.
6. For every aligned pair, calculate absolute error in grams per second. Require at least five errors. Report their conventional median, averaging the two middle values for an even count, plus the contributing sample count, selected lag in milliseconds, and correlation.

### 9.3 Device-clock skew

Clock skew is available only for BooKoo, BooKoo Mini, BooKoo Ultra, and WeighMyBru+ samples carrying a device timestamp. A protocol clock declared as `shotTimer` is never eligible. Sort samples by host monotonic time. Use the protocol's device-clock modulus, defaulting to `2^24`; when the raw clock decreases by more than half the modulus, unwrap it by adding one modulus. Ignore smaller backward movements and non-increasing unwrapped timestamps.

Require at least ten accepted timestamp pairs spanning at least five host seconds. Regress unwrapped device milliseconds on host monotonic milliseconds using ordinary least squares. Report `skewPartsPerMillion = (slope - 1) * 1,000,000` and the accepted pair count.

### 9.4 Packet coalescing

Packet coalescing is available only when Delivery applies and both coverage and frame rate exist with coverage greater than zero. Use the scorer's published six-decimal `coverage` and `frameRateHz` values. Define `servedSlotRateHz = coverage * 20` and `framesPerServedSlot = frameRateHz / servedSlotRateHz`. Report frame rate, served-slot rate, and the ratio. A ratio above `1` means multiple weight frames arrived per occupied 50 ms slot; it does not by itself distinguish true higher-rate delivery from callback batching.

### 9.5 Stream-quality diagnostics

Stream-quality diagnostics explain the presentation stream a user saw during a recording. They are not truth or calibration measurements: without a second reference scale, ScaleBench can only say whether the captured stream is internally plausible. Therefore `truthUnavailable` is always `true`.

Use the same bounded scorer frames and frame classes used for Delivery. `implausibleCount` is the count of frames classified as implausible. For each implausible frame with weight, find the nearest usable weighted frame before it and the nearest usable weighted frame after it. If both exist, linearly interpolate the expected weight between those two usable frames at the implausible frame's timestamp and calculate `implausibleErrorGrams = abs(weight - expectedWeight)`. If only one usable neighbor exists, calculate the error against that neighbor. If no usable neighbor exists, the local error is `null`. Report mean, population standard deviation, p95, and max of measurable errors. `implausibleRatePerSecond = implausibleCount / recordingSpanSeconds`. `longestImplausibleRunMilliseconds` is the longest contiguous implausible run from first to last frame timestamp in that run.

For Shot / Pour only, report active-pour backward motion from parseable weight frames sorted by time. The active-pour window starts at the frame immediately before the first frame whose weight has risen by at least `max(1.0 g, resolutionGrams * 10)` above the running minimum. It ends at the highest-weight frame after that start. Ignore backward steps within the duplicate tolerance. Report `activePourNegativeStepCount`, `activePourNegativeStepTotalGrams`, and `activePourAbsStepP95Grams`; for other modes these fields are `null`.

Duplicate-run diagnostics use frames classified as duplicate. `duplicateRunMaxMilliseconds` is the longest duplicate run from the timestamp immediately before the run to the last duplicate frame. `freezeThenReleaseMaxGrams` is the largest absolute difference between the held pre-run weight and the first parseable non-duplicate frame after a duplicate run, or `null` if no release can be measured.

`effectiveOutputRateHz` is parseable weight frames divided by the first-to-last parseable-frame span. It is a signal-output rate, not proof of physical sensor accuracy. Golden-vector decimal outputs are rounded to six places and checked by platform conformance with `1e-6` tolerance.

---

## 10. Calibration — before any constant is frozen

Every threshold in §4 and §5 is **provisional**, chosen to give a usable spread on synthetic signals, not derived from hardware. Freezing requires a corpus of real recordings and three acceptance criteria:

1. **Spread.** The score distribution across the real device population must use most of 0–100 with no ceiling pile-up. The failure being corrected is a model where everything scores 95–100.
2. **Test–retest reliability.** Same scale, same conditions, ≥ 5 repeats. Between-scale variance must dominate within-scale variance — compute an intraclass correlation. If repeat variance is comparable to between-scale variance the benchmark cannot rank anything, however principled each term is. **Most often skipped; decides whether the benchmark means anything.**
3. **Independence.** Correlate coverage against purity across the corpus. Strong correlation means they are one measurement wearing two hats and the product is charging it twice.

### 10.1 The open decision: is clean 10 Hz worth 50?

Linear coverage makes the score proportional to rate below 20 Hz. If most of the supported matrix sits at 5–10 Hz, the population lands at 25–50 with a gap up to ~100 for 20 Hz hardware — so the headline number mostly reports a hardware design choice, and genuine delivery-quality differences *within* the 10 Hz cluster compress into a narrow band. That is criterion 1 failing in a specific, testable way.

The alternative is a log curve on `occupancy × 20` (10 Hz → 77), which spreads the cluster better but is less honest about "you received half the available data."

Decide empirically: run the corpus both ways and check which separates devices **inside** the dominant rate cluster. Do not decide it from first principles — both are defensible.

### 10.2 Other open questions

- Is 20 Hz the right reference? It must be reachable on the target phones under §11.1, or coverage measures the handset. Check the achieved coverage ceiling on the slowest supported Android device.
- Is 20 Hz the right reference for USB? WMB+ USB Serial can carry an 80 SPS HX711 stream on a device clock that does not expose Bluetooth callback jitter, so USB captures may pile up near 100 and stop separating high-rate devices. Before any public USB leaderboard, run the real USB corpus against transport-specific reference rates and check criterion 1 for ceiling pile-up.
- Should run length re-enter the score (§4.5), given the variance cost?
- Is the 0.30 reconstruction threshold right, and should `signalUnreconstructable` invalidate rather than score 0?
- Are the impulse (0.5 g) and rate (25 g/s) thresholds right for pour-over as well as espresso?
- Are Step Response metrics stable enough across repeats to be scored?

### 10.3 Optional - score uncertainty intervals

Recommended, not required. A score without an uncertainty is easy to over-read; "82 ± 1" and "82 ± 9" support very different claims.

If implemented, resampling MUST be deterministic and identical across platforms: a fixed-seed xorshift64\* specified inline, **not** the platform RNG. 1000 resamples of the frame sequence, percentile method, seed `0x2545F4914F6CDD1D`. If the 95% interval spans more than ±2 points, say so on the scorecard.

---

## 11. Provenance — required in every export

`schemaVersion` describes the file container. It MUST NOT signal a change in the scoring maths — a consumer needs to distinguish "the layout changed" from "the numbers mean something different now."

| Field | Notes |
|---|---|
| `scoringModelVersion` | `standard-1.0.0`. Bumped on **every** formula or constant change. |
| `schemaVersion` | Container layout only. |
| `platform` | `ios` \| `macos-catalyst` \| `android` |
| `appVersion`, `appBuild` | Read from the build system. **Never hardcoded** — the two apps previously carried three different hardcoded strings, none matching the build. |
| `recordingStartMonotonicSeconds`, `recordingEndMonotonicSeconds` | Authoritative §2 boundaries. |
| `events` | Timestamped disconnect/reconnect and app background/foreground evidence. |
| `link.requestedConnectionPriority`, `link.requestedMtu`, `link.negotiatedMtu` | Android link setup; `null` on Apple platforms. |
| `protocolCapabilities` | Drives §7 |
| `metrics.validity` | `{ isValid, reasons[] }` |

WMB+ USB Serial exports additionally include `source: "usbSerial"`, `protocol: "WMB+ USB Serial"`, `serialBaud: 115200`, and per-row `firmwareMillis`, `sequenceNumber`, `usbStatusRaw`, `usbStatusLabels`, `firmwareQuality`, `hx711Hz`, `usbDroppedCumulative`, `usbDroppedDelta`, and `hostReceivedAt`. These fields are optional for older and Bluetooth recordings, preserving container compatibility.

Recommended calibration context, not required by scoring model `standard-1.0.0`: OS version, device model/manufacturer, low-power state, thermal/standby state, and an RSSI series. Adding these fields changes the container schema, not the scoring model, until a future normative formula consumes them.

### 11.1 Cross-platform comparability

Android can call `requestConnectionPriority` and `requestMtu`. iOS can do neither — `CoreBluetooth` negotiates connection parameters per Apple's accessory guidelines with no app control.

**iOS and Android Delivery Scores are therefore not directly comparable, independent of everything else in this spec.** Neither platform is wrong; they are different measurement conditions. With a 20 Hz reference this stops being a footnote: at Android's default BALANCED connection interval (~30 ms) a scale cannot reliably serve 50 ms slots, so coverage would measure the handset.

Transport is also part of the measurement condition. BLE Delivery cadence uses host callback arrival time, while WMB+ USB Serial cadence uses firmware time and sequence normalised onto the host axis because USB serial drivers can batch complete rows. **BLE and USB Delivery Scores are therefore not directly comparable.** A USB score can answer "did this cabled stream deliver the firmware samples without declared drops"; a BLE score can answer "did this wireless link deliver usable packets to the app on time."

Requirements:

1. Android MUST fix one standard for official scorecards — `CONNECTION_PRIORITY_HIGH` and `requestMtu(247)` — and record both the request and the negotiated result.
2. Every scorecard MUST display the platform and transport source.
3. Leaderboards MUST segment by platform and transport, or label every entry with both before sorting.
4. Protocol-comparison views MUST group by transport before ranking scores. Cross-transport comparison is diagnostic only.
5. Official captures MUST remain in the foreground. Apps MUST keep the screen awake during recording, export app-state transitions, and invalidate a result containing `appBackgrounded`.

---

## 12. Conformance

An implementation is conformant when it reproduces every vector listed in `vectors/index.json`:

- integer scores and frame-class counts: exact equality
- floating-point diagnostics: absolute tolerance `1e-6`
- `null` vs present: exact
- `validity.reasons` and `protocolVerification.*Classes`: same set, order-insensitive

`index.json` is generated and is the **authoritative** list. Directories present in `vectors/` but absent from `index.json` are residue from an earlier `scoringModelVersion` and must be ignored by the runner. See `vectors/README.md`.
