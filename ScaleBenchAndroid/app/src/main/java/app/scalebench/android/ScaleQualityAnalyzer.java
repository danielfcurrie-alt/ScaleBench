package app.scalebench.android;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

final class ScaleQualityAnalyzer {
    private ScaleQualityAnalyzer() {
    }

    static ScaleQualityMetrics analyze(ScaleRecording recording) {
        ScoringProfile profile = recording.scoringProfile.normalized();
        List<ScaleSample> samples = recording.samples;
        int rejected = 0;
        for (RawScalePacket packet : recording.rawPackets) {
            if (packet.rejectionReason != null) rejected++;
        }

        List<Integer> batteryValues = new ArrayList<>();
        for (ScaleSample sample : samples) {
            if (sample.batteryPercent != null && sample.batteryPercent >= 0 && sample.batteryPercent <= 100) {
                batteryValues.add(sample.batteryPercent);
            }
        }
        for (ScaleBatteryEvent event : recording.batteryEvents) {
            if (event.percent >= 0 && event.percent <= 100) batteryValues.add(event.percent);
        }

        List<Integer> firmwareQuality = new ArrayList<>();
        for (ScaleSample sample : samples) {
            if (sample.firmwareQualityScore != null && sample.firmwareQualityScore >= 0 && sample.firmwareQualityScore <= 100) {
                firmwareQuality.add(sample.firmwareQualityScore);
            }
        }

        int bumpCount = firmwareBumpEventCount(samples);
        if (samples.size() < 2) {
            ScaleQualityMetrics metrics = ScaleQualityMetrics.empty();
            metrics.rejectedPacketCount = rejected;
            metrics.batteryMinPercent = minInt(batteryValues);
            metrics.batteryMaxPercent = maxInt(batteryValues);
            metrics.firmwareQualityAverage = averageInt(firmwareQuality);
            metrics.firmwareBumpCount = bumpCount;
            return metrics;
        }

        List<Double> intervals = sampleIntervalsMilliseconds(samples);
        Double p50 = percentile(intervals, 0.50);
        Double p95 = percentile(intervals, 0.95);
        Double maxInterval = intervals.isEmpty() ? null : Collections.max(intervals);
        double duration = samples.get(samples.size() - 1).monotonicSeconds - samples.get(0).monotonicSeconds;
        Double effectiveRate = duration > 0 ? (samples.size() - 1) / duration : null;
        double longGapThreshold = longGapThresholdMilliseconds(p50, profile);
        int longGaps = 0;
        for (double interval : intervals) if (interval >= longGapThreshold) longGaps++;
        int missingSequence = missingSequenceCount(samples);
        int timestampIssues = duplicateOrOutOfOrderDeviceTimestamps(samples);

        List<Double> weights = new ArrayList<>();
        for (ScaleSample sample : samples) weights.add(sample.weightGrams);
        Double noisePeakToPeak = weights.isEmpty() ? null : Collections.max(weights) - Collections.min(weights);
        Double standardDeviation = standardDeviation(weights);
        Double drift = driftGramsPerMinute(samples);

        int transportScore = scoreTransport(longGaps, missingSequence, timestampIssues, rejected, samples.size(), profile);
        int stabilityScore = recording.mode == RecordingMode.IDLE_STABILITY
                ? scoreIdleStability(noisePeakToPeak, standardDeviation, drift, profile)
                : scoreDynamicStability(bumpCount);
        int validBatteryEventCount = 0;
        for (ScaleBatteryEvent event : recording.batteryEvents) if (event.percent >= 0 && event.percent <= 100) validBatteryEventCount++;
        int metadataScore = scoreMetadata(samples, validBatteryEventCount);
        int overall = (int) Math.round(transportScore * profile.transportWeight
                + stabilityScore * profile.stabilityWeight
                + metadataScore * profile.metadataWeight);
        overall = Math.min(100, Math.max(0, overall));

        ScaleQualityMetrics metrics = new ScaleQualityMetrics();
        metrics.overallScore = overall;
        metrics.transportScore = transportScore;
        metrics.stabilityScore = stabilityScore;
        metrics.metadataScore = metadataScore;
        metrics.effectiveSampleRateHz = effectiveRate;
        metrics.packetIntervalP50Milliseconds = p50;
        metrics.packetIntervalP95Milliseconds = p95;
        metrics.packetIntervalMaxMilliseconds = maxInterval;
        metrics.longGapCount = longGaps;
        metrics.missingSequenceCount = missingSequence;
        metrics.duplicateOrOutOfOrderTimestampCount = timestampIssues;
        metrics.rejectedPacketCount = rejected;
        metrics.idleNoisePeakToPeakGrams = recording.mode == RecordingMode.IDLE_STABILITY ? noisePeakToPeak : null;
        metrics.idleNoiseStandardDeviationGrams = recording.mode == RecordingMode.IDLE_STABILITY ? standardDeviation : null;
        metrics.driftGramsPerMinute = recording.mode == RecordingMode.IDLE_STABILITY ? drift : null;
        metrics.batteryMinPercent = minInt(batteryValues);
        metrics.batteryMaxPercent = maxInt(batteryValues);
        metrics.firmwareQualityAverage = averageInt(firmwareQuality);
        metrics.firmwareBumpCount = bumpCount;
        return metrics;
    }

    private static List<Double> sampleIntervalsMilliseconds(List<ScaleSample> samples) {
        List<Double> intervals = new ArrayList<>();
        for (int i = 1; i < samples.size(); i++) {
            ScaleSample previous = samples.get(i - 1);
            ScaleSample current = samples.get(i);
            if (previous.deviceTimestampMilliseconds != null
                    && current.deviceTimestampMilliseconds != null
                    && previous.scaleKind == current.scaleKind) {
                intervals.add((double) deviceTimestampDelta(previous.deviceTimestampMilliseconds, current.deviceTimestampMilliseconds, current.scaleKind));
            } else {
                intervals.add(Math.max(0, current.monotonicSeconds - previous.monotonicSeconds) * 1000.0);
            }
        }
        return intervals;
    }

    private static double longGapThresholdMilliseconds(Double typicalInterval, ScoringProfile profile) {
        if (typicalInterval == null || typicalInterval <= 0) return profile.minimumLongGapMilliseconds;
        return Math.max(profile.minimumLongGapMilliseconds, typicalInterval * profile.longGapMultiplier);
    }

    private static int missingSequenceCount(List<ScaleSample> samples) {
        int count = 0;
        for (int i = 1; i < samples.size(); i++) {
            Integer previous = samples.get(i - 1).sequence;
            Integer current = samples.get(i).sequence;
            if (previous == null || current == null) continue;
            int delta = (current - previous) & 0xFF;
            if (delta > 1 && delta <= 127) count += delta - 1;
        }
        return count;
    }

    private static int duplicateOrOutOfOrderDeviceTimestamps(List<ScaleSample> samples) {
        int count = 0;
        for (int i = 1; i < samples.size(); i++) {
            ScaleSample previous = samples.get(i - 1);
            ScaleSample current = samples.get(i);
            if (previous.deviceTimestampMilliseconds == null
                    || current.deviceTimestampMilliseconds == null
                    || previous.scaleKind != current.scaleKind) continue;
            long delta = deviceTimestampDelta(previous.deviceTimestampMilliseconds, current.deviceTimestampMilliseconds, current.scaleKind);
            if (delta == 0 || delta > deviceTimestampHalfRange(current.scaleKind)) count++;
        }
        return count;
    }

    private static long deviceTimestampDelta(long previous, long current, ScaleKind kind) {
        if (!uses24BitDeviceTimestamp(kind)) return (current - previous) & 0xFFFF_FFFFL;
        long mask = 0x00FF_FFFFL;
        return ((current & mask) - (previous & mask)) & mask;
    }

    private static long deviceTimestampHalfRange(ScaleKind kind) {
        return uses24BitDeviceTimestamp(kind) ? 0x007F_FFFFL : 0x7FFF_FFFFL;
    }

    private static boolean uses24BitDeviceTimestamp(ScaleKind kind) {
        return kind == ScaleKind.BOOKOO
                || kind == ScaleKind.BOOKOO_MINI
                || kind == ScaleKind.BOOKOO_ULTRA
                || kind == ScaleKind.WEIGH_MY_BRU_PLUS;
    }

    private static Double percentile(List<Double> values, double p) {
        if (values.isEmpty()) return null;
        List<Double> sorted = new ArrayList<>(values);
        Collections.sort(sorted);
        int index = Math.min(sorted.size() - 1, Math.max(0, (int) Math.round((sorted.size() - 1) * p)));
        return sorted.get(index);
    }

    private static Double standardDeviation(List<Double> values) {
        if (values.size() < 2) return null;
        double mean = 0;
        for (double value : values) mean += value;
        mean /= values.size();
        double variance = 0;
        for (double value : values) variance += Math.pow(value - mean, 2);
        variance /= values.size() - 1;
        return Math.sqrt(variance);
    }

    private static Double driftGramsPerMinute(List<ScaleSample> samples) {
        ScaleSample first = samples.get(0);
        ScaleSample last = samples.get(samples.size() - 1);
        double minutes = (last.monotonicSeconds - first.monotonicSeconds) / 60.0;
        if (minutes <= 0) return null;
        return (last.weightGrams - first.weightGrams) / minutes;
    }

    private static int firmwareBumpEventCount(List<ScaleSample> samples) {
        int count = 0;
        boolean bumpIsActive = false;
        for (ScaleSample sample : samples) {
            boolean hasBump = sample.diagnosticFlags != null && sample.diagnosticFlags.recentBump;
            if (hasBump && !bumpIsActive) count++;
            bumpIsActive = hasBump;
        }
        return count;
    }

    private static int scoreTransport(int longGaps, int missingSequence, int timestampIssues, int rejected, int sampleCount, ScoringProfile profile) {
        int score = 100;
        score -= cappedPenalty(longGaps, profile.longGapPenalty, 40);
        score -= cappedPenalty(missingSequence, profile.missingSequencePenalty, 30);
        score -= cappedPenalty(timestampIssues, profile.timestampIssuePenalty, 20);
        int parseAttemptCount = Math.max(sampleCount + rejected, 1);
        score -= Math.min(30, (int) Math.round((double) rejected / parseAttemptCount * profile.rejectedPacketRatePenaltyScale));
        return Math.max(0, score);
    }

    private static int scoreIdleStability(Double noisePeakToPeak, Double standardDeviation, Double drift, ScoringProfile profile) {
        int score = 100;
        if (noisePeakToPeak != null) {
            score -= Math.min(35, (int) Math.round(Math.max(0, noisePeakToPeak - profile.idleNoiseFreePeakToPeakGrams) * profile.idleNoisePeakToPeakPenaltyScale));
        }
        if (standardDeviation != null) {
            score -= Math.min(35, (int) Math.round(Math.max(0, standardDeviation - profile.idleStandardDeviationFreeGrams) * profile.idleStandardDeviationPenaltyScale));
        }
        if (drift != null) {
            score -= Math.min(30, (int) Math.round(Math.abs(drift) * profile.driftPenaltyScale));
        }
        return Math.max(0, score);
    }

    private static int scoreDynamicStability(int bumpCount) {
        return Math.max(0, 100 - Math.min(50, bumpCount * 10));
    }

    private static int scoreMetadata(List<ScaleSample> samples, int batteryEventCount) {
        boolean hasTimestamp = false;
        boolean hasBattery = batteryEventCount > 0;
        boolean hasFlow = false;
        boolean hasQuality = false;
        for (ScaleSample sample : samples) {
            hasTimestamp |= sample.deviceTimestampMilliseconds != null;
            hasBattery |= sample.batteryPercent != null;
            hasFlow |= sample.flowGramsPerSecond != null;
            hasQuality |= sample.firmwareQualityScore != null;
        }
        int score = 0;
        if (hasTimestamp) score += 35;
        if (hasBattery) score += 25;
        if (hasFlow) score += 20;
        if (hasQuality) score += 20;
        return score;
    }

    private static int cappedPenalty(int count, int unit, int cap) {
        return Math.min(cap, Math.max(0, count) * Math.max(0, unit));
    }

    private static Integer minInt(List<Integer> values) {
        return values.isEmpty() ? null : Collections.min(values);
    }

    private static Integer maxInt(List<Integer> values) {
        return values.isEmpty() ? null : Collections.max(values);
    }

    private static Double averageInt(List<Integer> values) {
        if (values.isEmpty()) return null;
        double total = 0;
        for (int value : values) total += value;
        return total / values.size();
    }
}

