# Golden vectors

Conformance fixtures for `SCORING-SPEC.md`, currently `standard-1.0.0`.

**`index.json` is the authoritative list.** The runner MUST iterate `index.json` rather than the directory listing: a model change renames and removes vectors, and a directory-driven runner will silently keep testing orphans from an earlier `scoringModelVersion`. It should also assert `index.json`'s `scoringModelVersion` against the implementation's own, so a stale checkout fails loudly instead of passing against the wrong model.

The current vector count and model version live in `index.json`.

**No expected value here was written by hand.** Every one was computed by `../reference/scalebench_scoring.py`, a direct transcription of the spec. Regenerate with:

```sh
cd ../reference && python3 generate_vectors.py
```

Deterministic — the synthetic signals use fixed irrational-frequency sine sums, never a PRNG — so a clean checkout reproduces byte-identical files. A diff without a spec change is a bug.

## Input format

Frame-level, not sample-level. A frame that fails its checksum never becomes a sample, so a scorer that only sees samples can never charge for it.

```json
{
  "vectorId": "shot-clean-20hz",
  "mode": "shot",
  "deviceKind": "weighMyBruPlus",
  "frames": [
    { "monotonicSeconds": 0.0, "kind": "weight", "weightGrams": 0.0,
      "parseFailed": false, "sequence": 12, "deviceTimestampMs": 1234,
      "flowGramsPerSecond": 1.8 }
  ],
  "events": [ { "type": "disconnect", "monotonicSeconds": 18.4 } ],
  "protocolCapabilities": {
    "hasChecksum": true,
    "hasSequence": false,
    "hasDeviceClock": true,
    "deviceClockSemantics": "freeRunning"
  }
}
```

Only `kind: "weight"` frames enter the purity numerator or denominator.

## Comparison rules

| Field kind | Rule |
|---|---|
| Integer scores, frame-class counts | exact |
| Floating-point diagnostics | absolute tolerance `1e-6` |
| `null` vs present | exact |
| `validity.reasons`, `protocolVerification.*Classes` | same set, order-insensitive |

## What each vector pins

### The anchors

| Vector | Coverage × purity | Score | Pins |
|---|---|---|---|
| `shot-clean-20hz` | 1.000 × 1.000 | **100** | Reference rate. Also the slot-epsilon fix — without it this scores 99.8. |
| `shot-clean-80hz` | 1.000 × 1.000 | **100** | Coverage saturates; repeats excused by the resolution gate. |
| `shot-clean-10hz` | 0.502 × 1.000 | **50** | Linear coverage — the §10.1 decision. |
| `shot-clean-5hz` | 0.251 × 1.000 | **25** | |
| `shot-clean-2hz` | 0.101 × 1.000 | **10** | |
| `shot-80hz-quarter-parseable` | 1.000 × 0.250 | **25** | Purity independent of coverage: each slot still gets one good frame. |
| `shot-half-coverage-half-purity` | 0.502 × 0.501 | **25** | Multiplicative structure — neither factor buys back the other. |

### Corrupt-value reconstruction

| Vector | Score | Pins |
|---|---|---|
| `shot-80hz-corrupt-values` | **0** | 3 of 4 frames carry garbage that parses cleanly, is in sequence, and is not stale. Under parseFailure/outOfOrder/stale/duplicate alone every frame is `usable` and this scores **100**. The `implausible` class closes it. Result is 0 rather than 25 because 75% corruption is past the reconstruction limit — `signalUnreconstructable` is set. Correct: if the host cannot identify the good frames, nothing downstream can. |
| `shot-80hz-corrupt-sparse` | **90** | The realistic regime — 10% isolated impulses, where a 3-point median filter still works. |

### Resolution gate, both directions

| Vector | Score | Pins |
|---|---|---|
| `shot-clean-80hz` | **100** | 0.1 g scale at 2 g/s: 15 of 16 frames legitimately repeat. Must be excused, or a correct scale scores ~6. |
| `shot-avoidable-duplicates` | **87** | Scale demonstrably resolves 0.01 g and still freezes 200 ms at a time. Must be charged. |

### Protocol asymmetry

| Vector | Score / verification | Pins |
|---|---|---|
| `shot-unverifiable-protocol` | **100** / 40% | No checksum, no sequence, no clock. Scores 100, but purity was only measurable on two of five classes. A verified 100 and this are not the same number. |
| `shot-out-of-order-sequence` | **95** / 60% | `outOfOrder` only classifiable because sequence numbers exist. |
| `shot-stale-device-clock` | **94** / 60% | `stale` only classifiable because a device clock exists. |
| `stress-mode-disabled-checks` | **100** / 60% | Full protocol detail, but Transport Stress intentionally disables duplicate and implausible-weight checks. Mode-disabled checks cannot masquerade as verified. |

### Structure and validity

`shot-excluded-frames-ignored` (status/battery/unhandled must not dilute purity — must equal `shot-clean-20hz`) · `shot-single-stall` (coverage carries it; `longestUnservedRunMs` reports the run the score deliberately does not weight) · `shot-insufficient-duration` · `shot-two-frames` · `shot-disconnect-invalidates` · `stress-disconnect-allowed` · `stress-background-invalidates` (backgrounding invalidates even the mode that allows disconnects).

### Signal diagnostics

`shot-signal-diagnostics` is the shared numerical oracle for the three non-scoring diagnostics. Its reported flow trails the centered one-second weight derivative by 200 ms, its integer device clock runs approximately 112.5 ppm fast after timestamp quantization, and its clean 20 Hz stream produces exactly one frame per occupied slot. Every other vector also carries explicit expected `null` or packet-coalescing values, so eligibility behavior cannot drift silently.

### Idle and Step

`idle-clean` · `idle-drift-only` (OLS slope, not a two-point estimate) · `idle-noisy` · `idle-drift-and-noise` (**detrending** — compare `noiseScore` against `idle-noisy`; drift must not inflate it) · `idle-too-short`.

`step-fast` / `step-sluggish` have identical coverage, purity and every delivery diagnostic, and differ only in the step metrics — 0.2 s vs 2.0 s rise, 0.6 s vs 4.7 s settling. That is the property Delivery structurally cannot see. `step-overshoot` exercises the ringing path.

## Wiring — Swift (XCTest)

Add `scoring/vectors` as a folder reference so the JSON is copied verbatim.

```swift
func testGoldenVectors() throws {
    let root = Bundle(for: type(of: self)).url(forResource: "vectors", withExtension: nil)!
    let index = try JSONDecoder().decode(VectorIndex.self,
                    from: Data(contentsOf: root.appendingPathComponent("index.json")))
    XCTAssertEqual(index.scoringModelVersion, ScaleQualityAnalyzer.scoringModelVersion)
    for entry in index.vectors {                       // index.json, not directory listing
        let dir = root.appendingPathComponent(entry.vectorId)
        let input = try JSONDecoder().decode(ScoringInput.self,
                        from: Data(contentsOf: dir.appendingPathComponent("input.json")))
        let expected = try JSONDecoder().decode(ScoringResult.self,
                        from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
        assertScoringResultsEqual(ScaleQualityAnalyzer.analyze(input), expected, vector: entry.vectorId)
    }
}
```

## Wiring — Android (JUnit)

Symlink or copy `scoring/vectors` to `app/src/test/resources/vectors` and iterate `index.json` the same way. `scripts/run_core_smoke_tests.sh` is dependency-free and is the right hook.

## Not covered here

**Parser conformance.** These vectors begin at classified frames and test nothing about byte decoding. Parser fixtures need *real captured hex* per protocol — the current unit tests on both platforms build their fixtures from the same assumptions the parser uses, so they prove internal consistency, not protocol correctness. Add under `../parser-vectors/` once captured.

**Incremental scoring.** If either app computes metrics during recording, the incremental path must equal a batch pass over the finished recording. Assert separately by feeding each vector one frame at a time.
