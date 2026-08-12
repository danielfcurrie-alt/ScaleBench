"""Generates golden vectors under ../vectors/ for ScaleBench Standard v1.

Every expected.json is COMPUTED by scalebench_scoring.py, never hand-written.
Signals are synthesised deterministically -- no PRNG -- so a clean checkout
reproduces byte-identical files.
"""

import json, math, os
import scalebench_scoring as sb

HERE = os.path.dirname(os.path.abspath(__file__))
VECTORS = os.path.abspath(os.path.join(HERE, "..", "vectors"))


def det_noise(i, amp, phase=0.0):
    return amp * (0.6 * math.sin(i * 1.7320508075688772 + phase)
                  + 0.3 * math.sin(i * 2.6457513110645907 + 1.1 + phase)
                  + 0.1 * math.sin(i * 3.3166247903554 + 2.3 + phase))


def q(value, resolution):
    """Quantise to the scale's reported resolution."""
    return round(round(value / resolution) * resolution, 6)


def pour(t, flow=2.0, start=2.0, cap=36.0):
    return 0.0 if t < start else min(cap, (t - start) * flow)


def frame(t, w, **kw):
    f = {"monotonicSeconds": round(t, 6), "kind": "weight", "weightGrams": round(w, 6)}
    f.update(kw)
    return f


def stream(hz, seconds, weight_fn, resolution=0.1, **kw):
    step = 1.0 / hz
    n = int(round(seconds * hz))
    return [frame(i * step, q(weight_fn(i * step), resolution), **kw) for i in range(n + 1)]


def build():
    V = []

    V.append(("shot-clean-20hz",
              "Metronomic 20 Hz, every frame usable. The reference rate: coverage 1.0, purity 1.0.",
              {"mode": "shot", "frames": stream(20, 30, pour), "events": []}))

    diagnostics = []
    for i in range(400):
        t = i / 20.0
        weight = 20.0 + t + 2.0 * math.sin(0.8 * t)
        flow = 1.0 + 1.6 * math.cos(0.8 * (t - 0.2))
        diagnostics.append(frame(
            t,
            weight,
            flowGramsPerSecond=round(flow, 6),
            deviceTimestampMs=sb.round_half_away_from_zero(t * 1000.0 * 1.0001),
            sequence=i % 256,
        ))
    V.append(("shot-signal-diagnostics",
              "Shared numerical oracle for reported-flow validation, free-running device-clock "
              "skew, and packet coalescing. The reported flow trails the centered weight "
              "derivative by 200 ms and the device clock runs approximately 100 ppm fast.",
              {"mode": "shot", "deviceKind": "weighMyBruPlus", "frames": diagnostics,
               "events": [], "recordingStartMonotonicSeconds": 0.0,
               "recordingEndMonotonicSeconds": 20.0,
               "protocolCapabilities": {"hasChecksum": True, "hasSequence": True,
                                          "sequenceModulus": 256, "hasDeviceClock": True,
                                          "deviceClockSemantics": "freeRunning",
                                          "deviceClockModulus": 1 << 24}}))

    V.append(("shot-clean-80hz",
              "Metronomic 80 Hz at 0.1 g resolution. Most frames repeat the previous value because "
              "at 2 g/s the true weight changes only 0.025 g per frame -- less than one quantum. "
              "The resolution gate must treat those repeats as UNAVOIDABLE, so purity stays 1.0 "
              "and the score matches clean 20 Hz. Without the gate this scale would score ~25 "
              "for behaving correctly.",
              {"mode": "shot", "frames": stream(80, 30, pour), "events": []}))

    V.append(("shot-clean-10hz",
              "Metronomic 10 Hz. Half the 50 ms slots are served -> coverage 0.5, purity 1.0 -> 50. "
              "Pins the linear-coverage decision.",
              {"mode": "shot", "frames": stream(10, 30, pour), "events": []}))

    V.append(("shot-clean-5hz",
              "Metronomic 5 Hz -> coverage 0.25 -> 25.",
              {"mode": "shot", "frames": stream(5, 40, pour), "events": []}))

    V.append(("shot-clean-2hz",
              "Metronomic 2 Hz -> coverage 0.10 -> 10.",
              {"mode": "shot", "frames": stream(2, 40, pour), "events": []}))

    # 80 Hz where 3 of every 4 frames fail the checksum
    f = stream(80, 30, pour)
    for i, x in enumerate(f):
        if i % 4 != 0:
            x["parseFailed"] = True
    V.append(("shot-80hz-quarter-parseable",
              "80 Hz, 3 of every 4 frames fail their checksum. Each 50 ms slot still receives one "
              "good frame, so coverage stays 1.0 and purity falls to 0.25 -> 25.",
              {"mode": "shot", "frames": f, "events": [],
               "protocolCapabilities": {"hasChecksum": True}}))

    # 80 Hz where 3 of every 4 frames parse cleanly but carry impossible values
    f = []
    for i in range(2401):
        t = i * 0.0125
        true = pour(t)
        if i % 4 == 0:
            w = true
        elif i % 4 == 1:
            w = true + 37.5
        elif i % 4 == 2:
            w = true - 18.0
        else:
            w = true + 61.0
        f.append(frame(t, q(w, 0.1)))
    V.append(("shot-80hz-corrupt-values",
              "THE CASE THE FIVE-CLASS TAXONOMY MISSES. 80 Hz, 3 of every 4 frames carry garbage "
              "weights. Every one of them parses cleanly, is not a duplicate, is in sequence and "
              "is not stale -- so under parseFailure/duplicate/outOfOrder/stale alone they all "
              "count as usable and the score is 100. The `implausible` class closes it; above "
              "the reconstruction limit the stream scores 0 because the host cannot identify "
              "which frames are trustworthy.",
              {"mode": "shot", "frames": f, "events": [],
               "protocolCapabilities": {"hasChecksum": True}}))

    # 20 Hz with every second frame failing its checksum: usable frames land at
    # 10 Hz -> coverage 0.5, purity 0.5. Built from LABELLED parse failures so
    # the test isolates the multiplicative structure and does not also depend on
    # the impulse detector.
    halfhalf = stream(20, 30, pour)
    for i, x in enumerate(halfhalf):
        if i % 2 == 1:
            x["parseFailed"] = True
    sparse = []
    for i in range(2401):
        ts = i * 0.0125
        sparse.append(frame(ts, q(pour(ts) + (23.0 if i % 10 == 3 else 0.0), 0.1)))
    V.append(("shot-80hz-corrupt-sparse",
              "80 Hz with 10% isolated impulse corruption -- the realistic regime, where a "
              "3-point median filter can still identify the good frames. Contrast with "
              "shot-80hz-corrupt-values, which is past the reconstruction limit.",
              {"mode": "shot", "frames": sparse, "events": [],
               "protocolCapabilities": {"hasChecksum": True}}))

    V.append(("shot-half-coverage-half-purity",
              "20 Hz with every second frame failing its checksum. coverage 0.5 x purity 0.5 -> 25. Pins the "
              "multiplicative structure: neither factor can buy back the other.",
              {"mode": "shot", "frames": halfhalf, "events": [],
               "protocolCapabilities": {"hasChecksum": True}}))

    # avoidable duplicates: fine resolution, fast flow, value frozen for 200 ms at a time
    f = []
    for i in range(2401):
        ts = i * 0.0125
        # fine 0.01 g steps normally, frozen for 200 ms once every second
        held = ts if (ts % 1.0) < 0.8 else math.floor(ts) + 0.8
        f.append(frame(ts, q(pour(held, flow=5.0), 0.01)))
    V.append(("shot-avoidable-duplicates",
              "80 Hz at 0.01 g resolution during 5 g/s flow, emitting fine steps for 800 ms then "
              "freezing for 200 ms, once a second. Because the scale demonstrably CAN resolve "
              "0.01 g, the frozen stretches are avoidable and must classify as duplicate -- the "
              "mirror image of shot-clean-80hz, where identical repeats are excused because no "
              "finer step was ever achievable.",
              {"mode": "shot", "frames": f, "events": []}))

    # out-of-order sequence numbers
    f = stream(20, 30, pour, sequence=0)
    for i, x in enumerate(f):
        x["sequence"] = i % 256
    for i in range(10, len(f), 40):
        f[i]["sequence"] = (i - 5) % 256
    V.append(("shot-out-of-order-sequence",
              "20 Hz with a sequence number that jumps backwards every 40th frame. Only "
              "classifiable because the protocol exposes sequence numbers -- protocolVerification "
              "records that outOfOrder was verifiable here.",
              {"mode": "shot", "frames": f, "events": [],
               "protocolCapabilities": {"hasChecksum": True, "hasSequence": True}}))

    # stale device clock
    f = stream(20, 30, pour)
    for i, x in enumerate(f):
        x["deviceTimestampMs"] = i * 50 if i % 30 else max(0, (i - 10) * 50)
    V.append(("shot-stale-device-clock",
              "20 Hz where the device clock repeats an earlier value every 30th frame.",
              {"mode": "shot", "frames": f, "events": [],
               "protocolCapabilities": {"hasChecksum": True, "hasDeviceClock": True}}))

    # unverifiable protocol: no checksum, no sequence, no clock
    V.append(("shot-unverifiable-protocol",
              "Clean 20 Hz on a protocol with no checksum, no sequence numbers and no device "
              "clock. Delivery is 100, but purity could only be measured on duplicate and "
              "implausible, so protocolVerification must mark it an upper bound. A verified 100 and "
              "this 100 are not the same number.",
              {"mode": "shot", "frames": stream(20, 30, pour), "events": [],
               "protocolCapabilities": {"hasChecksum": False}}))

    # one long stall
    f = stream(20, 30, pour)
    for j in range(300, len(f)):
        f[j]["monotonicSeconds"] = round(f[j]["monotonicSeconds"] + 1.5, 6)
    V.append(("shot-single-stall",
              "Clean 20 Hz with one 1.5 s freeze. Coverage carries it; longestUnservedRunMs "
              "reports the run length, which the score deliberately does not weight (spec 4.5).",
              {"mode": "shot", "frames": f, "events": []}))

    # excluded frames must not touch the denominator
    f = stream(20, 30, pour)
    out = []
    for i, x in enumerate(f):
        out.append(x)
        if i % 10 == 0:
            out.append({"monotonicSeconds": x["monotonicSeconds"], "kind": "battery"})
        if i % 25 == 0:
            out.append({"monotonicSeconds": x["monotonicSeconds"], "kind": "unhandled"})
    V.append(("shot-excluded-frames-ignored",
              "Clean 20 Hz interleaved with battery and unhandled frames. Those must be excluded "
              "from the purity denominator entirely -- the score must equal shot-clean-20hz.",
              {"mode": "shot", "frames": out, "events": []}))

    # validity
    V.append(("shot-insufficient-duration",
              "8 s recording. Metrics reported, deliveryScore null.",
              {"mode": "shot", "frames": stream(20, 8, pour), "events": []}))

    V.append(("shot-two-frames",
              "Degenerate case the pre-v1 model scored happily.",
              {"mode": "shot", "frames": [frame(0.0, 0.0), frame(0.05, 0.5)], "events": []}))

    V.append(("shot-disconnect-invalidates",
              "Otherwise-perfect shot with a disconnect. Disconnect is a validity gate, not a "
              "scored component.",
              {"mode": "shot", "frames": stream(20, 30, pour),
               "events": [{"type": "disconnect", "monotonicSeconds": 18.4}]}))

    f = stream(20, 130, pour, cap=60.0)
    for j in range(1200, len(f)):
        f[j]["monotonicSeconds"] = round(f[j]["monotonicSeconds"] + 2.0, 6)
    V.append(("stress-disconnect-allowed",
              "Transport Stress: the same disconnect does not invalidate.",
              {"mode": "transportStress", "frames": f,
               "events": [{"type": "disconnect", "monotonicSeconds": 61.0},
                          {"type": "reconnect", "monotonicSeconds": 63.4}]}))

    # Transport Stress deliberately disables weight-physics and duplicate checks.
    # Even a protocol exposing every structural field therefore verifies only
    # parse failure, ordering, and freshness: 3 of 5 classes.
    f = []
    for i in range(2401):
        t = i * 0.05
        true = pour(t, cap=60.0)
        offsets = (0.0, 37.5, -18.0, 61.0)
        f.append(frame(t, q(true + offsets[i % 4], 0.1),
                       sequence=i % 256, deviceTimestampMs=i * 50))
    V.append(("stress-mode-disabled-checks",
              "Transport Stress with full protocol detail and 75% implausible-looking weights. "
              "The mode intentionally accepts all weight motion, but verification must report "
              "only the three enabled structural checks rather than claiming 5 of 5.",
              {"mode": "transportStress", "frames": f, "events": [],
               "protocolCapabilities": {
                   "hasChecksum": True,
                   "hasSequence": True,
                   "sequenceModulus": 256,
                   "hasDeviceClock": True,
                   "deviceClockSemantics": "freeRunning",
                   "deviceClockModulus": 1 << 32,
               }}))

    # idle
    V.append(("idle-clean", "70 s idle, 0.01 g noise, no drift.",
              {"mode": "idleStability",
               "frames": stream(20, 70, lambda t: det_noise(int(t * 20), 0.010), resolution=0.001),
               "events": []}))
    V.append(("idle-drift-only", "70 s idle drifting +0.5 g/min. Pins the OLS slope.",
              {"mode": "idleStability",
               "frames": stream(20, 70, lambda t: t * (0.5 / 60.0) + det_noise(int(t * 20), 0.004),
                                resolution=0.001),
               "events": []}))
    V.append(("idle-noisy", "70 s idle, 0.12 g noise, no drift.",
              {"mode": "idleStability",
               "frames": stream(20, 70, lambda t: det_noise(int(t * 20), 0.120), resolution=0.001),
               "events": []}))
    V.append(("idle-drift-and-noise",
              "Both. Noise is computed on DETRENDED residuals, so drift cannot inflate it -- "
              "compare noiseScore against idle-noisy.",
              {"mode": "idleStability",
               "frames": stream(20, 70, lambda t: t * (0.8 / 60.0) + det_noise(int(t * 20), 0.060),
                                resolution=0.001),
               "events": []}))
    V.append(("idle-too-short", "40 s idle: below the gate.",
              {"mode": "idleStability",
               "frames": stream(20, 40, lambda t: det_noise(int(t * 20), 0.010), resolution=0.001),
               "events": []}))

    V.append(("idle-three-frames-invalid",
              "A 60 s span with only three usable frames must not earn an Idle score.",
              {"mode": "idleStability",
               "frames": [frame(0.0, 0.0), frame(6.0, 0.0), frame(59.9, 0.0)],
               "recordingStartMonotonicSeconds": 0.0,
               "recordingEndMonotonicSeconds": 60.0,
               "events": []}))

    # step
    def step_fn(tau, ring=None):
        def fn(t):
            if t < 5.0:
                return 0.0
            x = t - 5.0
            if ring is None:
                return 20.0 * (1.0 - math.exp(-x / tau))
            return 20.0 * (1.0 - math.exp(-x / tau) * math.cos(2.0 * math.pi * x / ring))
        return fn

    V.append(("step-fast", "20 g step, 120 ms time constant: responsive, lightly filtered.",
              {"mode": "stepResponse", "frames": stream(20, 24, step_fn(0.12), resolution=0.01),
               "events": []}))
    V.append(("step-sluggish",
              "Same step, 900 ms time constant: heavy firmware smoothing. Coverage, purity and "
              "every delivery diagnostic are identical to step-fast -- only the step metrics "
              "separate them. This is the property Delivery structurally cannot see.",
              {"mode": "stepResponse", "frames": stream(20, 24, step_fn(0.90), resolution=0.01),
               "events": []}))
    V.append(("step-overshoot", "20 g step with ringing.",
              {"mode": "stepResponse", "frames": stream(20, 24, step_fn(0.15, 0.5), resolution=0.01),
               "events": []}))

    V.append(("step-three-frames-invalid",
              "Three frames spanning 10 s cannot prove rise time or a one-second settling hold.",
              {"mode": "stepResponse",
               "frames": [frame(0.0, 0.0), frame(5.0, 100.0), frame(9.9, 100.0)],
               "recordingStartMonotonicSeconds": 0.0,
               "recordingEndMonotonicSeconds": 10.0,
               "events": []}))

    # High-water semantics: a rejected backward value must never move the
    # comparison baseline backwards and make the next stale value look fresh.
    f = stream(20, 30, pour)
    for i, x in enumerate(f):
        x["sequence"] = i % 256
    f[100]["sequence"] = 90
    f[101]["sequence"] = 95
    V.append(("shot-sequence-high-water",
              "Two backward sequence values in a row. Both must be outOfOrder; the first "
              "must not reset the accepted sequence high-water mark.",
              {"mode": "shot", "frames": f, "events": [],
               "protocolCapabilities": {"hasSequence": True, "sequenceModulus": 256}}))

    f = stream(20, 30, pour)
    for i, x in enumerate(f):
        x["deviceTimestampMs"] = i * 50
    f[100]["deviceTimestampMs"] = 4000
    f[101]["deviceTimestampMs"] = 4500
    V.append(("shot-clock-high-water",
              "Two stale device-clock values in a row. Both must remain stale relative to the "
              "last accepted high-water value.",
              {"mode": "shot", "frames": f, "events": [],
               "protocolCapabilities": {"hasDeviceClock": True,
                                          "deviceClockSemantics": "freeRunning",
                                          "deviceClockModulus": 16777216}}))

    V.append(("shot-timer-is-not-device-clock",
              "A repeating shot timer is diagnostic data, not a free-running freshness clock.",
              {"mode": "shot",
               "frames": [dict(x, deviceTimestampMs=int((x["monotonicSeconds"] % 1.0) * 1000))
                          for x in stream(20, 30, pour)],
               "events": [],
               "protocolCapabilities": {"hasDeviceClock": True,
                                          "deviceClockSemantics": "shotTimer"}}))

    V.append(("shot-parse-failure-before-duplicate",
              "A parse-failed frame before a repeated weight must not become the duplicate "
              "detector's flow baseline or crash the analyzer.",
              {"mode": "shot",
               "frames": [dict(frame(0.0, 0.0), parseFailed=True), frame(0.5, 0.0),
                          frame(1.1, 0.0)] + [
                              frame(1.15 + i * 0.05, q(pour(1.15 + i * 0.05), 0.1))
                              for i in range(int((30.0 - 1.15) * 20) + 1)
                          ],
               "events": [], "protocolCapabilities": {"hasChecksum": True}}))

    V.append(("stress-trailing-outage",
              "Transport Stress records through 130 s but receives no frames for the last 10 s; "
              "authoritative recording boundaries must charge those empty slots.",
              {"mode": "transportStress", "frames": stream(20, 120, pour, cap=60.0),
               "recordingStartMonotonicSeconds": 0.0,
               "recordingEndMonotonicSeconds": 130.0,
               "events": [{"type": "disconnect", "monotonicSeconds": 120.0}]}))

    V.append(("stress-background-invalidates",
              "A clean Transport Stress stream that leaves the app foreground. Backgrounding "
              "invalidates every official result even though disconnects are allowed in this mode.",
              {"mode": "transportStress", "frames": stream(20, 130, lambda t: pour(t, cap=60.0)),
               "events": [
                   {"type": "appBackgrounded", "monotonicSeconds": 60.0},
                   {"type": "appForegrounded", "monotonicSeconds": 65.0},
               ]}))

    V.append(("shot-missing-boundaries-invalid",
              "First/last frame times may support diagnostics but cannot produce an official "
              "score without authoritative recording boundaries.",
              {"mode": "shot", "frames": stream(20, 30, pour), "events": [],
               "omitRecordingBoundaries": True}))

    return V


def main():
    os.makedirs(VECTORS, exist_ok=True)
    index = []
    for name, description, rec in build():
        d = os.path.join(VECTORS, name)
        os.makedirs(d, exist_ok=True)
        rec = dict(rec)
        omit_boundaries = rec.pop("omitRecordingBoundaries", False)
        if not omit_boundaries:
            frame_times = [x["monotonicSeconds"] for x in rec["frames"]
                           if "monotonicSeconds" in x]
            if frame_times:
                rec.setdefault("recordingStartMonotonicSeconds", min(frame_times))
                rec.setdefault("recordingEndMonotonicSeconds", max(frame_times))
        rec["vectorId"] = name
        rec["description"] = description
        expected = sb.analyze(rec)
        for fn, obj in (("input.json", rec), ("expected.json", expected)):
            with open(os.path.join(d, fn), "w") as fh:
                json.dump(obj, fh, indent=2, sort_keys=True)
                fh.write("\n")
        index.append({"vectorId": name, "mode": rec["mode"], "description": description,
                      "frameCount": len(rec["frames"]),
                      "isValid": expected["validity"]["isValid"],
                      "deliveryScore": expected["delivery"]["deliveryScore"],
                      "coverage": expected["delivery"]["coverage"],
                      "purity": expected["delivery"]["purity"],
                      "idleStabilityScore": (expected.get("idle") or {}).get("idleStabilityScore")})
    with open(os.path.join(VECTORS, "index.json"), "w") as fh:
        json.dump({"scoringModelVersion": sb.SCORING_MODEL_VERSION, "vectors": index},
                  fh, indent=2, sort_keys=True)
        fh.write("\n")
    return index


if __name__ == "__main__":
    for r in main():
        print("{:<30} {:<16} valid={:<5} cov={:<8} pur={:<8} -> {}".format(
            r["vectorId"], r["mode"], str(r["isValid"]),
            str(r["coverage"]), str(r["purity"]), str(r["deliveryScore"])))
