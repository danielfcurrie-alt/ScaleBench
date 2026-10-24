"""
ScaleBench scoring reference implementation.

Normative source: ../SCORING-SPEC.md
scoringModelVersion: standard-1.0.0

Delivery = 100 * coverage * purity.  Plain arithmetic only -- no numpy, no
library percentiles, no library rounding -- so every line transcribes directly
into Swift and Java.

Pinned cross-platform hazards:
  1. Percentile convention -> linear interpolation between closest ranks (R-7).
  2. Rounding mode         -> half away from zero (NOT banker's rounding).
  3. Frame classification  -> evaluated in a FIXED order; a frame takes the
                              first class that matches and is never reclassified.
"""

import math

SCORING_MODEL_VERSION = "standard-1.0.0"

SLOT_REFERENCE_HZ = 20.0
SLOT_MS = 1000.0 / SLOT_REFERENCE_HZ
SLOT_EPSILON = 1e-9      # see slot_index(): guards binary-float representation error

# Non-scoring signal diagnostics (spec section 9)
FLOW_DIAGNOSTIC_HALF_WINDOW_S = 0.5
FLOW_DIAGNOSTIC_MIN_CORRELATION = 0.25
FLOW_DIAGNOSTIC_LAG_STEP_S = 0.05
FLOW_DIAGNOSTIC_MAX_LAG_STEPS = 20
DEFAULT_DEVICE_CLOCK_MODULUS = 1 << 24
CLOCK_DIAGNOSTIC_KINDS = {"bookoo", "bookooMini", "bookooUltra", "weighMyBruPlus"}

# Implausibility thresholds (PROVISIONAL - spec section 10)
IMPULSE_DEVIATION_G = 0.5          # deviation from the 3-point median
MAX_PHYSICAL_FLOW_G_PER_S = 25.0   # beyond any real pour
FLOW_WINDOW_S = 1.0

# Duplicate resolution gate
MIN_RESOLUTION_G = 0.01

# Idle Stability constants (PROVISIONAL)
IDLE_SETTLING_SECONDS = 5.0
IDLE_NOISE_FREE_SD_G = 0.02
IDLE_NOISE_ZERO_SD_G = 0.20
IDLE_DRIFT_FREE_G_PER_MIN = 0.05
IDLE_DRIFT_ZERO_G_PER_MIN = 1.00
IDLE_NOISE_WEIGHT = 0.50
IDLE_DRIFT_WEIGHT = 0.50

# Step Response constants
STEP_MIN_GRAMS = 5.0
STEP_ONSET_FRACTION = 0.05
STEP_BASELINE_WINDOW_S = 2.0
STEP_FINAL_WINDOW_S = 2.0
STEP_SETTLE_BAND_G = 0.1
STEP_SETTLE_HOLD_S = 1.0
STEP_SETTLE_MAX_SAMPLE_GAP_S = 0.25

COMPONENT_FLOOR = 5.0

GATES = {
    "shot":            {"min_seconds": 20.0,  "min_usable": 2,   "disconnect_invalidates": True},
    "transportStress": {"min_seconds": 120.0, "min_usable": 2,   "disconnect_invalidates": False},
    "idleStability":   {"min_seconds": 60.0,  "min_usable": 100, "disconnect_invalidates": True},
    "stepResponse":    {"min_seconds": 10.0,  "min_usable": 30,  "disconnect_invalidates": True},
    "tareLatency":     {"min_seconds": 5.0,   "min_usable": 10,  "disconnect_invalidates": True},
    "batteryStability":{"min_seconds": 60.0,  "min_usable": 0,   "disconnect_invalidates": True},
}

IMPLAUSIBLE_UNRECONSTRUCTABLE_FRACTION = 0.30

FRAME_CLASSES = ["usable", "parseFailure", "outOfOrder", "stale", "duplicate", "implausible"]


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

def round_half_away_from_zero(x):
    return int(math.floor(x + 0.5)) if x >= 0 else int(math.ceil(x - 0.5))


def percentile(sorted_values, p):
    n = len(sorted_values)
    if n == 0:
        return None
    if n == 1:
        return sorted_values[0]
    h = (n - 1) * p
    lo = int(math.floor(h))
    if lo + 1 > n - 1:
        return sorted_values[n - 1]
    return sorted_values[lo] + (h - lo) * (sorted_values[lo + 1] - sorted_values[lo])


def clamp01(x):
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)


def sample_stddev(values):
    n = len(values)
    if n < 2:
        return None
    m = sum(values) / n
    return math.sqrt(sum((v - m) ** 2 for v in values) / (n - 1))


def ols_slope_intercept(xs, ys):
    n = len(xs)
    if n < 2:
        return None, None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0.0:
        return None, None
    sxy = sum((xs[i] - mx) * (ys[i] - my) for i in range(n))
    slope = sxy / sxx
    return slope, my - slope * mx


def floored(v):
    return COMPONENT_FLOOR + (1.0 - COMPONENT_FLOOR / 100.0) * v


def weighted_geometric_mean(pairs):
    return math.exp(sum(w * math.log(floored(v)) for v, w in pairs))


def r6(x):
    return None if x is None else round(x + 0.0, 6)


def median3(a, b, c):
    return sorted([a, b, c])[1]


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2 == 0:
        return (ordered[middle - 1] + ordered[middle]) / 2.0
    return ordered[middle]


def slot_index(seconds_since_start, slot_count):
    """Slot for an offset, guarded against binary-float representation error.

    Unguarded, 0.35 * 1000 evaluates to 349.99999999999994, so floor() puts a
    frame in slot 6 instead of slot 7 -- leaving a real slot unserved and
    costing coverage. The error appears at different inputs in Swift and Java,
    so an implementation that omits the epsilon will diverge on real data while
    passing casual inspection."""
    j = int(math.floor(seconds_since_start * 1000.0 / SLOT_MS + SLOT_EPSILON))
    return min(max(j, 0), slot_count - 1)


def interpolated_value(points, time):
    if not points or time < points[0][0] or time > points[-1][0]:
        return None
    low, high = 0, len(points) - 1
    while low <= high:
        middle = (low + high) // 2
        point_time, point_value = points[middle]
        if point_time == time:
            return point_value
        if point_time < time:
            low = middle + 1
        else:
            high = middle - 1
    if low <= 0 or low >= len(points):
        return None
    before_time, before_value = points[low - 1]
    after_time, after_value = points[low]
    span = after_time - before_time
    if span <= 0.0:
        return None
    fraction = (time - before_time) / span
    return before_value + (after_value - before_value) * fraction


def pearson_correlation(pairs):
    if len(pairs) < 2:
        return None
    mean_x = sum(x for x, _ in pairs) / len(pairs)
    mean_y = sum(y for _, y in pairs) / len(pairs)
    numerator = sum((x - mean_x) * (y - mean_y) for x, y in pairs)
    x_variance = sum((x - mean_x) ** 2 for x, _ in pairs)
    y_variance = sum((y - mean_y) ** 2 for _, y in pairs)
    denominator = math.sqrt(x_variance * y_variance)
    return numerator / denominator if denominator > 0.0 else None


# ---------------------------------------------------------------------------
# Frame classification -- each relevant weight frame gets exactly one class
# ---------------------------------------------------------------------------

def estimate_resolution(weights):
    """Conservative reported resolution estimate used by the duplicate gate."""
    deltas = [abs(weights[i] - weights[i - 1]) for i in range(1, len(weights))]
    nonzero = sorted(d for d in deltas if d > 0 and math.isfinite(d))
    if not nonzero:
        return MIN_RESOLUTION_G
    return max(MIN_RESOLUTION_G, percentile(nonzero, 0.10))


def forward_delta(previous, current, modulus=None):
    """Return a forward delta, or None for duplicate/backward movement."""
    if modulus is not None and modulus > 0:
        delta = (int(current) - int(previous)) % int(modulus)
        return delta if 0 < delta <= modulus / 2 else None
    delta = int(current) - int(previous)
    return delta if delta > 0 else None


def scoring_frames(recording):
    """Return scoring frames, using the WMB+ device clock for USB cadence."""
    frames = [dict(frame) for frame in recording.get("frames", [])]
    if recording.get("source") != "usbSerial":
        return frames

    for frame in frames:
        if frame.get("sequenceNumber") is not None:
            frame["sequence"] = frame["sequenceNumber"]
        if frame.get("firmwareMillis") is not None:
            frame["deviceTimestampMs"] = frame["firmwareMillis"]

    first_index = next(
        (index for index, frame in enumerate(frames)
         if frame.get("deviceTimestampMs") is not None),
        None,
    )
    if first_index is None:
        return frames

    modulus = 1 << 32
    previous = int(frames[first_index]["deviceTimestampMs"])
    elapsed_ms = 0
    anchor = frames[first_index]["monotonicSeconds"]
    for index in range(first_index, len(frames)):
        frame = frames[index]
        timestamp = frame.get("deviceTimestampMs")
        if timestamp is None:
            continue
        if index > first_index:
            delta = forward_delta(previous, timestamp, modulus)
            if delta is not None:
                elapsed_ms += delta
                previous = int(timestamp)
        frame["monotonicSeconds"] = anchor + elapsed_ms / 1000.0
    return frames


def classify_frames(frames, mode, capabilities=None):
    """Fixed evaluation order. A frame takes the first class that matches.

    parseFailure -> outOfOrder -> stale -> implausible -> duplicate -> usable

    `implausible` is evaluated BEFORE `duplicate` because a corrupted value is
    never a duplicate, and it is the class that catches the failure mode none of
    the others do: a frame that parses cleanly, carries a fresh sequence number
    and an advancing device clock, and reports a physically impossible weight.
    """
    capabilities = capabilities or {}
    weight_frames = [f for f in frames if f.get("kind", "weight") == "weight"]
    n = len(weight_frames)
    classes = [None] * n
    if n == 0:
        return weight_frames, classes, MIN_RESOLUTION_G

    parsed_weights = [
        f["weightGrams"] for f in weight_frames
        if not f.get("parseFailed") and f.get("weightGrams") is not None
        and math.isfinite(f["weightGrams"])
    ]
    resolution = estimate_resolution(parsed_weights) if len(parsed_weights) >= 2 else MIN_RESOLUTION_G

    last_usable = None          # index into weight_frames
    usable_indices = []
    last_sequence = None
    last_device_ms = None
    sequence_modulus = int(capabilities.get("sequenceModulus", 256))
    clock_modulus = capabilities.get("deviceClockModulus")
    if clock_modulus is not None:
        clock_modulus = int(clock_modulus)
    has_clock = bool(capabilities.get("hasDeviceClock")) or any(
        f.get("deviceTimestampMs") is not None for f in weight_frames
    )
    clock_semantics = capabilities.get(
        "deviceClockSemantics", "freeRunning" if has_clock else "none"
    )
    verifies_freshness = has_clock and clock_semantics == "freeRunning"
    checks_impulse = mode in ("shot", "idleStability")
    checks_physical_rate = mode == "idleStability"
    checks_duplicates = mode == "shot"

    for i, f in enumerate(weight_frames):
        if f.get("parseFailed") or f.get("weightGrams") is None \
                or not math.isfinite(f.get("weightGrams", math.nan)):
            classes[i] = "parseFailure"
            continue

        seq = f.get("sequence")
        if seq is not None and last_sequence is not None:
            if forward_delta(last_sequence, seq, sequence_modulus) is None:
                classes[i] = "outOfOrder"
                continue

        dev = f.get("deviceTimestampMs")
        if verifies_freshness and dev is not None and last_device_ms is not None:
            if forward_delta(last_device_ms, dev, clock_modulus) is None:
                classes[i] = "stale"
                continue

        # Structurally valid sequence/clock values advance their high-water marks.
        # Rejected backward values never move the marks backwards.
        if seq is not None:
            last_sequence = seq
        if verifies_freshness and dev is not None:
            last_device_ms = dev

        w = f["weightGrams"]
        implausible = False

        if checks_impulse:
            # (a) impulse: disagrees with both parseable neighbours
            if 0 < i < n - 1 and not weight_frames[i - 1].get("parseFailed") \
                    and not weight_frames[i + 1].get("parseFailed") \
                    and weight_frames[i - 1].get("weightGrams") is not None \
                    and weight_frames[i + 1].get("weightGrams") is not None:
                med = median3(weight_frames[i - 1]["weightGrams"], w, weight_frames[i + 1]["weightGrams"])
                if abs(w - med) > IMPULSE_DEVIATION_G:
                    implausible = True

        if checks_physical_rate and last_usable is not None:
            prev = weight_frames[last_usable]
            dt = f["monotonicSeconds"] - prev["monotonicSeconds"]
            if dt > 0:
                # (b) rate beyond anything physical
                if abs(w - prev["weightGrams"]) / dt > MAX_PHYSICAL_FLOW_G_PER_S:
                    implausible = True

        if implausible:
            classes[i] = "implausible"
            continue

        # duplicate, but only when a distinct value was ACHIEVABLE
        if checks_duplicates and last_usable is not None:
            prev = weight_frames[last_usable]
            if w == prev["weightGrams"]:
                dt = f["monotonicSeconds"] - prev["monotonicSeconds"]
                base = None
                for j in reversed(usable_indices):
                    if weight_frames[j]["monotonicSeconds"] <= f["monotonicSeconds"] - FLOW_WINDOW_S:
                        base = weight_frames[j]
                        break
                achievable = False
                if base is not None and dt > 0:
                    span = f["monotonicSeconds"] - base["monotonicSeconds"]
                    if span > 0:
                        flow = abs(w - base["weightGrams"]) / span
                        if flow * dt >= resolution:
                            achievable = True
                if achievable:
                    classes[i] = "duplicate"
                    continue

        classes[i] = "usable"
        last_usable = i
        usable_indices.append(i)

    return weight_frames, classes, resolution


# ---------------------------------------------------------------------------
# Delivery = coverage * purity
# ---------------------------------------------------------------------------

def coverage_and_purity(weight_frames, classes, recording_start, recording_end,
                        additional_lost_frames=0):
    n = len(weight_frames)
    if n == 0 or recording_start is None or recording_end is None:
        return None, None, None

    usable_count = sum(1 for c in classes if c == "usable")
    purity = usable_count / (n + additional_lost_frames)

    span_ms = (recording_end - recording_start) * 1000.0
    if span_ms <= 0:
        return None, None, None

    slot_count = int(math.floor(span_ms / SLOT_MS + SLOT_EPSILON))
    if slot_count < 1:
        return None, None, None

    served = [False] * slot_count
    for i, f in enumerate(weight_frames):
        if classes[i] != "usable":
            continue
        offset = f["monotonicSeconds"] - recording_start
        if offset < 0 or offset * 1000.0 >= slot_count * SLOT_MS:
            continue
        served[slot_index(offset, slot_count)] = True

    coverage = sum(1 for x in served if x) / slot_count

    longest_run = 0
    run = 0
    for x in served:
        run = 0 if x else run + 1
        longest_run = max(longest_run, run)

    return coverage, purity, {"slotCount": slot_count,
                              "servedSlots": sum(1 for x in served if x),
                              "longestUnservedRunMs": longest_run * SLOT_MS}


# ---------------------------------------------------------------------------
# Idle Stability
# ---------------------------------------------------------------------------

def idle_stability(samples, recording_start):
    if len(samples) < 2:
        return None
    window = [
        s for s in samples
        if s["monotonicSeconds"] - recording_start >= IDLE_SETTLING_SECONDS
    ]
    if len(window) < 2:
        return None

    base = window[0]["monotonicSeconds"]
    xs = [s["monotonicSeconds"] - base for s in window]
    ys = [s["weightGrams"] for s in window]

    slope, intercept = ols_slope_intercept(xs, ys)
    if slope is None:
        return None

    drift_g_per_min = slope * 60.0
    residuals = [ys[i] - (intercept + slope * xs[i]) for i in range(len(xs))]
    sd = sample_stddev(residuals)
    rs = sorted(residuals)
    p2p = percentile(rs, 0.995) - percentile(rs, 0.005)

    deltas = []
    for i in range(1, len(ys)):
        d = abs(ys[i] - ys[i - 1])
        if d > 0:
            deltas.append(d)
    resolution = min(deltas) if deltas else None

    noise = 100.0 * clamp01((IDLE_NOISE_ZERO_SD_G - sd) /
                            (IDLE_NOISE_ZERO_SD_G - IDLE_NOISE_FREE_SD_G)) if sd is not None else None
    drift = 100.0 * clamp01((IDLE_DRIFT_ZERO_G_PER_MIN - abs(drift_g_per_min)) /
                            (IDLE_DRIFT_ZERO_G_PER_MIN - IDLE_DRIFT_FREE_G_PER_MIN))

    overall = None
    if noise is not None:
        overall = round_half_away_from_zero(weighted_geometric_mean(
            [(noise, IDLE_NOISE_WEIGHT), (drift, IDLE_DRIFT_WEIGHT)]
        ))
        overall = max(0, min(100, overall))

    return {
        "idleStabilityScore": overall,
        "noiseScore": round_half_away_from_zero(noise) if noise is not None else None,
        "driftScore": round_half_away_from_zero(drift),
        "analysedSampleCount": len(window),
        "residualStandardDeviationGrams": r6(sd),
        "residualPeakToPeakGrams": r6(p2p),
        "driftGramsPerMinute": r6(drift_g_per_min),
        "resolutionGrams": r6(resolution),
    }


# ---------------------------------------------------------------------------
# Step Response (metrics only -- not scored in v1, see spec section 6)
# ---------------------------------------------------------------------------

def step_response(samples, recording_start, recording_end):
    """Metrics only -- not scored in v1 (spec section 6).

    Assumes the documented Step Response procedure: settle empty, start
    recording, wait, apply the mass, wait for it to settle, stop.
    """
    if len(samples) < 3:
        return {"stepDetected": False}

    pre = [x["weightGrams"] for x in samples
           if recording_start <= x["monotonicSeconds"] <= recording_start + STEP_BASELINE_WINDOW_S]
    post = [x["weightGrams"] for x in samples
            if recording_end - STEP_FINAL_WINDOW_S <= x["monotonicSeconds"] < recording_end]
    if not pre or not post:
        return {"stepDetected": False}

    baseline = percentile(sorted(pre), 0.50)
    final = percentile(sorted(post), 0.50)
    amplitude = final - baseline
    if amplitude < STEP_MIN_GRAMS:
        return {"stepDetected": False}

    def first_time_at_or_above(level):
        for x in samples:
            if x["weightGrams"] >= level:
                return x["monotonicSeconds"]
        return None

    onset_t = first_time_at_or_above(baseline + STEP_ONSET_FRACTION * amplitude)
    t10 = first_time_at_or_above(baseline + 0.10 * amplitude)
    t90 = first_time_at_or_above(baseline + 0.90 * amplitude)
    if onset_t is None:
        return {"stepDetected": False}

    settle_t = None
    for i in range(len(samples)):
        x = samples[i]
        if x["monotonicSeconds"] < onset_t:
            continue
        if abs(x["weightGrams"] - final) > STEP_SETTLE_BAND_G:
            continue
        hold_end = x["monotonicSeconds"] + STEP_SETTLE_HOLD_S
        observed_through_hold = False
        held = True
        previous_t = x["monotonicSeconds"]
        for j in range(i, len(samples)):
            candidate = samples[j]
            if candidate["monotonicSeconds"] - previous_t > STEP_SETTLE_MAX_SAMPLE_GAP_S:
                held = False
                break
            if abs(candidate["weightGrams"] - final) > STEP_SETTLE_BAND_G:
                held = False
                break
            if candidate["monotonicSeconds"] >= hold_end:
                observed_through_hold = True
                break
            previous_t = candidate["monotonicSeconds"]
        if held and observed_through_hold:
            settle_t = x["monotonicSeconds"]
            break

    after = [x["weightGrams"] for x in samples if x["monotonicSeconds"] >= onset_t]
    peak = max(after) if after else final
    overshoot = ((peak - final) / amplitude * 100.0) if (amplitude > 0 and peak > final) else 0.0

    return {
        "stepDetected": True,
        "onsetSecondsFromRecordingStart": r6(onset_t - recording_start),
        "baselineGrams": r6(baseline),
        "finalGrams": r6(final),
        "amplitudeGrams": r6(amplitude),
        "riseTime10To90Seconds": r6(t90 - t10) if (t10 is not None and t90 is not None) else None,
        "settlingTimeSeconds": r6(settle_t - onset_t) if settle_t is not None else None,
        "overshootPercent": r6(overshoot),
    }


# ---------------------------------------------------------------------------
# Protocol verification -- how much of purity was actually observable
# ---------------------------------------------------------------------------

def protocol_verification(frames, capabilities, mode):
    """Purity is measured with different instruments on different protocols. A
    scale with no checksum can never register a parseFailure; one with no
    sequence numbers can never register outOfOrder. Its purity is an UPPER
    BOUND, not a measurement. This result reports how much of it was real, and
    MUST be displayed adjacent to the Delivery Score."""
    caps = capabilities or {}
    has_checksum = bool(caps.get("hasChecksum"))
    has_sequence = bool(caps.get("hasSequence")) or any(f.get("sequence") is not None for f in frames)
    has_clock = bool(caps.get("hasDeviceClock")) or any(f.get("deviceTimestampMs") is not None for f in frames)
    has_free_running_clock = has_clock and caps.get("deviceClockSemantics", "freeRunning") == "freeRunning"
    checks_implausible = mode in ("shot", "idleStability")
    checks_duplicates = mode == "shot"

    verifiable = {
        "parseFailure": has_checksum,
        "outOfOrder": has_sequence,
        "stale": has_free_running_clock,
        "duplicate": checks_duplicates,
        "implausible": checks_implausible,
    }
    verified = sum(1 for v in verifiable.values() if v)
    return {
        "verifiableClasses": sorted(k for k, v in verifiable.items() if v),
        "unverifiableClasses": sorted(k for k, v in verifiable.items() if not v),
        "verificationCoveragePercent": round_half_away_from_zero(100.0 * verified / len(verifiable)),
        "purityIsUpperBound": verified < len(verifiable),
    }


# ---------------------------------------------------------------------------
# Signal diagnostics -- normative, cross-platform, and never scored
# ---------------------------------------------------------------------------

def parsed_samples(recording):
    samples = []
    default_kind = recording.get("deviceKind", "unknown")
    for position, frame in enumerate(recording.get("frames", [])):
        if frame.get("kind", "weight") != "weight" or frame.get("parseFailed"):
            continue
        seconds = frame.get("monotonicSeconds")
        weight = frame.get("weightGrams")
        if seconds is None or weight is None or not math.isfinite(seconds) or not math.isfinite(weight):
            continue
        sample = dict(frame)
        if sample.get("firmwareMillis") is not None:
            sample["deviceTimestampMs"] = sample["firmwareMillis"]
        if sample.get("sequenceNumber") is not None:
            sample["sequence"] = sample["sequenceNumber"]
        sample["monotonicSeconds"] = float(seconds)
        sample["weightGrams"] = float(weight)
        sample["scaleKind"] = frame.get("scaleKind", default_kind)
        sample["_position"] = position
        samples.append(sample)
    return samples


def strictly_increasing_samples(samples):
    ordered = sorted(samples, key=lambda sample: (sample["monotonicSeconds"], sample["_position"]))
    result = []
    for sample in ordered:
        if result and sample["monotonicSeconds"] <= result[-1]["monotonicSeconds"]:
            continue
        result.append(sample)
    return result


def flow_validation(samples):
    samples = strictly_increasing_samples(samples)
    if len(samples) < 5 or samples[-1]["monotonicSeconds"] - samples[0]["monotonicSeconds"] < 1.0:
        return None

    reported = [
        (sample["monotonicSeconds"], float(sample["flowGramsPerSecond"]))
        for sample in samples
        if sample.get("flowGramsPerSecond") is not None
        and math.isfinite(sample["flowGramsPerSecond"])
    ]
    if len(reported) < 5:
        return None

    weight_points = [(sample["monotonicSeconds"], sample["weightGrams"]) for sample in samples]
    derived = []
    for sample in samples:
        seconds = sample["monotonicSeconds"]
        left = interpolated_value(weight_points, seconds - FLOW_DIAGNOSTIC_HALF_WINDOW_S)
        right = interpolated_value(weight_points, seconds + FLOW_DIAGNOSTIC_HALF_WINDOW_S)
        if left is not None and right is not None:
            derived.append((
                seconds,
                (right - left) / (FLOW_DIAGNOSTIC_HALF_WINDOW_S * 2.0),
            ))
    if len(derived) < 5:
        return None

    best_lag = None
    best_correlation = None
    for step in range(-FLOW_DIAGNOSTIC_MAX_LAG_STEPS, FLOW_DIAGNOSTIC_MAX_LAG_STEPS + 1):
        lag = step * FLOW_DIAGNOSTIC_LAG_STEP_S
        pairs = []
        for seconds, reported_value in reported:
            derived_value = interpolated_value(derived, seconds - lag)
            if derived_value is not None:
                pairs.append((reported_value, derived_value))
        if len(pairs) < 8:
            continue
        correlation = pearson_correlation(pairs)
        if correlation is None:
            continue
        if (best_correlation is None
                or correlation > best_correlation + 0.000001
                or (abs(correlation - best_correlation) <= 0.000001
                    and abs(lag) < abs(best_lag if best_lag is not None else math.inf))):
            best_correlation = correlation
            best_lag = lag

    if best_correlation is not None and best_correlation < FLOW_DIAGNOSTIC_MIN_CORRELATION:
        best_lag = None
    alignment_lag = best_lag if best_lag is not None else 0.0
    errors = []
    for seconds, reported_value in reported:
        derived_value = interpolated_value(derived, seconds - alignment_lag)
        if derived_value is not None:
            errors.append(abs(reported_value - derived_value))
    median_error = median(errors)
    if len(errors) < 5 or median_error is None:
        return None

    return {
        "sampleCount": len(errors),
        "medianAbsoluteErrorGramsPerSecond": r6(median_error),
        "lagMilliseconds": r6(best_lag * 1000.0) if best_lag is not None else None,
        "correlation": r6(best_correlation) if best_lag is not None else None,
    }


def clock_skew(recording, samples):
    samples = sorted(samples, key=lambda sample: (sample["monotonicSeconds"], sample["_position"]))
    kind = recording.get("deviceKind") or (samples[0].get("scaleKind") if samples else "unknown")
    capabilities = recording.get("protocolCapabilities") or {}
    if kind not in CLOCK_DIAGNOSTIC_KINDS or capabilities.get("deviceClockSemantics") == "shotTimer":
        return None

    modulus = float(capabilities.get("deviceClockModulus", DEFAULT_DEVICE_CLOCK_MODULUS))
    points = []
    previous_raw = None
    previous_unwrapped = None
    offset = 0.0
    for sample in samples:
        timestamp = sample.get("deviceTimestampMs")
        if timestamp is None:
            continue
        raw = float(timestamp)
        if previous_raw is not None and raw < previous_raw:
            if previous_raw - raw > modulus / 2.0:
                offset += modulus
            else:
                continue
        unwrapped = raw + offset
        if previous_unwrapped is not None and unwrapped <= previous_unwrapped:
            continue
        points.append((sample["monotonicSeconds"] * 1000.0, unwrapped))
        previous_raw = raw
        previous_unwrapped = unwrapped

    if len(points) < 10 or points[-1][0] - points[0][0] < 5000.0:
        return None
    mean_host = sum(host for host, _ in points) / len(points)
    mean_device = sum(device for _, device in points) / len(points)
    numerator = sum((host - mean_host) * (device - mean_device) for host, device in points)
    denominator = sum((host - mean_host) ** 2 for host, _ in points)
    if denominator <= 0.0:
        return None
    skew = (numerator / denominator - 1.0) * 1000000.0
    if not math.isfinite(skew):
        return None
    return {"sampleCount": len(points), "skewPartsPerMillion": r6(skew)}


def packet_coalescing(delivery_applicable, coverage, frame_rate_hz):
    if (not delivery_applicable or coverage is None or frame_rate_hz is None
            or coverage <= 0.0 or frame_rate_hz < 0.0):
        return None
    served_slot_rate_hz = coverage * SLOT_REFERENCE_HZ
    if served_slot_rate_hz <= 0.0:
        return None
    return {
        "observedFrameRateHz": r6(frame_rate_hz),
        "servedSlotRateHz": r6(served_slot_rate_hz),
        "framesPerServedSlot": r6(frame_rate_hz / served_slot_rate_hz),
    }


def signal_diagnostics(recording, delivery_applicable, coverage, frame_rate_hz):
    if recording.get("recordingEndMonotonicSeconds") is None:
        return {"flowValidation": None, "clockSkew": None, "packetCoalescing": None}
    samples = parsed_samples(recording)
    return {
        "flowValidation": flow_validation(samples),
        "clockSkew": clock_skew(recording, samples),
        "packetCoalescing": packet_coalescing(delivery_applicable, coverage, frame_rate_hz),
    }


# ---------------------------------------------------------------------------
# Validity
# ---------------------------------------------------------------------------

def evaluate_validity(mode, recording_start, recording_end, boundaries_present, samples, events):
    gate = GATES.get(mode)
    if gate is None:
        return {"isValid": False, "reasons": ["unknownMode"]}
    reasons = []
    if not boundaries_present:
        reasons.append("recordingBoundariesMissing")
    span_s = max(0.0, recording_end - recording_start) \
        if recording_start is not None and recording_end is not None else 0.0
    if span_s < gate["min_seconds"]:
        reasons.append("durationBelowMinimum")
    if len(samples) < gate["min_usable"]:
        reasons.append("usableFrameCountBelowMinimum")
    if mode == "idleStability":
        analysed = [
            s for s in samples
            if s["monotonicSeconds"] - recording_start >= IDLE_SETTLING_SECONDS
        ]
        if len(analysed) < gate["min_usable"]:
            reasons.append("idleAnalysedFrameCountBelowMinimum")
    if mode == "stepResponse":
        baseline_count = sum(
            1 for s in samples
            if recording_start <= s["monotonicSeconds"] <= recording_start + STEP_BASELINE_WINDOW_S
        )
        final_count = sum(
            1 for s in samples
            if recording_end - STEP_FINAL_WINDOW_S <= s["monotonicSeconds"] < recording_end
        )
        if baseline_count < 5:
            reasons.append("stepBaselineFrameCountBelowMinimum")
        if final_count < 5:
            reasons.append("stepFinalFrameCountBelowMinimum")
    if gate["disconnect_invalidates"] and any(e.get("type") == "disconnect" for e in events):
        reasons.append("disconnectDuringRecording")
    if any(e.get("type") == "appBackgrounded" for e in events):
        reasons.append("appLeftForeground")
    return {"isValid": len(reasons) == 0, "reasons": reasons}


# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

def analyze(recording):
    mode = recording["mode"]
    frames = scoring_frames(recording)
    events = recording.get("events", [])

    explicit_start = recording.get("recordingStartMonotonicSeconds")
    explicit_end = recording.get("recordingEndMonotonicSeconds")
    boundaries_present = explicit_start is not None and explicit_end is not None \
        and explicit_end > explicit_start
    frame_times = [f.get("monotonicSeconds") for f in frames if f.get("monotonicSeconds") is not None]
    recording_start = explicit_start if explicit_start is not None else (min(frame_times) if frame_times else 0.0)
    recording_end = explicit_end if explicit_end is not None else (max(frame_times) if frame_times else recording_start)

    bounded_frames = [
        f for f in frames
        if f.get("monotonicSeconds") is not None
        and recording_start <= f["monotonicSeconds"] < recording_end
    ]
    capabilities = recording.get("protocolCapabilities")
    weight_frames, classes, resolution = classify_frames(bounded_frames, mode, capabilities)
    verification = protocol_verification(bounded_frames, capabilities, mode)
    usb_dropped_frames = sum(
        max(0, int(frame.get("usbDroppedDelta", 0))) for frame in weight_frames
    ) if recording.get("source") == "usbSerial" else 0
    coverage, purity, slot_info = coverage_and_purity(
        weight_frames, classes, recording_start, recording_end, usb_dropped_frames
    )

    # Usable frames are the sample stream Idle and Step analyse.
    samples = [{"monotonicSeconds": f["monotonicSeconds"], "weightGrams": f["weightGrams"]}
               for i, f in enumerate(weight_frames) if classes[i] == "usable"]
    validity = evaluate_validity(
        mode, recording_start, recording_end, boundaries_present, samples, events
    )

    is_delivery_mode = mode in ("shot", "transportStress")
    delivery = None
    counts = {c: 0 for c in FRAME_CLASSES}
    for c in classes:
        if c is not None:
            counts[c] += 1

    # Above ~30% impulse corruption a 3-point median filter can no longer tell
    # signal from noise -- the good frames disagree with their neighbours just as
    # much as the bad ones do, so everything classifies implausible. This is a
    # diagnostic flag; Delivery still comes from coverage x purity.
    unreconstructable = (len(weight_frames) > 0 and
                         counts["implausible"] / len(weight_frames) > IMPLAUSIBLE_UNRECONSTRUCTABLE_FRACTION)

    if is_delivery_mode and validity["isValid"] and coverage is not None and purity is not None:
        delivery = max(0, min(100, round_half_away_from_zero(100.0 * coverage * purity)))

    intervals = [(weight_frames[i]["monotonicSeconds"] - weight_frames[i - 1]["monotonicSeconds"]) * 1000.0
                 for i in range(1, len(weight_frames))]
    sorted_iv = sorted(intervals)
    p25 = percentile(sorted_iv, 0.25) if sorted_iv else None
    p50 = percentile(sorted_iv, 0.50) if sorted_iv else None
    p75 = percentile(sorted_iv, 0.75) if sorted_iv else None
    frame_rate_hz = len(weight_frames) / (recording_end - recording_start) \
        if recording_end > recording_start else None
    if len(samples) >= 2:
        sample_span = max(0.0, samples[-1]["monotonicSeconds"] - samples[0]["monotonicSeconds"])
    else:
        sample_span = 0.0

    result = {
        "scoringModelVersion": SCORING_MODEL_VERSION,
        "scoringProfileName": "ScaleBench Standard v1",
        "mode": mode,
        "validity": validity,
        "delivery": {
            "applicable": is_delivery_mode,
            "deliveryScore": delivery,
            "coverage": r6(coverage) if is_delivery_mode else None,
            "purity": r6(purity) if is_delivery_mode else None,
            "purityIsUpperBound": verification["purityIsUpperBound"] if is_delivery_mode else None,
        },
        "frameClassification": counts,
        "signalUnreconstructable": unreconstructable,
        "protocolVerification": verification,
        "diagnostics": {
            "relevantWeightFrames": len(weight_frames),
            "excludedFrames": len(frames) - len(weight_frames),
            "usableSampleCount": len(samples),
            "spanSeconds": r6(max(0.0, recording_end - recording_start)),
            "recordingBoundaryInferred": not boundaries_present,
            "frameRateHz": r6(frame_rate_hz),
            "usableRateHz": r6(len(samples) / sample_span) if sample_span > 0 else None,
            "estimatedResolutionGrams": r6(resolution),
            "slotCount": (slot_info or {}).get("slotCount"),
            "servedSlots": (slot_info or {}).get("servedSlots"),
            "longestUnservedRunMs": r6((slot_info or {}).get("longestUnservedRunMs")),
            "intervalP50Ms": r6(p50),
            "robustCoefficientOfVariation": r6((p75 - p25) / p50) if (p50 and p50 > 0) else None,
            "intervalMaxMs": r6(max(intervals)) if intervals else None,
            "disconnectCount": sum(1 for e in events if e.get("type") == "disconnect"),
        },
        "signalDiagnostics": signal_diagnostics(
            recording,
            is_delivery_mode,
            r6(coverage),
            r6(frame_rate_hz),
        ),
    }

    if mode == "idleStability":
        idle = idle_stability(samples, recording_start)
        if idle is not None and not validity["isValid"]:
            idle["idleStabilityScore"] = None
        result["idle"] = idle
    if mode == "stepResponse":
        result["stepResponse"] = step_response(samples, recording_start, recording_end)

    return result
