package app.scalebench.android;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class ScaleQualityAnalyzer {
    static final String SCORING_MODEL_VERSION = ScaleRecording.SCORING_MODEL_VERSION;

    private static final double SLOT_MILLISECONDS = 50.0;
    private static final double SLOT_EPSILON = 1e-9;
    private static final double IMPULSE_DEVIATION_GRAMS = 0.5;
    private static final double MAX_PHYSICAL_FLOW_GRAMS_PER_SECOND = 25.0;
    private static final double FLOW_WINDOW_SECONDS = 1.0;
    private static final double MINIMUM_RESOLUTION_GRAMS = 0.01;
    private static final double MINIMUM_DUPLICATE_TOLERANCE_GRAMS = 0.005;
    private static final double IDLE_SETTLING_SECONDS = 5.0;
    private static final double STEP_BASELINE_WINDOW_SECONDS = 2.0;
    private static final double STEP_FINAL_WINDOW_SECONDS = 2.0;

    private enum FrameClass {
        USABLE, PARSE_FAILURE, OUT_OF_ORDER, STALE, DUPLICATE, IMPLAUSIBLE
    }

    private static final class ScoringFrame {
        double monotonicSeconds;
        boolean weight;
        boolean parseFailed;
        Double weightGrams;
        Long sequence;
        Long deviceTimestampMilliseconds;
        long usbDroppedDelta;
    }

    private static final class SamplePoint {
        double monotonicSeconds;
        double weightGrams;

        SamplePoint(double monotonicSeconds, double weightGrams) {
            this.monotonicSeconds = monotonicSeconds;
            this.weightGrams = weightGrams;
        }
    }

    private static final class ClassifiedFrames {
        List<ScoringFrame> frames;
        List<FrameClass> classes;
        double resolutionGrams;
    }

    private static final class CoverageResult {
        double coverage;
        double purity;
        int slotCount;
        int servedSlots;
        double longestUnservedRunMilliseconds;
    }

    private static final class IdleResult {
        Integer score;
        Integer noiseScore;
        Integer driftScore;
        int analysedSampleCount;
        Double residualStandardDeviationGrams;
        Double residualPeakToPeakGrams;
        Double driftGramsPerMinute;
        Double resolutionGrams;
    }

    private ScaleQualityAnalyzer() {
    }

    static ScaleQualityMetrics analyze(ScaleRecording recording) {
        ScoringProfile scoringProfile = recording.scoringProfile == null
                ? ScoringProfile.standard()
                : recording.scoringProfile.normalized();
        List<ScoringFrame> allFrames = scoringFrames(recording);
        Double explicitStart = recording.recordingStartMonotonicSeconds;
        Double explicitEnd = recording.recordingEndMonotonicSeconds;
        boolean boundariesPresent = explicitStart != null && explicitEnd != null && explicitEnd > explicitStart;
        double recordingStart = explicitStart != null ? explicitStart : minimumFrameTime(allFrames, 0.0);
        double recordingEnd = explicitEnd != null ? explicitEnd : maximumFrameTime(allFrames, recordingStart);

        List<ScoringFrame> boundedFrames = new ArrayList<>();
        for (ScoringFrame frame : allFrames) {
            if (frame.monotonicSeconds >= recordingStart && frame.monotonicSeconds < recordingEnd) {
                boundedFrames.add(frame);
            }
        }
        ProtocolScoringCapabilities capabilities = recording.protocolCapabilities != null
                ? recording.protocolCapabilities
                : inferredProtocolCapabilities(recording, boundedFrames);
        ClassifiedFrames classified = classifyFrames(boundedFrames, recording.mode, capabilities);
        long usbDroppedFrameCount = 0;
        for (ScoringFrame frame : classified.frames) {
            usbDroppedFrameCount = saturatingAdd(usbDroppedFrameCount, frame.usbDroppedDelta);
        }
        List<SamplePoint> usableSamples = new ArrayList<>();
        for (int i = 0; i < classified.frames.size(); i++) {
            ScoringFrame frame = classified.frames.get(i);
            if (classified.classes.get(i) == FrameClass.USABLE && frame.weightGrams != null) {
                usableSamples.add(new SamplePoint(frame.monotonicSeconds, frame.weightGrams));
            }
        }

        ScoringValidity validity = evaluateValidity(
                recording.mode, recordingStart, recordingEnd, boundariesPresent, usableSamples, recording.events
        );
        CoverageResult coverage = coverageAndPurity(
                classified.frames, classified.classes, recordingStart, recordingEnd, usbDroppedFrameCount
        );
        FrameClassificationMetrics counts = frameClassification(classified.classes);
        int relevantFrameCount = classified.frames.size();
        boolean unreconstructable = relevantFrameCount > 0
                && (double) counts.implausible / relevantFrameCount > 0.30;
        boolean deliveryMode = recording.mode == RecordingMode.SHOT
                || recording.mode == RecordingMode.TRANSPORT_STRESS;
        Integer deliveryScore = null;
        if (deliveryMode && validity.isValid && coverage != null) {
            deliveryScore = clampedScore(100 * coverage.coverage * coverage.purity);
        }
        ProtocolVerificationMetrics verification = protocolVerification(
                boundedFrames, capabilities, recording.mode
        );

        List<Double> intervals = new ArrayList<>();
        for (int i = 1; i < classified.frames.size(); i++) {
            intervals.add((classified.frames.get(i).monotonicSeconds
                    - classified.frames.get(i - 1).monotonicSeconds) * 1000);
        }
        List<Double> sortedIntervals = new ArrayList<>(intervals);
        Collections.sort(sortedIntervals);
        Double p25 = percentile(sortedIntervals, 0.25);
        Double p50 = percentile(sortedIntervals, 0.50);
        Double p75 = percentile(sortedIntervals, 0.75);
        Double p95 = percentile(sortedIntervals, 0.95);
        Double intervalMax = intervals.isEmpty() ? null : Collections.max(intervals);
        double span = Math.max(0, recordingEnd - recordingStart);
        double sampleSpan = usableSamplesSampleSpan(usableSamples);
        IdleResult idle = recording.mode == RecordingMode.IDLE_STABILITY
                ? idleStability(usableSamples, recordingStart)
                : null;
        Integer idleScore = validity.isValid && idle != null ? idle.score : null;
        StepResponseMetrics step = recording.mode == RecordingMode.STEP_RESPONSE
                ? stepResponse(usableSamples, recordingStart, recordingEnd)
                : null;

        List<Integer> batteryValues = new ArrayList<>();
        List<Integer> firmwareQuality = new ArrayList<>();
        for (ScaleSample sample : recording.samples) {
            if (sample.batteryPercent != null && sample.batteryPercent >= 0 && sample.batteryPercent <= 100) {
                batteryValues.add(sample.batteryPercent);
            }
            if (sample.firmwareQualityScore != null
                    && sample.firmwareQualityScore >= 0 && sample.firmwareQualityScore <= 100) {
                firmwareQuality.add(sample.firmwareQualityScore);
            }
        }
        for (ScaleBatteryEvent event : recording.batteryEvents) {
            if (event.percent >= 0 && event.percent <= 100) batteryValues.add(event.percent);
        }
        double longGapThreshold = longGapThresholdMilliseconds(p50, scoringProfile);
        int longGapCount = 0;
        for (double interval : intervals) if (interval >= longGapThreshold) longGapCount++;

        ScaleQualityMetrics metrics = new ScaleQualityMetrics();
        metrics.overallScore = deliveryMode ? deliveryScore : idleScore;
        metrics.transportScore = deliveryMode ? deliveryScore : null;
        metrics.stabilityScore = recording.mode == RecordingMode.IDLE_STABILITY ? idleScore : null;
        metrics.metadataScore = verification.verificationCoveragePercent;
        metrics.effectiveSampleRateHz = sampleSpan > 0 ? usableSamples.size() / sampleSpan : null;
        metrics.packetIntervalP50Milliseconds = rounded6(p50);
        metrics.packetIntervalP95Milliseconds = rounded6(p95);
        metrics.packetIntervalMaxMilliseconds = rounded6(intervalMax);
        metrics.longGapCount = longGapCount;
        metrics.missingSequenceCount = Math.max(
                missingSequenceCount(classified.frames, capabilities.sequenceModulus),
                saturatingInt(usbDroppedFrameCount)
        );
        metrics.duplicateOrOutOfOrderTimestampCount = counts.stale;
        metrics.rejectedPacketCount = counts.parseFailure;
        metrics.idleNoisePeakToPeakGrams = idle == null ? null : idle.residualPeakToPeakGrams;
        metrics.idleNoiseStandardDeviationGrams = idle == null ? null : idle.residualStandardDeviationGrams;
        metrics.driftGramsPerMinute = idle == null ? null : idle.driftGramsPerMinute;
        metrics.batteryMinPercent = batteryValues.isEmpty() ? null : Collections.min(batteryValues);
        metrics.batteryMaxPercent = batteryValues.isEmpty() ? null : Collections.max(batteryValues);
        metrics.firmwareQualityAverage = average(firmwareQuality);
        metrics.firmwareBumpCount = firmwareBumpEventCount(recording.samples);
        metrics.scoringModelVersion = SCORING_MODEL_VERSION;
        metrics.scoringProfileName = scoringProfile.name;
        metrics.validity = validity;
        metrics.delivery = new DeliveryQualityMetrics();
        metrics.delivery.applicable = deliveryMode;
        metrics.delivery.deliveryScore = deliveryScore;
        metrics.delivery.coverage = deliveryMode && coverage != null ? rounded6(coverage.coverage) : null;
        metrics.delivery.purity = deliveryMode && coverage != null ? rounded6(coverage.purity) : null;
        metrics.delivery.purityIsUpperBound = deliveryMode ? verification.purityIsUpperBound : null;
        metrics.frameClassification = counts;
        metrics.protocolVerification = verification;
        metrics.signalUnreconstructable = unreconstructable;
        metrics.relevantWeightFrameCount = relevantFrameCount;
        metrics.excludedFrameCount = allFrames.size() - relevantFrameCount;
        metrics.usableSampleCount = usableSamples.size();
        metrics.recordingSpanSeconds = rounded6(span);
        metrics.recordingBoundaryInferred = !boundariesPresent;
        metrics.frameRateHz = span > 0 ? rounded6(relevantFrameCount / span) : null;
        metrics.usableRateHz = sampleSpan > 0 ? rounded6(usableSamples.size() / sampleSpan) : null;
        metrics.estimatedResolutionGrams = rounded6(classified.resolutionGrams);
        metrics.slotCount = coverage == null ? null : coverage.slotCount;
        metrics.servedSlots = coverage == null ? null : coverage.servedSlots;
        metrics.longestUnservedRunMilliseconds = coverage == null
                ? null : rounded6(coverage.longestUnservedRunMilliseconds);
        if (p25 != null && p50 != null && p75 != null && p50 > 0) {
            metrics.robustCoefficientOfVariation = rounded6((p75 - p25) / p50);
        }
        int disconnectCount = 0;
        for (ScaleRecordingEvent event : recording.events) {
            if (event.type == RecordingEventType.DISCONNECT) disconnectCount++;
        }
        metrics.disconnectCount = disconnectCount;
        metrics.idleNoiseScore = idle == null ? null : idle.noiseScore;
        metrics.idleDriftScore = idle == null ? null : idle.driftScore;
        metrics.idleAnalysedSampleCount = idle == null ? null : idle.analysedSampleCount;
        metrics.idleResolutionGrams = idle == null ? null : idle.resolutionGrams;
        metrics.stepResponse = step;
        return metrics;
    }

    static double longGapThresholdMilliseconds(List<ScaleSample> samples, ScoringProfile profile) {
        List<Double> intervals = new ArrayList<>();
        List<ScaleSample> sorted = new ArrayList<>(samples);
        sorted.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        for (int index = 1; index < sorted.size(); index++) {
            intervals.add(Math.max(0, (sorted.get(index).monotonicSeconds - sorted.get(index - 1).monotonicSeconds) * 1000.0));
        }
        Double typicalInterval = percentile(intervals, 0.50);
        return longGapThresholdMilliseconds(typicalInterval, profile);
    }

    private static double longGapThresholdMilliseconds(Double typicalInterval, ScoringProfile profile) {
        double minimum = profile == null ? 300.0 : profile.minimumLongGapMilliseconds;
        double multiplier = profile == null ? 3.0 : profile.longGapMultiplier;
        return typicalInterval == null || typicalInterval <= 0
                ? minimum
                : Math.max(minimum, typicalInterval * multiplier);
    }

    private static List<ScoringFrame> scoringFrames(ScaleRecording recording) {
        List<ScoringFrame> result = new ArrayList<>();
        if (!recording.rawPackets.isEmpty()) {
            List<ScaleSample> samplesByTime = samplesSortedByTime(recording.samples);
            boolean hasWmbPlus20WeightStream = hasWmbCompatibilityPair(recording);
            for (RawScalePacket packet : recording.rawPackets) {
                ScaleSample sample = sampleMatching(packet.monotonicSeconds, samplesByTime);
                boolean compatibilityFloat32 = hasWmbPlus20WeightStream
                        && packet.characteristicUuid != null
                        && ScaleParsers.uuidMatches(packet.characteristicUuid, ScaleParsers.WMB_FLOAT32_UUID);
                ScoringFrame frame = new ScoringFrame();
                frame.monotonicSeconds = packet.monotonicSeconds;
                frame.weight = packet.role == PacketRole.WEIGHT && !compatibilityFloat32;
                frame.parseFailed = frame.weight && !compatibilityFloat32 && packet.rejectionReason != null;
                frame.weightGrams = packet.weightGrams != null
                        ? packet.weightGrams : sample == null ? null : sample.weightGrams;
                USBSerialSampleMetadata usb = packet.usbSerial != null
                        ? packet.usbSerial : sample == null ? null : sample.usbSerial;
                Integer sequence = packet.sequence != null ? packet.sequence : sample == null ? null : sample.sequence;
                if (usb != null) {
                    frame.sequence = usb.sequenceNumber;
                    frame.deviceTimestampMilliseconds = usb.firmwareMillis;
                } else {
                    frame.sequence = sequence == null ? null : sequence.longValue();
                    frame.deviceTimestampMilliseconds = packet.deviceTimestampMilliseconds != null
                            ? packet.deviceTimestampMilliseconds
                            : sample == null ? null : sample.deviceTimestampMilliseconds;
                }
                frame.usbDroppedDelta = usb == null ? 0 : usb.usbDroppedDelta;
                result.add(frame);
            }
            return recording.source == RecordingSource.USB_SERIAL ? deviceTimedUSBFrames(result) : result;
        }
        for (ScaleSample sample : canonicalWeightSamples(recording)) {
            ScoringFrame frame = new ScoringFrame();
            frame.monotonicSeconds = sample.monotonicSeconds;
            frame.weight = true;
            frame.parseFailed = false;
            frame.weightGrams = sample.weightGrams;
            if (sample.usbSerial != null) {
                frame.sequence = sample.usbSerial.sequenceNumber;
                frame.deviceTimestampMilliseconds = sample.usbSerial.firmwareMillis;
            } else {
                frame.sequence = sample.sequence == null ? null : sample.sequence.longValue();
                frame.deviceTimestampMilliseconds = sample.deviceTimestampMilliseconds;
            }
            frame.usbDroppedDelta = sample.usbSerial == null ? 0 : sample.usbSerial.usbDroppedDelta;
            result.add(frame);
        }
        return recording.source == RecordingSource.USB_SERIAL ? deviceTimedUSBFrames(result) : result;
    }

    private static List<ScoringFrame> deviceTimedUSBFrames(List<ScoringFrame> frames) {
        int firstIndex = -1;
        for (int index = 0; index < frames.size(); index++) {
            if (frames.get(index).deviceTimestampMilliseconds != null) {
                firstIndex = index;
                break;
            }
        }
        if (firstIndex < 0) return frames;

        final long modulus = 1L << 32;
        long previousTimestamp = frames.get(firstIndex).deviceTimestampMilliseconds;
        long elapsedMilliseconds = 0;
        double anchor = frames.get(firstIndex).monotonicSeconds;
        for (int index = firstIndex; index < frames.size(); index++) {
            ScoringFrame frame = frames.get(index);
            if (frame.deviceTimestampMilliseconds == null) continue;
            if (index > firstIndex) {
                Long delta = forwardDelta(previousTimestamp, frame.deviceTimestampMilliseconds, modulus);
                if (delta != null) {
                    elapsedMilliseconds = saturatingAdd(elapsedMilliseconds, delta);
                    previousTimestamp = frame.deviceTimestampMilliseconds;
                }
            }
            frame.monotonicSeconds = anchor + elapsedMilliseconds / 1000.0;
        }
        return frames;
    }

    static List<ScaleSample> canonicalWeightSamples(ScaleRecording recording) {
        if (hasWmbCompatibilityPair(recording)) {
            List<ScaleSample> samplesByTime = samplesSortedByTime(recording.samples);
            List<ScaleSample> repaired = new ArrayList<>();
            for (RawScalePacket packet : recording.rawPackets) {
                if (packet.role != PacketRole.WEIGHT || !isWmb20BytePacket(packet)) continue;
                ScaleSample existing = sampleMatching(packet.monotonicSeconds, samplesByTime);
                Double weight = packet.weightGrams != null
                        ? packet.weightGrams
                        : existing == null ? null : existing.weightGrams;
                if (weight == null) continue;
                ScaleSample sample = new ScaleSample();
                sample.arrivalTimeMillis = packet.arrivalTimeMillis;
                sample.monotonicSeconds = packet.monotonicSeconds;
                sample.scaleKind = existing == null ? packet.scaleKind : existing.scaleKind;
                sample.weightGrams = weight;
                sample.deviceTimestampMilliseconds = packet.deviceTimestampMilliseconds != null
                        ? packet.deviceTimestampMilliseconds
                        : existing == null ? null : existing.deviceTimestampMilliseconds;
                sample.sequence = packet.sequence != null
                        ? packet.sequence
                        : existing == null ? null : existing.sequence;
                sample.batteryPercent = existing == null ? null : existing.batteryPercent;
                sample.flowGramsPerSecond = existing == null ? null : existing.flowGramsPerSecond;
                sample.firmwareQualityScore = existing == null ? null : existing.firmwareQualityScore;
                sample.detectedSampleRateHz = existing == null ? null : existing.detectedSampleRateHz;
                sample.statusFlags = existing == null ? null : existing.statusFlags;
                sample.diagnosticFlags = existing == null ? null : existing.diagnosticFlags;
                sample.usbSerial = existing == null ? packet.usbSerial
                        : existing.usbSerial != null ? existing.usbSerial : packet.usbSerial;
                repaired.add(sample);
            }
            if (!repaired.isEmpty()) return repaired;
        }
        boolean hasWmbPlusStream = false;
        for (ScaleSample sample : recording.samples) {
            if (sample.scaleKind == ScaleKind.WEIGH_MY_BRU_PLUS) {
                hasWmbPlusStream = true;
                break;
            }
        }
        if (!hasWmbPlusStream) {
            for (RawScalePacket packet : recording.rawPackets) {
                if (packet.role == PacketRole.WEIGHT
                        && packet.scaleKind == ScaleKind.WEIGH_MY_BRU_PLUS
                        && isWmb20BytePacket(packet)) {
                    hasWmbPlusStream = true;
                    break;
                }
            }
        }
        if (!hasWmbPlusStream) return recording.samples;
        List<ScaleSample> result = new ArrayList<>();
        for (ScaleSample sample : recording.samples) {
            if (sample.scaleKind != ScaleKind.WEIGH_MY_BRU) result.add(sample);
        }
        return result;
    }

    private static List<ScaleSample> samplesSortedByTime(List<ScaleSample> samples) {
        List<ScaleSample> result = new ArrayList<>();
        for (ScaleSample sample : samples) {
            if (Double.isFinite(sample.monotonicSeconds)) result.add(sample);
        }
        result.sort(Comparator.comparingDouble(sample -> sample.monotonicSeconds));
        return result;
    }

    private static ScaleSample sampleMatching(double monotonicSeconds, List<ScaleSample> sortedSamples) {
        if (!Double.isFinite(monotonicSeconds) || sortedSamples.isEmpty()) return null;
        double tolerance = 0.001;
        int low = 0;
        int high = sortedSamples.size();
        while (low < high) {
            int mid = (low + high) / 2;
            if (sortedSamples.get(mid).monotonicSeconds < monotonicSeconds) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        ScaleSample best = null;
        double bestDelta = Double.MAX_VALUE;
        for (int index = low - 1; index <= low; index++) {
            if (index < 0 || index >= sortedSamples.size()) continue;
            double delta = Math.abs(sortedSamples.get(index).monotonicSeconds - monotonicSeconds);
            if (delta < bestDelta) {
                best = sortedSamples.get(index);
                bestDelta = delta;
            }
        }
        return bestDelta <= tolerance ? best : null;
    }

    private static boolean hasWmbCompatibilityPair(ScaleRecording recording) {
        boolean has20ByteWeight = false;
        boolean hasFloat32Weight = false;
        for (RawScalePacket packet : recording.rawPackets) {
            if (packet.role != PacketRole.WEIGHT) continue;
            if (isWmb20BytePacket(packet)) {
                has20ByteWeight = true;
            } else if (isWmbFloat32Packet(packet)) {
                hasFloat32Weight = true;
            }
            if (has20ByteWeight && hasFloat32Weight) return true;
        }
        return false;
    }

    private static boolean isWmb20BytePacket(RawScalePacket packet) {
        return packet.characteristicUuid != null
                && ScaleParsers.uuidMatches(packet.characteristicUuid, ScaleParsers.WMB_WEIGHT20_UUID);
    }

    private static boolean isWmbFloat32Packet(RawScalePacket packet) {
        return packet.characteristicUuid != null
                && ScaleParsers.uuidMatches(packet.characteristicUuid, ScaleParsers.WMB_FLOAT32_UUID);
    }

    private static ProtocolScoringCapabilities inferredProtocolCapabilities(
            ScaleRecording recording, List<ScoringFrame> frames
    ) {
        ScaleKind kind = recording.device != null
                ? recording.device.kind
                : recording.samples.isEmpty()
                ? ScaleKind.UNKNOWN
                : recording.samples.get(recording.samples.size() - 1).scaleKind;
        boolean hasSequence = false;
        boolean hasClock = false;
        for (ScoringFrame frame : frames) {
            hasSequence |= frame.sequence != null;
            hasClock |= frame.deviceTimestampMilliseconds != null;
        }
        ProtocolScoringCapabilities capabilities = new ProtocolScoringCapabilities();
        capabilities.hasChecksum = kind == ScaleKind.BOOKOO
                || kind == ScaleKind.BOOKOO_MINI
                || kind == ScaleKind.BOOKOO_ULTRA
                || kind == ScaleKind.WEIGH_MY_BRU_PLUS
                || kind == ScaleKind.ACAIA
                || kind == ScaleKind.DIFLUID
                || kind == ScaleKind.DIFLUID_TI
                || kind == ScaleKind.TIMEMORE_DOT;
        if (kind == ScaleKind.WEIGH_MY_BRU) {
            for (RawScalePacket packet : recording.rawPackets) {
                capabilities.hasChecksum |= packet.characteristicUuid != null
                        && packet.characteristicUuid.toUpperCase(Locale.ROOT).contains("6E400002");
            }
        }
        capabilities.hasSequence = hasSequence;
        capabilities.sequenceModulus = hasSequence
                ? recording.source == RecordingSource.USB_SERIAL ? 1L << 32 : 256L
                : null;
        capabilities.hasDeviceClock = hasClock;
        capabilities.deviceClockSemantics = kind == ScaleKind.DECENT || kind == ScaleKind.ESPRESSI
                ? DeviceClockSemantics.SHOT_TIMER
                : hasClock ? DeviceClockSemantics.FREE_RUNNING : DeviceClockSemantics.NONE;
        if (recording.source == RecordingSource.USB_SERIAL) {
            capabilities.deviceClockModulus = 1L << 32;
        } else if (kind == ScaleKind.BOOKOO || kind == ScaleKind.BOOKOO_MINI
                || kind == ScaleKind.BOOKOO_ULTRA || kind == ScaleKind.WEIGH_MY_BRU_PLUS) {
            capabilities.deviceClockModulus = 1L << 24;
        } else if (kind == ScaleKind.DIFLUID || kind == ScaleKind.DIFLUID_TI) {
            capabilities.deviceClockModulus = 1L << 32;
        }
        return capabilities;
    }

    private static ClassifiedFrames classifyFrames(
            List<ScoringFrame> allFrames,
            RecordingMode mode,
            ProtocolScoringCapabilities capabilities
    ) {
        List<ScoringFrame> frames = new ArrayList<>();
        for (ScoringFrame frame : allFrames) if (frame.weight) frames.add(frame);
        List<Double> parsedWeights = new ArrayList<>();
        for (ScoringFrame frame : frames) {
            if (!frame.parseFailed && finite(frame.weightGrams)) parsedWeights.add(frame.weightGrams);
        }
        double resolution = estimateResolution(parsedWeights);
        List<FrameClass> classes = new ArrayList<>(Collections.nCopies(frames.size(), null));
        Integer lastUsableIndex = null;
        List<Integer> usableIndices = new ArrayList<>();
        Long sequenceHighWater = null;
        Long clockHighWater = null;
        long sequenceModulus = capabilities.sequenceModulus == null ? 256 : capabilities.sequenceModulus;
        boolean verifiesFreshness = capabilities.hasDeviceClock
                && capabilities.deviceClockSemantics == DeviceClockSemantics.FREE_RUNNING;
        boolean checksImpulse = mode == RecordingMode.SHOT || mode == RecordingMode.IDLE_STABILITY;
        boolean checksPhysicalRate = mode == RecordingMode.IDLE_STABILITY;
        boolean checksDuplicates = mode == RecordingMode.SHOT;

        for (int i = 0; i < frames.size(); i++) {
            ScoringFrame frame = frames.get(i);
            if (frame.parseFailed || !finite(frame.weightGrams)) {
                classes.set(i, FrameClass.PARSE_FAILURE);
                continue;
            }
            if (frame.sequence != null && sequenceHighWater != null
                    && forwardDelta(sequenceHighWater, frame.sequence, sequenceModulus) == null) {
                classes.set(i, FrameClass.OUT_OF_ORDER);
                continue;
            }
            if (verifiesFreshness && frame.deviceTimestampMilliseconds != null && clockHighWater != null
                    && forwardDelta(clockHighWater, frame.deviceTimestampMilliseconds,
                    capabilities.deviceClockModulus) == null) {
                classes.set(i, FrameClass.STALE);
                continue;
            }
            if (frame.sequence != null) sequenceHighWater = frame.sequence;
            if (verifiesFreshness && frame.deviceTimestampMilliseconds != null) {
                clockHighWater = frame.deviceTimestampMilliseconds;
            }

            double weight = frame.weightGrams;
            boolean implausible = false;
            if (checksImpulse && i > 0 && i < frames.size() - 1) {
                Double previousWeight = parseableWeight(frames.get(i - 1));
                Double nextWeight = parseableWeight(frames.get(i + 1));
                if (previousWeight != null && nextWeight != null
                        && Math.abs(weight - median3(previousWeight, weight, nextWeight)) > IMPULSE_DEVIATION_GRAMS) {
                    implausible = true;
                }
            }
            if (checksPhysicalRate && lastUsableIndex != null) {
                ScoringFrame previous = frames.get(lastUsableIndex);
                double deltaSeconds = frame.monotonicSeconds - previous.monotonicSeconds;
                if (deltaSeconds > 0 && previous.weightGrams != null) {
                    if (Math.abs(weight - previous.weightGrams) / deltaSeconds
                            > MAX_PHYSICAL_FLOW_GRAMS_PER_SECOND) {
                        implausible = true;
                    }
                }
            }
            if (implausible) {
                classes.set(i, FrameClass.IMPLAUSIBLE);
                continue;
            }

            if (checksDuplicates && lastUsableIndex != null
                    && frames.get(lastUsableIndex).weightGrams != null
                    && Math.abs(weight - frames.get(lastUsableIndex).weightGrams)
                    <= duplicateTolerance(resolution)) {
                double deltaSeconds = frame.monotonicSeconds - frames.get(lastUsableIndex).monotonicSeconds;
                Integer baseIndex = latestFlowBase(usableIndices, frames,
                        frame.monotonicSeconds - FLOW_WINDOW_SECONDS);
                if (baseIndex != null && frames.get(baseIndex).weightGrams != null && deltaSeconds > 0) {
                    double baseSpan = frame.monotonicSeconds - frames.get(baseIndex).monotonicSeconds;
                    if (baseSpan > 0) {
                        double flow = Math.abs(weight - frames.get(baseIndex).weightGrams) / baseSpan;
                        if (flow * deltaSeconds >= resolution) {
                            classes.set(i, FrameClass.DUPLICATE);
                            continue;
                        }
                    }
                }
            }
            classes.set(i, FrameClass.USABLE);
            lastUsableIndex = i;
            usableIndices.add(i);
        }

        ClassifiedFrames result = new ClassifiedFrames();
        result.frames = frames;
        result.classes = classes;
        result.resolutionGrams = resolution;
        return result;
    }

    private static Integer latestFlowBase(
            List<Integer> usableIndices, List<ScoringFrame> frames, double cutoff
    ) {
        for (int i = usableIndices.size() - 1; i >= 0; i--) {
            int index = usableIndices.get(i);
            if (frames.get(index).monotonicSeconds <= cutoff) return index;
        }
        return null;
    }

    private static Double parseableWeight(ScoringFrame frame) {
        return !frame.parseFailed && finite(frame.weightGrams) ? frame.weightGrams : null;
    }

    private static double duplicateTolerance(double resolution) {
        return Math.max(MINIMUM_DUPLICATE_TOLERANCE_GRAMS, resolution * 0.25);
    }

    private static double estimateResolution(List<Double> weights) {
        List<Double> nonzero = new ArrayList<>();
        for (int i = 1; i < weights.size(); i++) {
            double delta = Math.abs(weights.get(i) - weights.get(i - 1));
            if (delta > 0 && Double.isFinite(delta)) nonzero.add(delta);
        }
        Collections.sort(nonzero);
        Double estimate = percentile(nonzero, 0.10);
        return Math.max(MINIMUM_RESOLUTION_GRAMS, estimate == null ? MINIMUM_RESOLUTION_GRAMS : estimate);
    }

    private static Long forwardDelta(long previous, long current, Long modulus) {
        if (modulus != null && modulus > 0) {
            long delta = Math.floorMod(current - previous, modulus);
            return delta > 0 && (double) delta <= modulus / 2.0 ? delta : null;
        }
        return current > previous ? current - previous : null;
    }

    private static CoverageResult coverageAndPurity(
            List<ScoringFrame> frames,
            List<FrameClass> classes,
            double recordingStart,
            double recordingEnd,
            long additionalLostFrameCount
    ) {
        if (frames.isEmpty()) return null;
        double spanMilliseconds = (recordingEnd - recordingStart) * 1000;
        if (spanMilliseconds <= 0) return null;
        int slotCount = (int) Math.floor(spanMilliseconds / SLOT_MILLISECONDS + SLOT_EPSILON);
        if (slotCount < 1) return null;
        boolean[] served = new boolean[slotCount];
        int usableCount = 0;
        for (int i = 0; i < frames.size(); i++) {
            if (classes.get(i) != FrameClass.USABLE) continue;
            usableCount++;
            double offset = frames.get(i).monotonicSeconds - recordingStart;
            if (offset < 0 || offset * 1000 >= slotCount * SLOT_MILLISECONDS) continue;
            int index = (int) Math.floor(offset * 1000 / SLOT_MILLISECONDS + SLOT_EPSILON);
            index = Math.min(Math.max(index, 0), slotCount - 1);
            served[index] = true;
        }
        int servedCount = 0;
        int run = 0;
        int longestRun = 0;
        for (boolean isServed : served) {
            if (isServed) {
                servedCount++;
                run = 0;
            } else {
                run++;
                longestRun = Math.max(longestRun, run);
            }
        }
        CoverageResult result = new CoverageResult();
        result.coverage = (double) servedCount / slotCount;
        result.purity = (double) usableCount / ((double) frames.size() + additionalLostFrameCount);
        result.slotCount = slotCount;
        result.servedSlots = servedCount;
        result.longestUnservedRunMilliseconds = longestRun * SLOT_MILLISECONDS;
        return result;
    }

    private static FrameClassificationMetrics frameClassification(List<FrameClass> classes) {
        FrameClassificationMetrics result = new FrameClassificationMetrics();
        for (FrameClass frameClass : classes) {
            switch (frameClass) {
                case USABLE: result.usable++; break;
                case PARSE_FAILURE: result.parseFailure++; break;
                case OUT_OF_ORDER: result.outOfOrder++; break;
                case STALE: result.stale++; break;
                case DUPLICATE: result.duplicate++; break;
                case IMPLAUSIBLE: result.implausible++; break;
            }
        }
        return result;
    }

    private static ProtocolVerificationMetrics protocolVerification(
            List<ScoringFrame> frames,
            ProtocolScoringCapabilities capabilities,
            RecordingMode mode
    ) {
        boolean hasSequence = capabilities.hasSequence;
        boolean hasClock = capabilities.hasDeviceClock;
        for (ScoringFrame frame : frames) {
            hasSequence |= frame.sequence != null;
            hasClock |= frame.deviceTimestampMilliseconds != null;
        }
        Map<String, Boolean> values = new HashMap<>();
        values.put("parseFailure", capabilities.hasChecksum);
        values.put("outOfOrder", hasSequence);
        values.put("stale", hasClock && capabilities.deviceClockSemantics == DeviceClockSemantics.FREE_RUNNING);
        values.put("duplicate", mode == RecordingMode.SHOT);
        values.put("implausible", mode == RecordingMode.SHOT || mode == RecordingMode.IDLE_STABILITY);
        ProtocolVerificationMetrics result = new ProtocolVerificationMetrics();
        for (Map.Entry<String, Boolean> entry : values.entrySet()) {
            (entry.getValue() ? result.verifiableClasses : result.unverifiableClasses).add(entry.getKey());
        }
        Collections.sort(result.verifiableClasses);
        Collections.sort(result.unverifiableClasses);
        result.verificationCoveragePercent = roundHalfAwayFromZero(100.0 * result.verifiableClasses.size() / 5);
        result.purityIsUpperBound = result.verifiableClasses.size() < 5;
        return result;
    }

    private static ScoringValidity evaluateValidity(
            RecordingMode mode,
            double recordingStart,
            double recordingEnd,
            boolean boundariesPresent,
            List<SamplePoint> samples,
            List<ScaleRecordingEvent> events
    ) {
        double minimumSeconds;
        int minimumUsable;
        boolean disconnectInvalidates;
        switch (mode) {
            case SHOT: minimumSeconds = 20; minimumUsable = 2; disconnectInvalidates = true; break;
            case TRANSPORT_STRESS: minimumSeconds = 120; minimumUsable = 2; disconnectInvalidates = false; break;
            case IDLE_STABILITY: minimumSeconds = 60; minimumUsable = 100; disconnectInvalidates = true; break;
            case STEP_RESPONSE: minimumSeconds = 10; minimumUsable = 30; disconnectInvalidates = true; break;
            case TARE_LATENCY: minimumSeconds = 5; minimumUsable = 10; disconnectInvalidates = true; break;
            case BATTERY_STABILITY: minimumSeconds = 60; minimumUsable = 0; disconnectInvalidates = true; break;
            default: throw new IllegalStateException("Unknown recording mode");
        }
        ScoringValidity result = new ScoringValidity();
        if (!boundariesPresent) result.reasons.add("recordingBoundariesMissing");
        if (Math.max(0, recordingEnd - recordingStart) < minimumSeconds) {
            result.reasons.add("durationBelowMinimum");
        }
        if (samples.size() < minimumUsable) result.reasons.add("usableFrameCountBelowMinimum");
        if (mode == RecordingMode.IDLE_STABILITY) {
            int analysed = 0;
            for (SamplePoint sample : samples) {
                if (sample.monotonicSeconds - recordingStart >= IDLE_SETTLING_SECONDS) analysed++;
            }
            if (analysed < minimumUsable) result.reasons.add("idleAnalysedFrameCountBelowMinimum");
        }
        if (mode == RecordingMode.STEP_RESPONSE) {
            int baselineCount = 0;
            int finalCount = 0;
            for (SamplePoint sample : samples) {
                if (sample.monotonicSeconds >= recordingStart
                        && sample.monotonicSeconds <= recordingStart + STEP_BASELINE_WINDOW_SECONDS) {
                    baselineCount++;
                }
                if (sample.monotonicSeconds >= recordingEnd - STEP_FINAL_WINDOW_SECONDS
                        && sample.monotonicSeconds < recordingEnd) {
                    finalCount++;
                }
            }
            if (baselineCount < 5) result.reasons.add("stepBaselineFrameCountBelowMinimum");
            if (finalCount < 5) result.reasons.add("stepFinalFrameCountBelowMinimum");
        }
        if (disconnectInvalidates) {
            for (ScaleRecordingEvent event : events) {
                if (event.type == RecordingEventType.DISCONNECT) {
                    result.reasons.add("disconnectDuringRecording");
                    break;
                }
            }
        }
        for (ScaleRecordingEvent event : events) {
            if (event.type == RecordingEventType.APP_BACKGROUNDED) {
                result.reasons.add("appLeftForeground");
                break;
            }
        }
        result.isValid = result.reasons.isEmpty();
        return result;
    }

    private static IdleResult idleStability(List<SamplePoint> samples, double recordingStart) {
        List<SamplePoint> window = new ArrayList<>();
        for (SamplePoint sample : samples) {
            if (sample.monotonicSeconds - recordingStart >= IDLE_SETTLING_SECONDS) window.add(sample);
        }
        if (window.size() < 2) return null;
        double base = window.get(0).monotonicSeconds;
        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
        for (SamplePoint sample : window) {
            xs.add(sample.monotonicSeconds - base);
            ys.add(sample.weightGrams);
        }
        double[] fit = olsSlopeIntercept(xs, ys);
        if (fit == null) return null;
        double drift = fit[0] * 60;
        List<Double> residuals = new ArrayList<>();
        for (int i = 0; i < xs.size(); i++) residuals.add(ys.get(i) - (fit[1] + fit[0] * xs.get(i)));
        Double standardDeviation = sampleStandardDeviation(residuals);
        List<Double> sortedResiduals = new ArrayList<>(residuals);
        Collections.sort(sortedResiduals);
        Double upper = percentile(sortedResiduals, 0.995);
        Double lower = percentile(sortedResiduals, 0.005);
        Double peakToPeak = upper == null || lower == null ? null : upper - lower;
        Double resolution = null;
        for (int i = 1; i < ys.size(); i++) {
            double delta = Math.abs(ys.get(i) - ys.get(i - 1));
            if (delta > 0 && (resolution == null || delta < resolution)) resolution = delta;
        }
        Double noise = standardDeviation == null ? null
                : 100 * clamp01((0.20 - standardDeviation) / (0.20 - 0.02));
        double driftComponent = 100 * clamp01((1.00 - Math.abs(drift)) / (1.00 - 0.05));
        IdleResult result = new IdleResult();
        result.score = noise == null ? null : clampedScore(Math.exp(
                0.5 * Math.log(floored(noise)) + 0.5 * Math.log(floored(driftComponent))
        ));
        result.noiseScore = noise == null ? null : roundHalfAwayFromZero(noise);
        result.driftScore = roundHalfAwayFromZero(driftComponent);
        result.analysedSampleCount = window.size();
        result.residualStandardDeviationGrams = rounded6(standardDeviation);
        result.residualPeakToPeakGrams = rounded6(peakToPeak);
        result.driftGramsPerMinute = rounded6(drift);
        result.resolutionGrams = rounded6(resolution);
        return result;
    }

    private static StepResponseMetrics stepResponse(
            List<SamplePoint> samples, double recordingStart, double recordingEnd
    ) {
        StepResponseMetrics result = new StepResponseMetrics();
        if (samples.size() < 3) return result;
        List<Double> baselineValues = new ArrayList<>();
        List<Double> finalValues = new ArrayList<>();
        for (SamplePoint sample : samples) {
            if (sample.monotonicSeconds >= recordingStart
                    && sample.monotonicSeconds <= recordingStart + STEP_BASELINE_WINDOW_SECONDS) {
                baselineValues.add(sample.weightGrams);
            }
            if (sample.monotonicSeconds >= recordingEnd - STEP_FINAL_WINDOW_SECONDS
                    && sample.monotonicSeconds < recordingEnd) {
                finalValues.add(sample.weightGrams);
            }
        }
        Collections.sort(baselineValues);
        Collections.sort(finalValues);
        Double baseline = percentile(baselineValues, 0.5);
        Double finalWeight = percentile(finalValues, 0.5);
        if (baseline == null || finalWeight == null || finalWeight - baseline < 5) return result;
        double amplitude = finalWeight - baseline;
        Double onset = firstTimeAtOrAbove(samples, baseline + 0.05 * amplitude);
        Double t10 = firstTimeAtOrAbove(samples, baseline + 0.10 * amplitude);
        Double t90 = firstTimeAtOrAbove(samples, baseline + 0.90 * amplitude);
        if (onset == null) return result;
        Double settledAt = null;
        for (int i = 0; i < samples.size(); i++) {
            SamplePoint sample = samples.get(i);
            if (sample.monotonicSeconds < onset || Math.abs(sample.weightGrams - finalWeight) > 0.1) continue;
            double holdEnd = sample.monotonicSeconds + 1;
            double previousTime = sample.monotonicSeconds;
            boolean held = true;
            boolean observedThroughHold = false;
            for (int j = i; j < samples.size(); j++) {
                SamplePoint candidate = samples.get(j);
                if (candidate.monotonicSeconds - previousTime > 0.25
                        || Math.abs(candidate.weightGrams - finalWeight) > 0.1) {
                    held = false;
                    break;
                }
                if (candidate.monotonicSeconds >= holdEnd) {
                    observedThroughHold = true;
                    break;
                }
                previousTime = candidate.monotonicSeconds;
            }
            if (held && observedThroughHold) {
                settledAt = sample.monotonicSeconds;
                break;
            }
        }
        double peak = finalWeight;
        for (SamplePoint sample : samples) {
            if (sample.monotonicSeconds >= onset) peak = Math.max(peak, sample.weightGrams);
        }
        result.stepDetected = true;
        result.onsetSecondsFromRecordingStart = rounded6(onset - recordingStart);
        result.baselineGrams = rounded6(baseline);
        result.finalGrams = rounded6(finalWeight);
        result.amplitudeGrams = rounded6(amplitude);
        result.riseTime10To90Seconds = t10 == null || t90 == null ? null : rounded6(t90 - t10);
        result.settlingTimeSeconds = settledAt == null ? null : rounded6(settledAt - onset);
        result.overshootPercent = rounded6(peak > finalWeight ? (peak - finalWeight) / amplitude * 100 : 0);
        return result;
    }

    private static Double firstTimeAtOrAbove(List<SamplePoint> samples, double level) {
        for (SamplePoint sample : samples) if (sample.weightGrams >= level) return sample.monotonicSeconds;
        return null;
    }

    private static int missingSequenceCount(List<ScoringFrame> frames, Long modulus) {
        long count = 0;
        Long acceptedHighWater = null;
        for (ScoringFrame frame : frames) {
            Long current = frame.sequence;
            if (current == null) continue;
            if (acceptedHighWater != null) {
                Long delta = forwardDelta(acceptedHighWater, current, modulus == null ? 256L : modulus);
                if (delta == null) continue;
                if (delta > 1) count = saturatingAdd(count, delta - 1);
            }
            acceptedHighWater = current;
        }
        return saturatingInt(count);
    }

    private static long saturatingAdd(long left, long right) {
        if (right > 0 && left > Long.MAX_VALUE - right) return Long.MAX_VALUE;
        return left + right;
    }

    private static int saturatingInt(long value) {
        return value >= Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) Math.max(0, value);
    }

    private static int firmwareBumpEventCount(List<ScaleSample> samples) {
        int count = 0;
        boolean active = false;
        for (ScaleSample sample : samples) {
            boolean hasBump = sample.diagnosticFlags != null && sample.diagnosticFlags.recentBump;
            if (hasBump && !active) count++;
            active = hasBump;
        }
        return count;
    }

    private static double usableSamplesSampleSpan(List<SamplePoint> samples) {
        if (samples.size() < 2) return 0;
        return Math.max(0, samples.get(samples.size() - 1).monotonicSeconds - samples.get(0).monotonicSeconds);
    }

    private static Double percentile(List<Double> sortedValues, double probability) {
        if (sortedValues.isEmpty()) return null;
        if (sortedValues.size() == 1) return sortedValues.get(0);
        double position = (sortedValues.size() - 1) * probability;
        int lower = (int) Math.floor(position);
        if (lower + 1 >= sortedValues.size()) return sortedValues.get(sortedValues.size() - 1);
        return sortedValues.get(lower)
                + (position - lower) * (sortedValues.get(lower + 1) - sortedValues.get(lower));
    }

    private static Double sampleStandardDeviation(List<Double> values) {
        if (values.size() < 2) return null;
        double mean = 0;
        for (double value : values) mean += value;
        mean /= values.size();
        double variance = 0;
        for (double value : values) variance += Math.pow(value - mean, 2);
        return Math.sqrt(variance / (values.size() - 1));
    }

    private static double[] olsSlopeIntercept(List<Double> xs, List<Double> ys) {
        if (xs.size() < 2 || xs.size() != ys.size()) return null;
        double meanX = 0;
        double meanY = 0;
        for (double value : xs) meanX += value;
        for (double value : ys) meanY += value;
        meanX /= xs.size();
        meanY /= ys.size();
        double sumXX = 0;
        double sumXY = 0;
        for (int i = 0; i < xs.size(); i++) {
            sumXX += Math.pow(xs.get(i) - meanX, 2);
            sumXY += (xs.get(i) - meanX) * (ys.get(i) - meanY);
        }
        if (sumXX == 0) return null;
        double slope = sumXY / sumXX;
        return new double[] {slope, meanY - slope * meanX};
    }

    private static double median3(double a, double b, double c) {
        return a > b ? (b > c ? b : Math.min(a, c)) : (a > c ? a : Math.min(b, c));
    }

    private static boolean finite(Double value) {
        return value != null && Double.isFinite(value);
    }

    private static double clamp01(double value) {
        return Math.min(1, Math.max(0, value));
    }

    private static double floored(double score) {
        return 5 + 0.95 * score;
    }

    private static int roundHalfAwayFromZero(double value) {
        return value >= 0 ? (int) Math.floor(value + 0.5) : (int) Math.ceil(value - 0.5);
    }

    private static int clampedScore(double value) {
        return Math.min(100, Math.max(0, roundHalfAwayFromZero(value)));
    }

    private static Double rounded6(Double value) {
        if (value == null) return null;
        double scaled = value * 1_000_000.0;
        double rounded = scaled >= 0 ? Math.floor(scaled + 0.5) : Math.ceil(scaled - 0.5);
        return rounded / 1_000_000.0;
    }

    private static Double average(List<Integer> values) {
        if (values.isEmpty()) return null;
        double total = 0;
        for (int value : values) total += value;
        return total / values.size();
    }

    private static double minimumFrameTime(List<ScoringFrame> frames, double fallback) {
        if (frames.isEmpty()) return fallback;
        double result = Double.POSITIVE_INFINITY;
        for (ScoringFrame frame : frames) result = Math.min(result, frame.monotonicSeconds);
        return result;
    }

    private static double maximumFrameTime(List<ScoringFrame> frames, double fallback) {
        if (frames.isEmpty()) return fallback;
        double result = Double.NEGATIVE_INFINITY;
        for (ScoringFrame frame : frames) result = Math.max(result, frame.monotonicSeconds);
        return result;
    }
}
