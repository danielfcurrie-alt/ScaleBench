package app.scalebench.android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class GoldenVectorSmokeTest {
    private static final double TOLERANCE = 0.000001;

    public static void main(String[] args) {
        run();
        check("invalidCRC".equals(SharedAnalysisContract.rejectionReasonName("INVALID_CRC")), "shared CRC spelling");
        checkPacketFieldContract();
        checkSignalDiagnostics();
        Path repoRoot = Paths.get(System.getProperty("scalebench.repo.root", ".")).toAbsolutePath().normalize();
        Map<String, Object> analysisFixture = object(readJson(repoRoot.resolve("shared/fixtures/official-analysis.json")));
        check(
                object(analysisFixture.get("chartAnalysis")).containsKey("signalDiagnostics"),
                "analysis fixture diagnostics"
        );
        System.out.println("Golden scoring vectors passed");
    }

    private static void checkSignalDiagnostics() {
        ScaleRecording recording = ScaleRecording.empty(RecordingMode.SHOT);
        recording.recordingStartMonotonicSeconds = 0.0;
        recording.recordingEndMonotonicSeconds = 20.0;
        recording.device = new ScaleDeviceIdentity();
        recording.device.name = "Diagnostic WMB+";
        recording.device.identifier = "diagnostic-wmb-plus";
        recording.device.kind = ScaleKind.WEIGH_MY_BRU_PLUS;
        recording.device.advertisedServices = new ArrayList<>();
        recording.protocolCapabilities = new ProtocolScoringCapabilities();
        recording.protocolCapabilities.hasChecksum = true;
        recording.protocolCapabilities.hasSequence = true;
        recording.protocolCapabilities.sequenceModulus = 256L;
        recording.protocolCapabilities.hasDeviceClock = true;
        recording.protocolCapabilities.deviceClockSemantics = DeviceClockSemantics.FREE_RUNNING;
        recording.protocolCapabilities.deviceClockModulus = 1L << 24;

        for (int index = 0; index < 400; index++) {
            double seconds = index / 20.0;
            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = Math.round(seconds * 1000.0);
            sample.monotonicSeconds = seconds;
            sample.scaleKind = ScaleKind.WEIGH_MY_BRU_PLUS;
            sample.weightGrams = 20.0 + seconds + 2.0 * Math.sin(0.8 * seconds);
            sample.deviceTimestampMilliseconds = Math.round(seconds * 1000.0 * 1.0001);
            sample.sequence = index % 256;
            sample.flowGramsPerSecond = 1.0 + 1.6 * Math.cos(0.8 * (seconds - 0.2));
            sample.detectedSampleRateHz = 20;
            recording.samples.add(sample);
        }

        AndroidChartAnalysis analysis = ChartAnalysis.create(recording, ScaleQualityAnalyzer.analyze(recording));
        AndroidFlowValidationDiagnostics flow = analysis.signalDiagnostics.flowValidation;
        check(flow != null && flow.medianAbsoluteErrorGramsPerSecond < 0.08, "flow validation error");
        check(flow.lagMilliseconds != null && Math.abs(flow.lagMilliseconds - 200.0) <= 51.0, "flow validation lag");
        AndroidClockSkewDiagnostics clock = analysis.signalDiagnostics.clockSkew;
        check(clock != null && Math.abs(clock.skewPartsPerMillion - 100.0) <= 20.0, "clock skew");
        AndroidPacketCoalescingDiagnostics packet = analysis.signalDiagnostics.packetCoalescing;
        check(packet != null && Math.abs(packet.framesPerServedSlot - 1.0) < 0.01, "packet grouping");

        recording.device.kind = ScaleKind.DECENT;
        recording.protocolCapabilities.deviceClockSemantics = DeviceClockSemantics.SHOT_TIMER;
        check(
                ChartAnalysis.create(recording, ScaleQualityAnalyzer.analyze(recording)).signalDiagnostics.clockSkew == null,
                "shot timer excluded from clock skew"
        );
    }

    private static void checkPacketFieldContract() {
        Path repoRoot = Paths.get(System.getProperty("scalebench.repo.root", ".")).toAbsolutePath().normalize();
        checkPacketFieldFixture(repoRoot.resolve("shared/fixtures/packet-fields.json"));
        checkPacketFieldFixture(repoRoot.resolve("shared/fixtures/packet-fields-bookoo.json"));
        check("03 0B 00".equals(ScaleParsers.normalizeHex("030B00")), "legacy compact hex normalization");
    }

    private static void checkPacketFieldFixture(Path path) {
        Map<String, Object> fixture = object(readJson(path));
        byte[] bytes = ScaleParsers.parseHex(string(fixture.get("bytesHex")));
        check(bytes != null, "packet field fixture hex");
        check(string(fixture.get("bytesHex")).equals(ScaleParsers.hex(bytes)), "Android spaced runtime hex");

        ScaleKind kind = "bookooUltra".equals(string(fixture.get("scaleKind")))
                ? ScaleKind.BOOKOO_ULTRA : ScaleKind.WEIGH_MY_BRU_PLUS;

        List<PacketFieldAnnotation> actual = ScaleParsers.packetFields(
                kind,
                string(fixture.get("characteristicUUID")),
                bytes
        );
        List<Object> expected = array(fixture.get("fields"));
        check(actual.size() == expected.size(), "packet field count");
        for (int index = 0; index < expected.size(); index++) {
            PacketFieldAnnotation field = actual.get(index);
            Map<String, Object> value = object(expected.get(index));
            check(field.startByte == intValue(value.get("startByte")), "packet field start " + index);
            check(field.endByteExclusive == intValue(value.get("endByteExclusive")), "packet field end " + index);
            check(field.label.equals(string(value.get("label"))), "packet field label " + index);
            check(field.decodedValue.equals(string(value.get("decodedValue"))), "packet field value " + index);
            check(SharedAnalysisContract.lowerCamelEnum(field.semantic.name()).equals(string(value.get("semantic"))), "packet field semantic " + index);
        }
    }

    static void run() {
        Path repoRoot = Paths.get(System.getProperty("scalebench.repo.root", ".")).toAbsolutePath().normalize();
        Path vectorsRoot = repoRoot.resolve("scoring/vectors");
        Map<String, Object> index = object(readJson(vectorsRoot.resolve("index.json")));
        check(ScaleQualityAnalyzer.SCORING_MODEL_VERSION.equals(string(index.get("scoringModelVersion"))), "vector scoring model version");

        for (Object entryObject : array(index.get("vectors"))) {
            Map<String, Object> entry = object(entryObject);
            String vectorId = string(entry.get("vectorId"));
            Path vectorDirectory = vectorsRoot.resolve(vectorId);
            Map<String, Object> input = object(readJson(vectorDirectory.resolve("input.json")));
            Map<String, Object> expected = object(readJson(vectorDirectory.resolve("expected.json")));
            ScaleRecording recording = recording(input);
            ScaleQualityMetrics metrics = ScaleQualityAnalyzer.analyze(recording);
            assertMetrics(metrics, ChartAnalysis.create(recording, metrics), expected, vectorId);
        }
    }

    private static ScaleRecording recording(Map<String, Object> input) {
        RecordingMode mode = mode(string(input.get("mode")));
        ScaleKind scaleKind = scaleKind(stringOrNull(input.get("deviceKind")));
        ScaleRecording recording = ScaleRecording.empty(mode);
        String source = stringOrNull(input.get("source"));
        recording.source = "usbSerial".equals(source)
                ? RecordingSource.USB_SERIAL : RecordingSource.BLUETOOTH;
        if (recording.source == RecordingSource.USB_SERIAL) {
            recording.protocolName = "WMB+ USB Serial";
            recording.serialBaud = 115200;
        }
        recording.device = new ScaleDeviceIdentity();
        recording.device.name = "Vector";
        recording.device.identifier = "vector";
        recording.device.kind = scaleKind;
        recording.device.advertisedServices = new ArrayList<>();
        recording.recordingStartMonotonicSeconds = nullableDouble(input.get("recordingStartMonotonicSeconds"));
        recording.recordingEndMonotonicSeconds = nullableDouble(input.get("recordingEndMonotonicSeconds"));

        Object capabilities = input.get("protocolCapabilities");
        if (capabilities instanceof Map<?, ?>) {
            recording.protocolCapabilities = capabilities(object(capabilities));
        }

        for (Object eventObject : array(input.get("events"))) {
            Map<String, Object> eventJson = object(eventObject);
            ScaleRecordingEvent event = new ScaleRecordingEvent();
            event.type = recordingEventType(string(eventJson.get("type")));
            event.monotonicSeconds = doubleValue(eventJson.get("monotonicSeconds"));
            recording.events.add(event);
        }

        for (Object frameObject : array(input.get("frames"))) {
            Map<String, Object> frame = object(frameObject);
            String kind = string(frame.get("kind"));
            double monotonicSeconds = doubleValue(frame.get("monotonicSeconds"));
            Double weightGrams = nullableDouble(frame.get("weightGrams"));
            boolean parseFailed = Boolean.TRUE.equals(frame.get("parseFailed"));

            RawScalePacket packet = new RawScalePacket();
            packet.arrivalTimeMillis = Math.round(monotonicSeconds * 1000.0);
            packet.monotonicSeconds = monotonicSeconds;
            packet.scaleKind = scaleKind;
            packet.characteristicUuid = "VECTOR";
            packet.role = packetRole(kind);
            packet.bytesHex = "";
            packet.rejectionReason = parseFailed && "weight".equals(kind) ? ParseRejectionReason.INVALID_CHECKSUM : null;
            packet.weightGrams = weightGrams;
            packet.sequence = recording.source == RecordingSource.USB_SERIAL
                    ? null : nullableInt(frame.get("sequence"));
            packet.deviceTimestampMilliseconds = frame.get("firmwareMillis") != null
                    ? nullableLong(frame.get("firmwareMillis"))
                    : nullableLong(frame.get("deviceTimestampMs"));
            packet.usbSerial = usbMetadata(frame, recording.source);
            recording.rawPackets.add(packet);

            if ("weight".equals(kind) && !parseFailed && weightGrams != null) {
                ScaleSample sample = new ScaleSample();
                sample.arrivalTimeMillis = packet.arrivalTimeMillis;
                sample.monotonicSeconds = monotonicSeconds;
                sample.scaleKind = scaleKind;
                sample.weightGrams = weightGrams;
                sample.sequence = packet.sequence;
                sample.deviceTimestampMilliseconds = packet.deviceTimestampMilliseconds;
                sample.flowGramsPerSecond = nullableDouble(frame.get("flowGramsPerSecond"));
                sample.usbSerial = packet.usbSerial;
                recording.samples.add(sample);
            }
        }
        return recording;
    }

    private static USBSerialSampleMetadata usbMetadata(
            Map<String, Object> frame,
            RecordingSource source
    ) {
        if (source != RecordingSource.USB_SERIAL || frame.get("firmwareMillis") == null
                || frame.get("sequenceNumber") == null) return null;
        USBSerialSampleMetadata metadata = new USBSerialSampleMetadata();
        metadata.firmwareMillis = nullableLong(frame.get("firmwareMillis"));
        metadata.sequenceNumber = nullableLong(frame.get("sequenceNumber"));
        metadata.usbStatusRaw = 0x0001;
        metadata.usbStatusLabels.add("HX711 connected");
        metadata.firmwareQuality = 100;
        metadata.hx711Hz = 20;
        Long cumulative = nullableLong(frame.get("usbDroppedCumulative"));
        Long delta = nullableLong(frame.get("usbDroppedDelta"));
        metadata.usbDroppedCumulative = cumulative == null ? 0 : cumulative;
        metadata.usbDroppedDelta = delta == null ? 0 : delta;
        metadata.hostReceivedAtMillis = Math.round(doubleValue(frame.get("monotonicSeconds")) * 1000.0);
        return metadata;
    }

    private static RecordingEventType recordingEventType(String value) {
        switch (value) {
            case "disconnect": return RecordingEventType.DISCONNECT;
            case "reconnect": return RecordingEventType.RECONNECT;
            case "appBackgrounded": return RecordingEventType.APP_BACKGROUNDED;
            case "appForegrounded": return RecordingEventType.APP_FOREGROUNDED;
            default: throw new IllegalStateException("Unknown recording event type " + value);
        }
    }

    private static ProtocolScoringCapabilities capabilities(Map<String, Object> json) {
        ProtocolScoringCapabilities capabilities = new ProtocolScoringCapabilities();
        capabilities.hasChecksum = Boolean.TRUE.equals(json.get("hasChecksum"));
        capabilities.hasSequence = Boolean.TRUE.equals(json.get("hasSequence"));
        capabilities.sequenceModulus = nullableLong(json.get("sequenceModulus"));
        capabilities.hasDeviceClock = Boolean.TRUE.equals(json.get("hasDeviceClock"));
        String semantics = stringOrNull(json.get("deviceClockSemantics"));
        capabilities.deviceClockSemantics = semantics == null && capabilities.hasDeviceClock
                ? DeviceClockSemantics.FREE_RUNNING
                : clockSemantics(semantics);
        capabilities.deviceClockModulus = nullableLong(json.get("deviceClockModulus"));
        return capabilities;
    }

    private static void assertMetrics(
            ScaleQualityMetrics metrics,
            AndroidChartAnalysis analysis,
            Map<String, Object> expected,
            String vector
    ) {
        check(ScaleRecording.SCORING_MODEL_VERSION.equals(string(expected.get("scoringModelVersion"))), vector + " expected model");
        check(ScaleRecording.SCORING_MODEL_VERSION.equals(metrics.scoringModelVersion), vector + " actual model");
        check(ScoringProfile.STANDARD_BENCHMARK_NAME.equals(metrics.scoringProfileName), vector + " profile");

        Map<String, Object> delivery = object(expected.get("delivery"));
        check(metrics.delivery.applicable == bool(delivery.get("applicable")), vector + " delivery applicable");
        close(metrics.delivery.deliveryScore, nullableInt(delivery.get("deliveryScore")), vector + " delivery score");
        close(metrics.delivery.coverage, nullableDouble(delivery.get("coverage")), vector + " coverage");
        close(metrics.delivery.purity, nullableDouble(delivery.get("purity")), vector + " purity");
        check(nullableBooleanEquals(metrics.delivery.purityIsUpperBound, delivery.get("purityIsUpperBound")), vector + " purity bound");

        Map<String, Object> validity = object(expected.get("validity"));
        check(metrics.validity.isValid == bool(validity.get("isValid")), vector + " validity");
        check(new HashSet<>(metrics.validity.reasons).equals(new HashSet<>(stringArray(validity.get("reasons")))), vector + " validity reasons");
        check(Boolean.valueOf(metrics.signalUnreconstructable).equals(bool(expected.get("signalUnreconstructable"))), vector + " unreconstructable");

        Map<String, Object> frames = object(expected.get("frameClassification"));
        check(metrics.frameClassification.usable == intValue(frames.get("usable")), vector + " usable");
        check(metrics.frameClassification.parseFailure == intValue(frames.get("parseFailure")), vector + " parse failures");
        check(metrics.frameClassification.outOfOrder == intValue(frames.get("outOfOrder")), vector + " out of order");
        check(metrics.frameClassification.stale == intValue(frames.get("stale")), vector + " stale");
        check(metrics.frameClassification.implausible == intValue(frames.get("implausible")), vector + " implausible");
        check(metrics.frameClassification.duplicate == intValue(frames.get("duplicate")), vector + " duplicate");

        Map<String, Object> verification = object(expected.get("protocolVerification"));
        check(set(metrics.protocolVerification.verifiableClasses).equals(set(stringArray(verification.get("verifiableClasses")))), vector + " verifiable classes");
        check(set(metrics.protocolVerification.unverifiableClasses).equals(set(stringArray(verification.get("unverifiableClasses")))), vector + " unverifiable classes");
        check(metrics.protocolVerification.verificationCoveragePercent == intValue(verification.get("verificationCoveragePercent")), vector + " verification coverage");
        check(metrics.protocolVerification.purityIsUpperBound == bool(verification.get("purityIsUpperBound")), vector + " verification bound");

        Map<String, Object> diagnostics = object(expected.get("diagnostics"));
        close(metrics.disconnectCount, nullableInt(diagnostics.get("disconnectCount")), vector + " disconnect count");
        close(metrics.estimatedResolutionGrams, nullableDouble(diagnostics.get("estimatedResolutionGrams")), vector + " resolution");
        close(metrics.excludedFrameCount, nullableInt(diagnostics.get("excludedFrames")), vector + " excluded frames");
        close(metrics.frameRateHz, nullableDouble(diagnostics.get("frameRateHz")), vector + " frame rate");
        close(metrics.packetIntervalMaxMilliseconds, nullableDouble(diagnostics.get("intervalMaxMs")), vector + " max interval");
        close(metrics.packetIntervalP50Milliseconds, nullableDouble(diagnostics.get("intervalP50Ms")), vector + " p50 interval");
        if (diagnostics.containsKey("intervalP95Ms")) {
            close(metrics.packetIntervalP95Milliseconds, nullableDouble(diagnostics.get("intervalP95Ms")), vector + " p95 interval");
        }
        close(metrics.longestUnservedRunMilliseconds, nullableDouble(diagnostics.get("longestUnservedRunMs")), vector + " longest unserved");
        check(Boolean.valueOf(metrics.recordingBoundaryInferred).equals(bool(diagnostics.get("recordingBoundaryInferred"))), vector + " boundary inferred");
        close(metrics.relevantWeightFrameCount, nullableInt(diagnostics.get("relevantWeightFrames")), vector + " relevant frames");
        close(metrics.robustCoefficientOfVariation, nullableDouble(diagnostics.get("robustCoefficientOfVariation")), vector + " robust cv");
        close(metrics.servedSlots, nullableInt(diagnostics.get("servedSlots")), vector + " served slots");
        close(metrics.slotCount, nullableInt(diagnostics.get("slotCount")), vector + " slot count");
        close(metrics.recordingSpanSeconds, nullableDouble(diagnostics.get("spanSeconds")), vector + " span");
        close(metrics.usableRateHz, nullableDouble(diagnostics.get("usableRateHz")), vector + " usable rate");
        close(metrics.usableSampleCount, nullableInt(diagnostics.get("usableSampleCount")), vector + " usable count");

        Map<String, Object> signals = object(expected.get("signalDiagnostics"));
        Map<String, Object> flow = mapOrNull(signals.get("flowValidation"));
        if (flow == null) {
            check(analysis.signalDiagnostics.flowValidation == null, vector + " flow validation absent");
        } else {
            check(analysis.signalDiagnostics.flowValidation != null, vector + " flow validation present");
            close(analysis.signalDiagnostics.flowValidation.sampleCount, nullableInt(flow.get("sampleCount")), vector + " flow sample count");
            close(analysis.signalDiagnostics.flowValidation.medianAbsoluteErrorGramsPerSecond,
                    nullableDouble(flow.get("medianAbsoluteErrorGramsPerSecond")), vector + " flow median error");
            close(analysis.signalDiagnostics.flowValidation.lagMilliseconds,
                    nullableDouble(flow.get("lagMilliseconds")), vector + " flow lag");
            close(analysis.signalDiagnostics.flowValidation.correlation,
                    nullableDouble(flow.get("correlation")), vector + " flow correlation");
        }
        Map<String, Object> clock = mapOrNull(signals.get("clockSkew"));
        if (clock == null) {
            check(analysis.signalDiagnostics.clockSkew == null, vector + " clock skew absent");
        } else {
            check(analysis.signalDiagnostics.clockSkew != null, vector + " clock skew present");
            close(analysis.signalDiagnostics.clockSkew.sampleCount, nullableInt(clock.get("sampleCount")), vector + " clock sample count");
            close(analysis.signalDiagnostics.clockSkew.skewPartsPerMillion,
                    nullableDouble(clock.get("skewPartsPerMillion")), vector + " clock skew ppm");
        }
        Map<String, Object> coalescing = mapOrNull(signals.get("packetCoalescing"));
        if (coalescing == null) {
            check(analysis.signalDiagnostics.packetCoalescing == null, vector + " packet coalescing absent");
        } else {
            check(analysis.signalDiagnostics.packetCoalescing != null, vector + " packet coalescing present");
            close(analysis.signalDiagnostics.packetCoalescing.observedFrameRateHz,
                    nullableDouble(coalescing.get("observedFrameRateHz")), vector + " coalescing observed rate");
            close(analysis.signalDiagnostics.packetCoalescing.servedSlotRateHz,
                    nullableDouble(coalescing.get("servedSlotRateHz")), vector + " coalescing served rate");
            close(analysis.signalDiagnostics.packetCoalescing.framesPerServedSlot,
                    nullableDouble(coalescing.get("framesPerServedSlot")), vector + " coalescing ratio");
        }

        Map<String, Object> idle = mapOrNull(expected.get("idle"));
        close(metrics.stabilityScore, idle == null ? null : nullableInt(idle.get("idleStabilityScore")), vector + " idle score");
        close(metrics.idleNoiseScore, idle == null ? null : nullableInt(idle.get("noiseScore")), vector + " idle noise score");
        close(metrics.idleDriftScore, idle == null ? null : nullableInt(idle.get("driftScore")), vector + " idle drift score");
        close(metrics.idleAnalysedSampleCount, idle == null ? null : nullableInt(idle.get("analysedSampleCount")), vector + " idle analysed");
        close(metrics.idleNoisePeakToPeakGrams, idle == null ? null : nullableDouble(idle.get("residualPeakToPeakGrams")), vector + " idle p2p");
        close(metrics.idleNoiseStandardDeviationGrams, idle == null ? null : nullableDouble(idle.get("residualStandardDeviationGrams")), vector + " idle std dev");
        close(metrics.driftGramsPerMinute, idle == null ? null : nullableDouble(idle.get("driftGramsPerMinute")), vector + " drift");
        close(metrics.idleResolutionGrams, idle == null ? null : nullableDouble(idle.get("resolutionGrams")), vector + " idle resolution");

        Map<String, Object> step = mapOrNull(expected.get("stepResponse"));
        if (step == null) {
            check(metrics.stepResponse == null, vector + " step response absent");
        } else {
            check(metrics.stepResponse != null, vector + " step response present");
            check(metrics.stepResponse.stepDetected == bool(step.get("stepDetected")), vector + " step detected");
            close(metrics.stepResponse.onsetSecondsFromRecordingStart, nullableDouble(step.get("onsetSecondsFromRecordingStart")), vector + " step onset");
            close(metrics.stepResponse.baselineGrams, nullableDouble(step.get("baselineGrams")), vector + " step baseline");
            close(metrics.stepResponse.finalGrams, nullableDouble(step.get("finalGrams")), vector + " step final");
            close(metrics.stepResponse.amplitudeGrams, nullableDouble(step.get("amplitudeGrams")), vector + " step amplitude");
            close(metrics.stepResponse.riseTime10To90Seconds, nullableDouble(step.get("riseTime10To90Seconds")), vector + " step rise");
            close(metrics.stepResponse.settlingTimeSeconds, nullableDouble(step.get("settlingTimeSeconds")), vector + " step settling");
            close(metrics.stepResponse.overshootPercent, nullableDouble(step.get("overshootPercent")), vector + " step overshoot");
        }
    }

    private static PacketRole packetRole(String kind) {
        if ("weight".equals(kind)) return PacketRole.WEIGHT;
        if ("battery".equals(kind)) return PacketRole.BATTERY;
        return PacketRole.UNKNOWN;
    }

    private static RecordingMode mode(String value) {
        switch (value) {
            case "idleStability": return RecordingMode.IDLE_STABILITY;
            case "shot": return RecordingMode.SHOT;
            case "stepResponse": return RecordingMode.STEP_RESPONSE;
            case "transportStress": return RecordingMode.TRANSPORT_STRESS;
            case "tareLatency": return RecordingMode.TARE_LATENCY;
            case "batteryStability": return RecordingMode.BATTERY_STABILITY;
            default: throw new IllegalArgumentException("Unknown mode " + value);
        }
    }

    private static ScaleKind scaleKind(String value) {
        if (value == null || "unknown".equals(value)) return ScaleKind.UNKNOWN;
        switch (value) {
            case "bookoo": return ScaleKind.BOOKOO;
            case "bookooMini": return ScaleKind.BOOKOO_MINI;
            case "bookooUltra": return ScaleKind.BOOKOO_ULTRA;
            case "weighMyBru": return ScaleKind.WEIGH_MY_BRU;
            case "weighMyBruPlus": return ScaleKind.WEIGH_MY_BRU_PLUS;
            default: throw new IllegalStateException("Unknown vector scale kind " + value);
        }
    }

    private static DeviceClockSemantics clockSemantics(String value) {
        if ("freeRunning".equals(value)) return DeviceClockSemantics.FREE_RUNNING;
        if ("shotTimer".equals(value)) return DeviceClockSemantics.SHOT_TIMER;
        return DeviceClockSemantics.NONE;
    }

    private static Object readJson(Path path) {
        try {
            return new JsonParser(new String(Files.readAllBytes(path), StandardCharsets.UTF_8)).parse();
        } catch (IOException error) {
            throw new AssertionError("Could not read " + path + ": " + error.getMessage(), error);
        }
    }

    private static Set<String> set(List<String> values) {
        return new HashSet<>(values);
    }

    private static void close(Integer actual, Integer expected, String label) {
        check(actual == null ? expected == null : actual.equals(expected), label + " expected " + expected + " got " + actual);
    }

    private static void close(Double actual, Double expected, String label) {
        if (actual == null || expected == null) {
            check(actual == null && expected == null, label + " expected " + expected + " got " + actual);
            return;
        }
        check(Math.abs(actual - expected) <= TOLERANCE, label + " expected " + expected + " got " + actual);
    }

    private static boolean nullableBooleanEquals(Boolean actual, Object expected) {
        if (expected == null) return actual == null;
        return actual != null && actual == bool(expected);
    }

    private static Map<String, Object> object(Object value) {
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> result = new LinkedHashMap<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) result.put(String.valueOf(entry.getKey()), entry.getValue());
            return result;
        }
        throw new AssertionError("Expected object, got " + value);
    }

    private static Map<String, Object> mapOrNull(Object value) {
        return value == null ? null : object(value);
    }

    private static List<Object> array(Object value) {
        if (value instanceof List<?> list) return new ArrayList<>(list);
        return new ArrayList<>();
    }

    private static List<String> stringArray(Object value) {
        List<String> strings = new ArrayList<>();
        for (Object item : array(value)) strings.add(string(item));
        return strings;
    }

    private static String string(Object value) {
        if (value == null) throw new AssertionError("Expected string, got null");
        return String.valueOf(value);
    }

    private static String stringOrNull(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static boolean bool(Object value) {
        if (value instanceof Boolean booleanValue) return booleanValue;
        throw new AssertionError("Expected boolean, got " + value);
    }

    private static int intValue(Object value) {
        Integer number = nullableInt(value);
        if (number == null) throw new AssertionError("Expected int, got null");
        return number;
    }

    private static double doubleValue(Object value) {
        Double number = nullableDouble(value);
        if (number == null) throw new AssertionError("Expected double, got null");
        return number;
    }

    private static Integer nullableInt(Object value) {
        if (value == null) return null;
        return ((Number) value).intValue();
    }

    private static Long nullableLong(Object value) {
        if (value == null) return null;
        return ((Number) value).longValue();
    }

    private static Double nullableDouble(Object value) {
        if (value == null) return null;
        return ((Number) value).doubleValue();
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }

    private static final class JsonParser {
        private final String text;
        private int index;

        JsonParser(String text) {
            this.text = text;
        }

        Object parse() {
            Object value = parseValue();
            skipWhitespace();
            if (index != text.length()) throw error("Unexpected trailing text");
            return value;
        }

        private Object parseValue() {
            skipWhitespace();
            if (index >= text.length()) throw error("Unexpected end of JSON");
            char c = text.charAt(index);
            if (c == '{') return parseObject();
            if (c == '[') return parseArray();
            if (c == '"') return parseString();
            if (c == 't') return parseLiteral("true", Boolean.TRUE);
            if (c == 'f') return parseLiteral("false", Boolean.FALSE);
            if (c == 'n') return parseLiteral("null", null);
            return parseNumber();
        }

        private Map<String, Object> parseObject() {
            expect('{');
            Map<String, Object> object = new LinkedHashMap<>();
            skipWhitespace();
            if (peek('}')) {
                index++;
                return object;
            }
            while (true) {
                String key = parseString();
                skipWhitespace();
                expect(':');
                object.put(key, parseValue());
                skipWhitespace();
                if (peek('}')) {
                    index++;
                    return object;
                }
                expect(',');
            }
        }

        private List<Object> parseArray() {
            expect('[');
            List<Object> array = new ArrayList<>();
            skipWhitespace();
            if (peek(']')) {
                index++;
                return array;
            }
            while (true) {
                array.add(parseValue());
                skipWhitespace();
                if (peek(']')) {
                    index++;
                    return array;
                }
                expect(',');
            }
        }

        private String parseString() {
            expect('"');
            StringBuilder builder = new StringBuilder();
            while (index < text.length()) {
                char c = text.charAt(index++);
                if (c == '"') return builder.toString();
                if (c == '\\') {
                    if (index >= text.length()) throw error("Unterminated escape");
                    char escaped = text.charAt(index++);
                    switch (escaped) {
                        case '"': builder.append('"'); break;
                        case '\\': builder.append('\\'); break;
                        case '/': builder.append('/'); break;
                        case 'b': builder.append('\b'); break;
                        case 'f': builder.append('\f'); break;
                        case 'n': builder.append('\n'); break;
                        case 'r': builder.append('\r'); break;
                        case 't': builder.append('\t'); break;
                        case 'u':
                            String hex = text.substring(index, index + 4);
                            builder.append((char) Integer.parseInt(hex, 16));
                            index += 4;
                            break;
                        default:
                            throw error("Bad escape");
                    }
                } else {
                    builder.append(c);
                }
            }
            throw error("Unterminated string");
        }

        private Object parseLiteral(String literal, Object value) {
            if (!text.startsWith(literal, index)) throw error("Expected " + literal);
            index += literal.length();
            return value;
        }

        private Number parseNumber() {
            int start = index;
            if (peek('-')) index++;
            while (index < text.length() && Character.isDigit(text.charAt(index))) index++;
            if (peek('.')) {
                index++;
                while (index < text.length() && Character.isDigit(text.charAt(index))) index++;
            }
            if (peek('e') || peek('E')) {
                index++;
                if (peek('+') || peek('-')) index++;
                while (index < text.length() && Character.isDigit(text.charAt(index))) index++;
            }
            String raw = text.substring(start, index);
            return raw.contains(".") || raw.contains("e") || raw.contains("E") ? Double.parseDouble(raw) : Long.parseLong(raw);
        }

        private void skipWhitespace() {
            while (index < text.length() && Character.isWhitespace(text.charAt(index))) index++;
        }

        private boolean peek(char c) {
            return index < text.length() && text.charAt(index) == c;
        }

        private void expect(char c) {
            skipWhitespace();
            if (!peek(c)) throw error("Expected " + c);
            index++;
        }

        private IllegalArgumentException error(String message) {
            return new IllegalArgumentException(message + " at " + index);
        }
    }
}
