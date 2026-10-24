package app.scalebench.android;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class ChartAnalysis {
    static AndroidChartAnalysis create(ScaleRecording recording, ScaleQualityMetrics metrics) {
        double referenceTime = chartReferenceTime(recording);
        List<ScaleSample> samples = ScaleQualityAnalyzer.canonicalWeightSamples(recording);
        List<ChartPoint> weightPoints = sampleChartPoints(samples, referenceTime);
        List<ChartPoint> flowPoints = flowChartPoints(samples, referenceTime);
        AndroidPacketTimeline timeline = packetTimeline(recording, referenceTime);
        return new AndroidChartAnalysis(
                weightPoints,
                flowPoints,
                timeline,
                problemWindows(weightPoints, timeline),
                chartDeductions(metrics),
                signalDiagnostics(recording, samples, metrics)
        );
    }

    static AndroidPacketTimeline packetTimeline(ScaleRecording recording) {
        return packetTimeline(recording, chartReferenceTime(recording));
    }

    private static AndroidPacketTimeline packetTimeline(ScaleRecording recording, double referenceTime) {
        List<RawScalePacket> packets = new ArrayList<>(recording.rawPackets);
        packets.sort(Comparator.comparingDouble(packet -> packet.monotonicSeconds));
        List<ScaleSample> samples = new ArrayList<>(ScaleQualityAnalyzer.canonicalWeightSamples(recording));
        samples.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        double threshold = ScaleQualityAnalyzer.longGapThresholdMilliseconds(samples, recording.scoringProfile);
        List<AndroidSampleInterval> intervals = sampleIntervalEntries(
                samples,
                referenceTime,
                threshold,
                recording.recordingStartMonotonicSeconds,
                recording.recordingEndMonotonicSeconds
        );
        double recordingDuration = recording.recordingEndMonotonicSeconds == null
                ? 0.0
                : Math.max(0.0, recording.recordingEndMonotonicSeconds - referenceTime);
        List<AndroidScoringGap> gaps = gapsFromIntervals(intervals);
        List<AndroidPacketTimelineEntry> entries = new ArrayList<>();
        RawScalePacket previous = null;
        for (int index = 0; index < packets.size(); index++) {
            RawScalePacket packet = packets.get(index);
            Double intervalMs = previous == null ? null : Math.max(0, (packet.monotonicSeconds - previous.monotonicSeconds) * 1000.0);
            PacketRole role = packet.role == null ? PacketRole.UNKNOWN : packet.role;
            boolean compatibilityFloat32 = role == PacketRole.UNKNOWN
                    && packet.rejectionReason == null
                    && packet.characteristicUuid != null
                    && ScaleParsers.uuidMatches(packet.characteristicUuid, ScaleParsers.WMB_FLOAT32_UUID);
            String roleLabel = compatibilityFloat32 ? "compatibility" : packetRoleLabel(role);
            String rejection = packet.rejectionReason == null ? null : packet.rejectionReason.name();
            AndroidPacketSeverity severity = packetSeverity(roleLabel, rejection, intervalMs, threshold);
            entries.add(new AndroidPacketTimelineEntry(
                    index,
                    packet.monotonicSeconds - referenceTime,
                    previous == null ? null : previous.monotonicSeconds - referenceTime,
                    intervalMs,
                    roleLabel,
                    packet.bytesHex == null ? "" : packet.bytesHex,
                    packet.characteristicUuid == null ? "" : packet.characteristicUuid,
                    rejection,
                    packet.sequence,
                    packet.weightGrams,
                    severity,
                    packetLane(roleLabel, severity),
                    packetEvidence(roleLabel, rejection, intervalMs, threshold),
                    ScaleParsers.packetFields(packet)
            ));
            previous = packet;
        }
        return new AndroidPacketTimeline(entries, gaps, threshold, intervals, recordingDuration);
    }

    static List<Double> sampleIntervals(List<ChartPoint> points) {
        List<Double> intervals = new ArrayList<>();
        for (int index = 1; index < points.size(); index++) {
            intervals.add(Math.max(0, (points.get(index).seconds - points.get(index - 1).seconds) * 1000.0));
        }
        return intervals;
    }

    static List<ChartPoint> pointsInWindow(List<ChartPoint> points, ChartWindow window) {
        if (window == null) return points;
        List<ChartPoint> visible = new ArrayList<>();
        for (ChartPoint point : points) {
            if (point.seconds >= window.startSeconds && point.seconds <= window.endSeconds) visible.add(point);
        }
        if (visible.size() >= 2) return visible;
        ChartPoint before = null;
        ChartPoint after = null;
        for (ChartPoint point : points) {
            if (point.seconds < window.startSeconds) before = point;
            if (after == null && point.seconds > window.endSeconds) after = point;
        }
        List<ChartPoint> fallback = new ArrayList<>();
        if (before != null) fallback.add(before);
        if (after != null) fallback.add(after);
        if (fallback.size() >= 2) return fallback;
        return points.subList(0, Math.min(2, points.size()));
    }

    static List<ChartWindow> problemWindows(List<ChartPoint> points, AndroidPacketTimeline timeline) {
        double lastSecond = Math.max(
                points.isEmpty() ? 0.0 : points.get(points.size() - 1).seconds,
                timeline.getDurationSeconds()
        );
        if (lastSecond <= 0.0) return new ArrayList<>();
        List<ChartWindow> windows = new ArrayList<>();
        for (int index = 0; index < Math.min(3, timeline.scoringGaps.size()); index++) {
            AndroidScoringGap gap = timeline.scoringGaps.get(index);
            windows.add(new ChartWindow(
                    "Gap " + (index + 1) + " (" + String.format(Locale.US, "%.0f ms", gap.intervalMs) + ")",
                    Math.max(0, gap.startSeconds - 2.0),
                    Math.min(lastSecond, gap.endSeconds + 2.0),
                    AndroidChartProblemCategory.GAP,
                    AndroidPacketSeverity.PENALTY,
                    null
            ));
        }
        for (AndroidPacketTimelineEntry entry : timeline.entries) {
            if (windows.size() >= 3) break;
            if (entry.severity != AndroidPacketSeverity.PENALTY) continue;
            windows.add(new ChartWindow(
                    "Packet " + (entry.id + 1) + " " + entry.severity.label,
                    Math.max(0, entry.relativeSeconds - 2.0),
                    Math.min(lastSecond, entry.relativeSeconds + 2.0),
                    entry.rejectionReason == null ? AndroidChartProblemCategory.DIAGNOSTIC : AndroidChartProblemCategory.PARSE_FAILURE,
                    entry.severity,
                    entry.id
            ));
        }
        if (windows.isEmpty()) {
            for (AndroidPacketTimelineEntry entry : timeline.entries) {
                if (windows.size() >= 2) break;
                if (entry.severity != AndroidPacketSeverity.WARNING) continue;
                windows.add(new ChartWindow(
                        "Packet " + (entry.id + 1) + " warning",
                        Math.max(0, entry.relativeSeconds - 2.0),
                        Math.min(lastSecond, entry.relativeSeconds + 2.0),
                        AndroidChartProblemCategory.DIAGNOSTIC,
                        AndroidPacketSeverity.WARNING,
                        entry.id
                ));
            }
        }
        Map<String, ChartWindow> distinct = new LinkedHashMap<>();
        for (ChartWindow window : windows) {
            ChartWindow normalized = window;
            if (normalized.endSeconds - normalized.startSeconds < 0.5) {
                normalized = window.copyEnd(Math.min(lastSecond, window.startSeconds + 0.5));
            }
            String key = String.format(Locale.US, "%.2f-%.2f", normalized.startSeconds, normalized.endSeconds);
            distinct.putIfAbsent(key, normalized);
        }
        return new ArrayList<>(distinct.values()).subList(0, Math.min(3, distinct.size()));
    }

    static String packetRoleLabel(PacketRole role) {
        switch (role) {
            case WEIGHT: return "weight";
            case CAPABILITIES: return "capabilities";
            case BATTERY: return "battery";
            case COMMAND_ACK: return "commandAck";
            case UNKNOWN:
            default: return "unknown";
        }
    }

    static AndroidPacketSeverity packetSeverity(String role, String rejectionReason, Double intervalMs, double thresholdMs) {
        if (rejectionReason != null) return AndroidPacketSeverity.PENALTY;
        if (intervalMs != null && intervalMs >= thresholdMs * 0.66) return AndroidPacketSeverity.WARNING;
        switch (role.toLowerCase(Locale.ROOT)) {
            case "battery":
            case "capabilities":
            case "commandack":
            case "compatibility":
                return AndroidPacketSeverity.INFO;
            case "unknown":
                return AndroidPacketSeverity.WARNING;
            default:
                return AndroidPacketSeverity.NORMAL;
        }
    }

    static AndroidPacketLane packetLane(String role, AndroidPacketSeverity severity) {
        if (severity == AndroidPacketSeverity.PENALTY) return AndroidPacketLane.PENALTY;
        switch (role.toLowerCase(Locale.ROOT)) {
            case "weight": return AndroidPacketLane.WEIGHT;
            case "battery": return AndroidPacketLane.METADATA;
            case "compatibility": return AndroidPacketLane.METADATA;
            case "capabilities":
            case "commandack":
                return AndroidPacketLane.CONTROL;
            default: return AndroidPacketLane.UNKNOWN;
        }
    }

    private static double chartReferenceTime(ScaleRecording recording) {
        if (recording.recordingStartMonotonicSeconds != null) {
            return recording.recordingStartMonotonicSeconds;
        }
        Double first = null;
        for (RawScalePacket packet : recording.rawPackets) {
            if (first == null || packet.monotonicSeconds < first) first = packet.monotonicSeconds;
        }
        for (ScaleSample sample : recording.samples) {
            if (first == null || sample.monotonicSeconds < first) first = sample.monotonicSeconds;
        }
        return first == null ? 0.0 : first;
    }

    private static List<ChartPoint> sampleChartPoints(List<ScaleSample> inputSamples, double referenceTime) {
        List<ScaleSample> samples = new ArrayList<>(inputSamples);
        samples.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        List<ChartPoint> points = new ArrayList<>();
        for (ScaleSample sample : samples) points.add(new ChartPoint(sample.monotonicSeconds - referenceTime, sample.weightGrams));
        return points;
    }

    private static List<ChartPoint> flowChartPoints(List<ScaleSample> inputSamples, double referenceTime) {
        List<ScaleSample> samples = new ArrayList<>(inputSamples);
        samples.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        List<ChartPoint> points = new ArrayList<>();
        for (ScaleSample sample : samples) {
            if (sample.flowGramsPerSecond != null) {
                points.add(new ChartPoint(sample.monotonicSeconds - referenceTime, sample.flowGramsPerSecond));
            }
        }
        return points;
    }

    private static List<AndroidSampleInterval> sampleIntervalEntries(
            List<ScaleSample> samples,
            double firstReference,
            double thresholdMs,
            Double recordingStart,
            Double recordingEnd
    ) {
        List<AndroidSampleInterval> intervals = new ArrayList<>();
        int boundaryIndexOffset = recordingStart == null ? 0 : 1;
        if (recordingStart != null && !samples.isEmpty()) {
            addSampleInterval(intervals, 0, recordingStart, samples.get(0).monotonicSeconds, firstReference, thresholdMs);
        }
        for (int index = 1; index < samples.size(); index++) {
            ScaleSample previous = samples.get(index - 1);
            ScaleSample current = samples.get(index);
            addSampleInterval(intervals, index - 1 + boundaryIndexOffset, previous.monotonicSeconds, current.monotonicSeconds, firstReference, thresholdMs);
        }
        if (recordingEnd != null && !samples.isEmpty()) {
            addSampleInterval(
                    intervals,
                    Math.max(0, samples.size() - 1 + boundaryIndexOffset),
                    samples.get(samples.size() - 1).monotonicSeconds,
                    recordingEnd,
                    firstReference,
                    thresholdMs
            );
        } else if (recordingStart != null && recordingEnd != null && samples.isEmpty()) {
            addSampleInterval(intervals, 0, recordingStart, recordingEnd, firstReference, thresholdMs);
        }
        return intervals;
    }

    private static void addSampleInterval(
            List<AndroidSampleInterval> intervals,
            int index,
            double previousTime,
            double currentTime,
            double firstReference,
            double thresholdMs
    ) {
        if (currentTime <= previousTime) return;
        double intervalMs = (currentTime - previousTime) * 1000.0;
        intervals.add(new AndroidSampleInterval(
                index,
                previousTime - firstReference,
                currentTime - firstReference,
                intervalMs,
                intervalSeverity(intervalMs, thresholdMs)
        ));
    }

    private static List<AndroidScoringGap> gapsFromIntervals(List<AndroidSampleInterval> intervals) {
        List<AndroidScoringGap> gaps = new ArrayList<>();
        for (AndroidSampleInterval interval : intervals) {
            if (interval.severity == AndroidPacketSeverity.PENALTY) {
                gaps.add(new AndroidScoringGap(
                        interval.index,
                        interval.previousRelativeSeconds,
                        interval.relativeSeconds,
                        interval.intervalMs
                ));
            }
        }
        return gaps;
    }

    private static AndroidPacketSeverity intervalSeverity(double intervalMs, double thresholdMs) {
        if (intervalMs >= thresholdMs) return AndroidPacketSeverity.PENALTY;
        if (intervalMs >= thresholdMs * 0.66) return AndroidPacketSeverity.WARNING;
        return AndroidPacketSeverity.NORMAL;
    }

    static List<String> packetEvidence(String role, String rejectionReason, Double intervalMs, double thresholdMs) {
        List<String> evidence = new ArrayList<>();
        if (rejectionReason != null) {
            evidence.add("Rejected by parser: " + rejectionReason + ". This directly lowers transport quality.");
        }
        if (intervalMs != null && intervalMs >= thresholdMs) {
            evidence.add("Raw packet interval before this packet: " + String.format(Locale.US, "%.0f ms", intervalMs) + ". Scoring uses parsed sample intervals; see the cadence chart for direct gap penalties.");
        } else if (intervalMs != null && intervalMs >= thresholdMs * 0.66) {
            evidence.add("Near-threshold raw packet interval before this packet: " + String.format(Locale.US, "%.0f ms", intervalMs) + ". Warning only.");
        }
        switch (role.toLowerCase(Locale.ROOT)) {
            case "compatibility":
                evidence.add("Compatibility weight packet. Preserved for diagnostics, but excluded from the official benchmark stream because WMB+ 20-byte packets are also present.");
                break;
            case "unknown":
                evidence.add("Unknown packet role. Kept for diagnostics; may indicate unsupported protocol traffic.");
                break;
            case "battery":
                evidence.add("Battery/metadata packet. This can improve metadata coverage when parsed.");
                break;
            case "capabilities":
                evidence.add("Capability packet. Useful context for WMB+ features and parser behavior.");
                break;
            case "commandack":
                evidence.add("Command acknowledgement packet. Useful context around tare/start/stop actions.");
                break;
            default:
                break;
        }
        if (evidence.isEmpty()) evidence.add("Normal parsed packet. No direct score penalty attached.");
        return evidence;
    }

    private static List<AndroidChartDeduction> chartDeductions(ScaleQualityMetrics metrics) {
        List<AndroidChartDeduction> result = new ArrayList<>();
        DeliveryQualityMetrics delivery = metrics.delivery;
        if (delivery != null && delivery.applicable && delivery.deliveryScore != null) {
            int lost = Math.max(0, 100 - delivery.deliveryScore);
            result.add(new AndroidChartDeduction(
                    AndroidChartProblemCategory.GAP,
                    "Delivery",
                    "Delivered packets and usable readings account for " + lost + " lost points.",
                    lost,
                    lost > 0 ? AndroidPacketSeverity.PENALTY : AndroidPacketSeverity.NORMAL
            ));
        }
        ScoringValidity validity = metrics.validity;
        if (validity != null && !validity.isValid) {
            result.add(new AndroidChartDeduction(
                    AndroidChartProblemCategory.VALIDITY,
                    "Validity",
                    String.join(", ", validity.reasons),
                    null,
                    AndroidPacketSeverity.PENALTY
            ));
        }
        FrameClassificationMetrics frames = metrics.frameClassification;
        if (frames != null) {
            int problems = frames.parseFailure + frames.outOfOrder + frames.stale + frames.duplicate + frames.implausible;
            if (problems > 0) {
                result.add(new AndroidChartDeduction(
                        AndroidChartProblemCategory.DIAGNOSTIC,
                        "Frame classification",
                        problems + " unusable or suspicious frame classes were observed.",
                        null,
                        AndroidPacketSeverity.WARNING
                ));
            }
        }
        return result;
    }

    private static AndroidSignalDiagnostics signalDiagnostics(ScaleRecording recording, List<ScaleSample> samples, ScaleQualityMetrics metrics) {
        if (recording.recordingEndMonotonicSeconds == null) {
            return new AndroidSignalDiagnostics(null, null, null);
        }
        return new AndroidSignalDiagnostics(
                flowValidation(samples),
                clockSkew(recording),
                packetCoalescing(metrics)
        );
    }

    private static AndroidFlowValidationDiagnostics flowValidation(List<ScaleSample> inputSamples) {
        List<ScaleSample> samples = strictlyIncreasingSamples(inputSamples);
        if (samples.size() < 5
                || samples.get(samples.size() - 1).monotonicSeconds - samples.get(0).monotonicSeconds < 1.0) {
            return null;
        }

        List<TimedValue> reported = new ArrayList<>();
        for (ScaleSample sample : samples) {
            if (sample.flowGramsPerSecond != null && Double.isFinite(sample.flowGramsPerSecond)) {
                reported.add(new TimedValue(sample.monotonicSeconds, sample.flowGramsPerSecond));
            }
        }
        if (reported.size() < 5) return null;

        double halfWindow = 0.5;
        List<TimedValue> derived = new ArrayList<>();
        for (ScaleSample sample : samples) {
            Double left = interpolatedWeight(sample.monotonicSeconds - halfWindow, samples);
            Double right = interpolatedWeight(sample.monotonicSeconds + halfWindow, samples);
            if (left != null && right != null) {
                derived.add(new TimedValue(sample.monotonicSeconds, (right - left) / (halfWindow * 2.0)));
            }
        }
        if (derived.size() < 5) return null;

        Double bestLag = null;
        Double bestCorrelation = null;
        for (int step = -20; step <= 20; step++) {
            double lag = step * 0.05;
            List<ValuePair> pairs = new ArrayList<>();
            for (TimedValue item : reported) {
                Double value = interpolatedValue(item.seconds - lag, derived);
                if (value != null) pairs.add(new ValuePair(item.value, value));
            }
            Double correlation = pearsonCorrelation(pairs);
            if (pairs.size() < 8 || correlation == null) continue;
            if (bestCorrelation == null
                    || correlation > bestCorrelation + 0.000_001
                    || (Math.abs(correlation - bestCorrelation) <= 0.000_001
                    && Math.abs(lag) < Math.abs(bestLag == null ? Double.POSITIVE_INFINITY : bestLag))) {
                bestCorrelation = correlation;
                bestLag = lag;
            }
        }

        if (bestCorrelation != null && bestCorrelation < 0.25) bestLag = null;
        double alignmentLag = bestLag == null ? 0.0 : bestLag;
        List<Double> errors = new ArrayList<>();
        for (TimedValue item : reported) {
            Double value = interpolatedValue(item.seconds - alignmentLag, derived);
            if (value != null) errors.add(Math.abs(item.value - value));
        }
        Double medianError = median(errors);
        if (errors.size() < 5 || medianError == null) return null;
        return new AndroidFlowValidationDiagnostics(
                errors.size(),
                medianError,
                bestLag == null ? null : bestLag * 1000.0,
                bestLag == null ? null : bestCorrelation
        );
    }

    private static AndroidClockSkewDiagnostics clockSkew(ScaleRecording recording) {
        List<ScaleSample> samples = new ArrayList<>(recording.samples);
        samples.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        ScaleKind kind = recording.device != null && recording.device.kind != null
                ? recording.device.kind
                : samples.isEmpty() || samples.get(0).scaleKind == null ? ScaleKind.UNKNOWN : samples.get(0).scaleKind;
        boolean supported = kind == ScaleKind.BOOKOO
                || kind == ScaleKind.BOOKOO_MINI
                || kind == ScaleKind.BOOKOO_ULTRA
                || kind == ScaleKind.WEIGH_MY_BRU_PLUS;
        if (!supported || (recording.protocolCapabilities != null
                && recording.protocolCapabilities.deviceClockSemantics == DeviceClockSemantics.SHOT_TIMER)) {
            return null;
        }

        double modulus = recording.protocolCapabilities != null
                && recording.protocolCapabilities.deviceClockModulus != null
                ? recording.protocolCapabilities.deviceClockModulus.doubleValue()
                : (double) (1L << 24);
        List<ValuePair> points = new ArrayList<>();
        Double previousRaw = null;
        Double previousUnwrapped = null;
        double offset = 0.0;
        for (ScaleSample sample : samples) {
            if (sample.deviceTimestampMilliseconds == null) continue;
            double raw = sample.deviceTimestampMilliseconds.doubleValue();
            if (previousRaw != null && raw < previousRaw) {
                if (previousRaw - raw > modulus / 2.0) offset += modulus;
                else continue;
            }
            double unwrapped = raw + offset;
            if (previousUnwrapped != null && unwrapped <= previousUnwrapped) continue;
            points.add(new ValuePair(sample.monotonicSeconds * 1000.0, unwrapped));
            previousRaw = raw;
            previousUnwrapped = unwrapped;
        }
        if (points.size() < 10 || points.get(points.size() - 1).x - points.get(0).x < 5000.0) return null;

        double meanHost = 0.0;
        double meanDevice = 0.0;
        for (ValuePair point : points) {
            meanHost += point.x;
            meanDevice += point.y;
        }
        meanHost /= points.size();
        meanDevice /= points.size();
        double numerator = 0.0;
        double denominator = 0.0;
        for (ValuePair point : points) {
            numerator += (point.x - meanHost) * (point.y - meanDevice);
            denominator += Math.pow(point.x - meanHost, 2.0);
        }
        if (denominator <= 0.0) return null;
        double skew = (numerator / denominator - 1.0) * 1_000_000.0;
        if (!Double.isFinite(skew)) return null;
        return new AndroidClockSkewDiagnostics(points.size(), skew);
    }

    private static AndroidPacketCoalescingDiagnostics packetCoalescing(ScaleQualityMetrics metrics) {
        if (metrics.delivery == null
                || !metrics.delivery.applicable
                || metrics.delivery.coverage == null
                || metrics.frameRateHz == null
                || metrics.delivery.coverage <= 0.0
                || metrics.frameRateHz < 0.0) {
            return null;
        }
        double servedSlotRate = metrics.delivery.coverage * 20.0;
        if (servedSlotRate <= 0.0) return null;
        return new AndroidPacketCoalescingDiagnostics(
                metrics.frameRateHz,
                servedSlotRate,
                metrics.frameRateHz / servedSlotRate
        );
    }

    private static List<ScaleSample> strictlyIncreasingSamples(List<ScaleSample> inputSamples) {
        List<ScaleSample> sorted = new ArrayList<>(inputSamples);
        sorted.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        List<ScaleSample> result = new ArrayList<>();
        for (ScaleSample sample : sorted) {
            if (!Double.isFinite(sample.monotonicSeconds) || !Double.isFinite(sample.weightGrams)) continue;
            if (!result.isEmpty()
                    && sample.monotonicSeconds <= result.get(result.size() - 1).monotonicSeconds) continue;
            result.add(sample);
        }
        return result;
    }

    private static Double interpolatedWeight(double time, List<ScaleSample> samples) {
        if (samples.isEmpty()
                || time < samples.get(0).monotonicSeconds
                || time > samples.get(samples.size() - 1).monotonicSeconds) return null;
        int low = 0;
        int high = samples.size() - 1;
        while (low <= high) {
            int middle = (low + high) / 2;
            ScaleSample sample = samples.get(middle);
            if (sample.monotonicSeconds == time) return sample.weightGrams;
            if (sample.monotonicSeconds < time) low = middle + 1;
            else high = middle - 1;
        }
        if (low <= 0 || low >= samples.size()) return null;
        ScaleSample before = samples.get(low - 1);
        ScaleSample after = samples.get(low);
        double span = after.monotonicSeconds - before.monotonicSeconds;
        if (span <= 0.0) return null;
        double fraction = (time - before.monotonicSeconds) / span;
        return before.weightGrams + (after.weightGrams - before.weightGrams) * fraction;
    }

    private static Double interpolatedValue(double time, List<TimedValue> points) {
        if (points.isEmpty() || time < points.get(0).seconds || time > points.get(points.size() - 1).seconds) return null;
        int low = 0;
        int high = points.size() - 1;
        while (low <= high) {
            int middle = (low + high) / 2;
            TimedValue point = points.get(middle);
            if (point.seconds == time) return point.value;
            if (point.seconds < time) low = middle + 1;
            else high = middle - 1;
        }
        if (low <= 0 || low >= points.size()) return null;
        TimedValue before = points.get(low - 1);
        TimedValue after = points.get(low);
        double span = after.seconds - before.seconds;
        if (span <= 0.0) return null;
        double fraction = (time - before.seconds) / span;
        return before.value + (after.value - before.value) * fraction;
    }

    private static Double pearsonCorrelation(List<ValuePair> pairs) {
        if (pairs.size() < 2) return null;
        double meanX = 0.0;
        double meanY = 0.0;
        for (ValuePair pair : pairs) {
            meanX += pair.x;
            meanY += pair.y;
        }
        meanX /= pairs.size();
        meanY /= pairs.size();
        double numerator = 0.0;
        double xVariance = 0.0;
        double yVariance = 0.0;
        for (ValuePair pair : pairs) {
            numerator += (pair.x - meanX) * (pair.y - meanY);
            xVariance += Math.pow(pair.x - meanX, 2.0);
            yVariance += Math.pow(pair.y - meanY, 2.0);
        }
        double denominator = Math.sqrt(xVariance * yVariance);
        return denominator > 0.0 ? numerator / denominator : null;
    }

    private static Double median(List<Double> values) {
        if (values.isEmpty()) return null;
        List<Double> sorted = new ArrayList<>(values);
        sorted.sort(Double::compareTo);
        int middle = sorted.size() / 2;
        if (sorted.size() % 2 == 0) return (sorted.get(middle - 1) + sorted.get(middle)) / 2.0;
        return sorted.get(middle);
    }

}

final class AndroidChartAnalysis {
    final List<ChartPoint> weightPoints;
    final List<ChartPoint> flowPoints;
    final AndroidPacketTimeline packetTimeline;
    final List<ChartWindow> problemWindows;
    final List<AndroidChartDeduction> deductionBreakdown;
    final AndroidSignalDiagnostics signalDiagnostics;

    AndroidChartAnalysis(
            List<ChartPoint> weightPoints,
            List<ChartPoint> flowPoints,
            AndroidPacketTimeline packetTimeline,
            List<ChartWindow> problemWindows,
            List<AndroidChartDeduction> deductionBreakdown,
            AndroidSignalDiagnostics signalDiagnostics
    ) {
        this.weightPoints = weightPoints;
        this.flowPoints = flowPoints;
        this.packetTimeline = packetTimeline;
        this.problemWindows = problemWindows;
        this.deductionBreakdown = deductionBreakdown;
        this.signalDiagnostics = signalDiagnostics;
    }
}

final class AndroidSignalDiagnostics {
    final AndroidFlowValidationDiagnostics flowValidation;
    final AndroidClockSkewDiagnostics clockSkew;
    final AndroidPacketCoalescingDiagnostics packetCoalescing;

    AndroidSignalDiagnostics(
            AndroidFlowValidationDiagnostics flowValidation,
            AndroidClockSkewDiagnostics clockSkew,
            AndroidPacketCoalescingDiagnostics packetCoalescing
    ) {
        this.flowValidation = flowValidation;
        this.clockSkew = clockSkew;
        this.packetCoalescing = packetCoalescing;
    }

    boolean isEmpty() {
        return flowValidation == null && clockSkew == null && packetCoalescing == null;
    }
}

final class AndroidFlowValidationDiagnostics {
    final int sampleCount;
    final double medianAbsoluteErrorGramsPerSecond;
    final Double lagMilliseconds;
    final Double correlation;

    AndroidFlowValidationDiagnostics(
            int sampleCount,
            double medianAbsoluteErrorGramsPerSecond,
            Double lagMilliseconds,
            Double correlation
    ) {
        this.sampleCount = sampleCount;
        this.medianAbsoluteErrorGramsPerSecond = medianAbsoluteErrorGramsPerSecond;
        this.lagMilliseconds = lagMilliseconds;
        this.correlation = correlation;
    }
}

final class AndroidClockSkewDiagnostics {
    final int sampleCount;
    final double skewPartsPerMillion;

    AndroidClockSkewDiagnostics(int sampleCount, double skewPartsPerMillion) {
        this.sampleCount = sampleCount;
        this.skewPartsPerMillion = skewPartsPerMillion;
    }
}

final class AndroidPacketCoalescingDiagnostics {
    final double observedFrameRateHz;
    final double servedSlotRateHz;
    final double framesPerServedSlot;

    AndroidPacketCoalescingDiagnostics(
            double observedFrameRateHz,
            double servedSlotRateHz,
            double framesPerServedSlot
    ) {
        this.observedFrameRateHz = observedFrameRateHz;
        this.servedSlotRateHz = servedSlotRateHz;
        this.framesPerServedSlot = framesPerServedSlot;
    }
}

final class TimedValue {
    final double seconds;
    final double value;

    TimedValue(double seconds, double value) {
        this.seconds = seconds;
        this.value = value;
    }
}

final class ValuePair {
    final double x;
    final double y;

    ValuePair(double x, double y) {
        this.x = x;
        this.y = y;
    }
}

final class ChartPoint {
    final double seconds;
    final double value;

    ChartPoint(double seconds, double value) {
        this.seconds = seconds;
        this.value = value;
    }
}

final class ChartWindow {
    final String title;
    final double startSeconds;
    final double endSeconds;
    final AndroidChartProblemCategory category;
    final AndroidPacketSeverity severity;
    final Integer relatedPacketIndex;

    ChartWindow(String title, double startSeconds, double endSeconds) {
        this(title, startSeconds, endSeconds, AndroidChartProblemCategory.DIAGNOSTIC, AndroidPacketSeverity.WARNING, null);
    }

    ChartWindow(
            String title,
            double startSeconds,
            double endSeconds,
            AndroidChartProblemCategory category,
            AndroidPacketSeverity severity,
            Integer relatedPacketIndex
    ) {
        this.title = title;
        this.startSeconds = startSeconds;
        this.endSeconds = endSeconds;
        this.category = category;
        this.severity = severity;
        this.relatedPacketIndex = relatedPacketIndex;
    }

    ChartWindow copyEnd(double endSeconds) {
        return new ChartWindow(title, startSeconds, endSeconds, category, severity, relatedPacketIndex);
    }
}

final class AndroidChartDeduction {
    final AndroidChartProblemCategory category;
    final String title;
    final String detail;
    final Integer pointsLost;
    final AndroidPacketSeverity severity;

    AndroidChartDeduction(
            AndroidChartProblemCategory category,
            String title,
            String detail,
            Integer pointsLost,
            AndroidPacketSeverity severity
    ) {
        this.category = category;
        this.title = title;
        this.detail = detail;
        this.pointsLost = pointsLost;
        this.severity = severity;
    }
}

enum AndroidChartProblemCategory {
    GAP,
    PARSE_FAILURE,
    OUT_OF_ORDER,
    STALE_CLOCK,
    DUPLICATE,
    IMPLAUSIBLE,
    DISCONNECT,
    VALIDITY,
    DIAGNOSTIC
}

final class AndroidPacketTimeline {
    final List<AndroidPacketTimelineEntry> entries;
    final List<AndroidScoringGap> scoringGaps;
    final double thresholdMs;
    final List<AndroidSampleInterval> sampleIntervals;
    final double recordingDurationSeconds;

    AndroidPacketTimeline(List<AndroidPacketTimelineEntry> entries, List<AndroidScoringGap> scoringGaps, double thresholdMs) {
        this(entries, scoringGaps, thresholdMs, new ArrayList<>(), 0.0);
    }

    AndroidPacketTimeline(
            List<AndroidPacketTimelineEntry> entries,
            List<AndroidScoringGap> scoringGaps,
            double thresholdMs,
            List<AndroidSampleInterval> sampleIntervals
    ) {
        this(entries, scoringGaps, thresholdMs, sampleIntervals, 0.0);
    }

    AndroidPacketTimeline(
            List<AndroidPacketTimelineEntry> entries,
            List<AndroidScoringGap> scoringGaps,
            double thresholdMs,
            List<AndroidSampleInterval> sampleIntervals,
            double recordingDurationSeconds
    ) {
        this.entries = entries;
        this.scoringGaps = scoringGaps;
        this.thresholdMs = thresholdMs;
        this.sampleIntervals = sampleIntervals;
        this.recordingDurationSeconds = recordingDurationSeconds;
    }

    double getDurationSeconds() {
        double entryEnd = entries.isEmpty() ? 0.0 : entries.get(entries.size() - 1).relativeSeconds;
        double sampleEnd = sampleIntervals.isEmpty()
                ? (scoringGaps.isEmpty() ? 0.0 : scoringGaps.get(scoringGaps.size() - 1).endSeconds)
                : sampleIntervals.get(sampleIntervals.size() - 1).relativeSeconds;
        return Math.max(recordingDurationSeconds, Math.max(entryEnd, sampleEnd));
    }

    int getWarningCount() {
        int count = 0;
        for (AndroidPacketTimelineEntry entry : entries) if (entry.severity == AndroidPacketSeverity.WARNING) count++;
        for (AndroidSampleInterval interval : sampleIntervals) if (interval.severity == AndroidPacketSeverity.WARNING) count++;
        return count;
    }
}

final class AndroidPacketTimelineEntry {
    final int id;
    final double relativeSeconds;
    final Double previousRelativeSeconds;
    final Double intervalMs;
    final String roleLabel;
    final String bytesHex;
    final String characteristicUuid;
    final String rejectionReason;
    final Integer sequence;
    final Double weightGrams;
    final AndroidPacketSeverity severity;
    final AndroidPacketLane lane;
    final List<String> evidence;
    final List<PacketFieldAnnotation> fields;

    AndroidPacketTimelineEntry(
            int id,
            double relativeSeconds,
            Double previousRelativeSeconds,
            Double intervalMs,
            String roleLabel,
            String bytesHex,
            String characteristicUuid,
            String rejectionReason,
            Integer sequence,
            Double weightGrams,
            AndroidPacketSeverity severity,
            AndroidPacketLane lane,
            List<String> evidence,
            List<PacketFieldAnnotation> fields
    ) {
        this.id = id;
        this.relativeSeconds = relativeSeconds;
        this.previousRelativeSeconds = previousRelativeSeconds;
        this.intervalMs = intervalMs;
        this.roleLabel = roleLabel;
        this.bytesHex = bytesHex;
        this.characteristicUuid = characteristicUuid;
        this.rejectionReason = rejectionReason;
        this.sequence = sequence;
        this.weightGrams = weightGrams;
        this.severity = severity;
        this.lane = lane;
        this.evidence = evidence;
        this.fields = fields;
    }
}

final class AndroidSampleInterval {
    final int index;
    final double previousRelativeSeconds;
    final double relativeSeconds;
    final double intervalMs;
    final AndroidPacketSeverity severity;

    AndroidSampleInterval(
            int index,
            double previousRelativeSeconds,
            double relativeSeconds,
            double intervalMs,
            AndroidPacketSeverity severity
    ) {
        this.index = index;
        this.previousRelativeSeconds = previousRelativeSeconds;
        this.relativeSeconds = relativeSeconds;
        this.intervalMs = intervalMs;
        this.severity = severity;
    }
}

final class AndroidScoringGap {
    final int index;
    final double startSeconds;
    final double endSeconds;
    final double intervalMs;

    AndroidScoringGap(int index, double startSeconds, double endSeconds, double intervalMs) {
        this.index = index;
        this.startSeconds = startSeconds;
        this.endSeconds = endSeconds;
        this.intervalMs = intervalMs;
    }
}

enum AndroidPacketSeverity {
    NORMAL("normal"),
    INFO("metadata/control"),
    WARNING("warning"),
    PENALTY("score penalty");

    final String label;

    AndroidPacketSeverity(String label) {
        this.label = label;
    }
}

enum AndroidPacketLane {
    WEIGHT(0),
    METADATA(1),
    CONTROL(2),
    PENALTY(3),
    UNKNOWN(4);

    final int index;

    AndroidPacketLane(int index) {
        this.index = index;
    }
}
