package app.scalebench.android;

import org.junit.Test;

public final class CoreSmokeTest {
    public static void main(String[] args) {
        runAll();
        System.out.println("Core smoke tests passed");
    }

    @Test
    public void coreContracts() {
        runAll();
    }

    private static void runAll() {
        testWmbPlusCapabilitiesParse();
        testWmbPlusExtendedPacketParse();
        testWmbPlusUsbSerialParser();
        testBookooPacketParse();
        testAdditionalParsers();
        testStandardV1RateAnchors();
        testHighWaterAndClockSemantics();
        testModeAwareClassificationAndValidity();
        testCompoundingErrorsAndRecordingEdges();
        testSampleRecordings();
        testChartAnalysisFindsGapsAndPacketPenalties();
        testLegacyWmbPlusDualTransportUsesTwentyByteStreamOnly();
        testChartAnalysisUsesRecordingStartForEverySeries();
        testOfficialAnalysisPayload();
        testSharedRecordingFixtures();
        testSharedRecordingImportDecoder();
        testSharedRecordingImportRejectsInvalidContractValues();
        testAndroidRecordingExportUsesSharedEnumNames();
        testAndroidRecordingGzipExportRoundTrips();
        testOfficialScorecardPayload();
        testBackupDeletionByRecordingId();
        testCorruptRecordingRecoversFromNewestReadableBackup();
        GoldenVectorSmokeTest.run();
    }

    private static void testWmbPlusCapabilitiesParse() {
        byte[] data = bytes(0x03, 0x0C, 0x01, 0x10, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x07, 0x00, 0x01, 0x14, 0x00, 0x8D);
        WmbPlusCapabilities capabilities = ScaleParsers.parseCapabilities(data);
        check(capabilities != null, "capabilities parsed");
        check(capabilities.featureMask == 0x0000_7FFFL, "feature mask");
        check(capabilities.preferredAtomicCommand == 0x07, "preferred command");
        check(capabilities.supportsExtendedPacket(), "extended packet");
    }

    private static void testWmbPlusExtendedPacketParse() {
        WmbPlusCapabilities capabilities = ScaleParsers.parseCapabilities(
                bytes(0x03, 0x0C, 0x01, 0x10, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x07, 0x00, 0x01, 0x14, 0x00, 0x8D)
        );
        byte[] packet = bytes(
                0x03, 0x0B,
                0x00, 0x12, 0x34,
                0x01,
                0x2B, 0x00, 0x09, 0xC4,
                0x2B, 0x00, 0xFA,
                0x55,
                0xFE,
                0x43,
                0x61,
                0x0C,
                0xEC,
                0x00
        );
        packet[19] = (byte) xor(packet, 19);
        ParserResult result = ScaleParsers.parseWmb20(packet, capabilities, 0, 10);
        check(result.isSample(), "wmb sample");
        ScaleSample sample = result.sample;
        check(sample.scaleKind == ScaleKind.WEIGH_MY_BRU_PLUS, "wmb kind");
        close(sample.weightGrams, 25.0, "wmb weight");
        close(sample.flowGramsPerSecond, 2.5, "wmb flow");
        check(sample.batteryPercent == 85, "wmb battery");
        check(sample.sequence == 254, "wmb sequence");
        check(sample.statusFlags.timerRunning, "timer flag");
        check(sample.statusFlags.batteryPresent, "battery present");
        check(sample.firmwareQualityScore == 97, "quality");
        check(sample.detectedSampleRateHz == 12, "sample rate");
        check(sample.diagnosticFlags.extensionPresent, "extension flag");
        check(sample.diagnosticFlags.detected80Sps, "80 SPS flag");
    }

    private static void testWmbPlusUsbSerialParser() {
        WMBPlusUSBSerialParser parser = new WMBPlusUSBSerialParser();
        WMBPlusUSBSerialParser.ParseResult header = parser.parse(
                WMBPlusUSBSerialParser.HEADER,
                1_000,
                1.0
        );
        check(header.ignored, "usb header ignored");

        String line = "WMBP_WEIGHT_V1,123456,9821,18.423,1.731,0x0041,98,75,79.82,0";
        WMBPlusUSBSerialParser.ParseResult result = parser.parse(line, 2_000, 2.0);
        check(!result.ignored && result.sample != null && result.packet != null, "usb sample parsed");
        check(result.sample.statusFlags.hx711Connected, "usb hx711 valid");
        close(result.sample.weightGrams, 18.423, "usb weight");
        check(result.sample.batteryPercent == 75, "usb battery");
        check(result.sample.usbSerial.sequenceNumber == 9821L, "usb sequence");
        check(result.sample.usbSerial.usbStatusLabels.contains("HX711 connected"), "usb status label");
        check(result.packet.bytesHex.equals(ScaleParsers.hex(line.getBytes(java.nio.charset.StandardCharsets.UTF_8))), "usb raw row encoded as hex");
        check(new String(ScaleParsers.parseHex(result.packet.bytesHex), java.nio.charset.StandardCharsets.UTF_8).equals(line), "usb raw hex round trip");

        WMBPlusUSBSerialParser.ParseResult dropped = parser.parse(
                "WMBP_WEIGHT_V1,123506,9822,18.500,1.500,0x0041,98,75,79.82,3",
                2_050,
                2.05
        );
        check(dropped.sample.usbSerial.usbDroppedDelta == 3L, "usb dropped delta");

        WMBPlusUSBSerialParser.ParseResult noHx711 = parser.parse(
                "WMBP_WEIGHT_V1,123556,9823,18.500,1.500,0x0040,98,75,79.82,3",
                2_100,
                2.1
        );
        check(noHx711.sample != null && !noHx711.sample.statusFlags.hx711Connected, "usb hx711 invalid");

        WMBPlusUSBSerialParser.ParseResult invalid = parser.parse(
                "WMBP_WEIGHT_V1,1,2,not-a-number,1.0,0x0041,98,75,79.82,0",
                2_150,
                2.15
        );
        check(!invalid.ignored && invalid.sample == null && invalid.rejectionReason != null, "usb invalid numeric rejected");
    }

    private static void testBookooPacketParse() {
        byte[] packet = bytes(
                0x03, 0x0B,
                0x00, 0x10, 0x00,
                0x02,
                0x2D, 0x00, 0x00, 0x64,
                0x2B, 0x00, 0xC8,
                0x63,
                0, 30, 2, 0, 1, 0
        );
        packet[19] = (byte) xor(packet, 19);
        ParserResult result = ScaleParsers.parseBookoo(packet, ScaleKind.BOOKOO_ULTRA, 0, 1);
        check(result.isSample(), "bookoo sample");
        ScaleSample sample = result.sample;
        check(sample.scaleKind == ScaleKind.BOOKOO_ULTRA, "bookoo kind");
        close(sample.weightGrams, -1.0, "bookoo weight");
        close(sample.flowGramsPerSecond, 2.0, "bookoo flow");
        check(sample.batteryPercent == 99, "bookoo battery");
    }

    private static void testAdditionalParsers() {
        byte[] acaiaFrame = bytes(0xEF, 0xDD, 0x0C, 0x04, 0x7B, 0x00, 0x01, 0x00, 0x7C, 0x00);
        ParserResult acaia = new AcaiaCodec().receive(acaiaFrame, 0, 1).get(0);
        check(acaia.isSample(), "acaia sample");
        close(acaia.sample.weightGrams, 12.3, "acaia weight");

        ParserResult decent = ScaleParsers.parseDecentEspressi(bytes(0x03, 0xCE, 0x00, 0x7B, 0x00, 0x01, 0x02, 0x03, 0x00, 0x00), ScaleKind.DECENT, 0, 1);
        check(decent.isSample(), "decent sample");
        close(decent.sample.weightGrams, 12.3, "decent weight");
        check(decent.sample.deviceTimestampMilliseconds == 62_300L, "decent timestamp");

        ParserResult difluidSensor = ScaleParsers.parseDiFluid(bytes(0xDF, 0xDF, 0x03, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x7B, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0x00, 0x00), ScaleKind.DIFLUID_TI, 0, 1);
        byte[] difluidBytes = bytes(0xDF, 0xDF, 0x03, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x7B, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0x00, 0x00);
        difluidBytes[difluidBytes.length - 1] = (byte) additive(difluidBytes, difluidBytes.length - 1);
        difluidSensor = ScaleParsers.parseDiFluid(difluidBytes, ScaleKind.DIFLUID_TI, 0, 1);
        check(difluidSensor.isSample(), "difluid sample");
        close(difluidSensor.sample.weightGrams, 12.3, "difluid weight");

        ParserResult eureka = ScaleParsers.parseEureka(bytes(0xAA, 0x09, 0x41, 0x00, 0x1D, 0x00, 0x00, 0x7B, 0x00, 0x00, 0x00), 0, 1);
        check(eureka.isSample(), "eureka sample");
        close(eureka.sample.weightGrams, 12.3, "eureka weight");

        byte[] felicitaBytes = bytes(0, 0, 0x2D, 0x30, 0x30, 0x30, 0x31, 0x32, 0x33, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        ParserResult felicita = ScaleParsers.parseFelicita(felicitaBytes, 0, 1);
        check(felicita.isSample(), "felicita sample");
        close(felicita.sample.weightGrams, -1.23, "felicita weight");

        ParserResult futula = ScaleParsers.parseFutula(bytes(0, 0, 0, 0x7B, 0x00, 0x01, 0, 0, 0), 0, 1);
        check(futula.isSample(), "futula sample");
        close(futula.sample.weightGrams, -12.3, "futula weight");

        ParserResult skale = ScaleParsers.parseSkale2(bytes(0x00, 0x7B, 0x00), 0, 1);
        check(skale.isSample(), "skale sample");
        close(skale.sample.weightGrams, 12.3, "skale weight");

        byte[] timemoreFrame = ScaleParsers.timemoreFrame(0x01, 0x01, new int[] {0x00, 0x00, 0x00, 0x7B, 0, 0, 0, 0});
        ParserResult timemore = new TimemoreDotCodec().receive(timemoreFrame, 0, 1).get(0);
        check(timemore.isSample(), "timemore sample");
        close(timemore.sample.weightGrams, 12.3, "timemore weight");
    }

    private static void testStandardV1RateAnchors() {
        ScaleQualityMetrics clean20 = ScaleQualityAnalyzer.analyze(shotRecording(20, 30));
        check(clean20.delivery.deliveryScore == 100, "clean 20 Hz delivery");
        close(clean20.delivery.coverage, 1.0, "clean 20 Hz coverage");
        close(clean20.delivery.purity, 1.0, "clean 20 Hz purity");

        ScaleQualityMetrics clean10 = ScaleQualityAnalyzer.analyze(shotRecording(10, 30));
        check(clean10.delivery.deliveryScore == 50, "clean 10 Hz delivery");
        close(clean10.delivery.coverage, 0.5, "clean 10 Hz coverage");
        close(clean10.delivery.purity, 1.0, "clean 10 Hz purity");
        check(ScaleRecording.SCORING_MODEL_VERSION.equals(clean20.scoringModelVersion), "model version");
    }

    private static void testHighWaterAndClockSemantics() {
        ScaleRecording sequence = shotRecording(20, 30);
        for (int i = 0; i < sequence.samples.size(); i++) sequence.samples.get(i).sequence = i & 0xFF;
        sequence.samples.get(100).sequence = 90;
        sequence.samples.get(101).sequence = 95;
        sequence.protocolCapabilities = capabilities(false, true, false, DeviceClockSemantics.NONE);
        ScaleQualityMetrics sequenceMetrics = ScaleQualityAnalyzer.analyze(sequence);
        check(sequenceMetrics.frameClassification.outOfOrder == 2, "sequence high water");

        ScaleRecording clock = shotRecording(20, 30);
        for (int i = 0; i < clock.samples.size(); i++) clock.samples.get(i).deviceTimestampMilliseconds = (long) i * 50;
        clock.samples.get(100).deviceTimestampMilliseconds = 4_500L;
        clock.samples.get(101).deviceTimestampMilliseconds = 4_750L;
        clock.protocolCapabilities = capabilities(false, false, true, DeviceClockSemantics.FREE_RUNNING);
        ScaleQualityMetrics clockMetrics = ScaleQualityAnalyzer.analyze(clock);
        check(clockMetrics.frameClassification.stale == 2, "clock high water");

        ScaleRecording timer = shotRecording(20, 30);
        for (ScaleSample sample : timer.samples) {
            sample.deviceTimestampMilliseconds = (long) ((sample.monotonicSeconds % 1.0) * 1000);
        }
        timer.protocolCapabilities = capabilities(false, false, true, DeviceClockSemantics.SHOT_TIMER);
        ScaleQualityMetrics timerMetrics = ScaleQualityAnalyzer.analyze(timer);
        check(timerMetrics.frameClassification.stale == 0, "shot timer is not freshness clock");
        check(timerMetrics.delivery.deliveryScore == 100, "shot timer delivery");
    }

    private static void testModeAwareClassificationAndValidity() {
        ScaleRecording stress = recording(RecordingMode.TRANSPORT_STRESS, 20, 130);
        for (int i = 0; i < stress.samples.size(); i++) {
            stress.samples.get(i).weightGrams = i % 2 == 0 ? -100 : 100;
        }
        ScaleQualityMetrics stressMetrics = ScaleQualityAnalyzer.analyze(stress);
        check(stressMetrics.frameClassification.implausible == 0, "stress ignores weight physics");
        check(stressMetrics.delivery.deliveryScore == 100, "stress delivery");

        ScaleRecording missingBoundaries = shotRecording(20, 30);
        missingBoundaries.recordingStartMonotonicSeconds = null;
        missingBoundaries.recordingEndMonotonicSeconds = null;
        ScaleQualityMetrics invalid = ScaleQualityAnalyzer.analyze(missingBoundaries);
        check(!invalid.validity.isValid, "missing boundaries invalid");
        check(invalid.validity.reasons.contains("recordingBoundariesMissing"), "missing boundary reason");
        check(invalid.delivery.deliveryScore == null, "invalid has no official score");

        ScaleRecording idle = recording(RecordingMode.IDLE_STABILITY, 20, 70);
        for (int i = 0; i < idle.samples.size(); i++) idle.samples.get(i).weightGrams = 0.001 * (i % 3);
        ScaleQualityMetrics idleMetrics = ScaleQualityAnalyzer.analyze(idle);
        check(idleMetrics.validity.isValid, "idle valid");
        check(idleMetrics.stabilityScore != null, "idle score");
        check(idleMetrics.transportScore == null, "idle has no delivery score");
    }

    private static void testCompoundingErrorsAndRecordingEdges() {
        ScaleRecording quarterParseable = shotRecording(80, 30);
        materializeRawPackets(quarterParseable);
        for (int i = 0; i < quarterParseable.rawPackets.size(); i++) {
            if (i % 4 != 0) {
                quarterParseable.rawPackets.get(i).rejectionReason = ParseRejectionReason.INVALID_CHECKSUM;
                quarterParseable.rawPackets.get(i).weightGrams = null;
            }
        }
        quarterParseable.protocolCapabilities = capabilities(true, false, false, DeviceClockSemantics.NONE);
        ScaleQualityMetrics quarterMetrics = ScaleQualityAnalyzer.analyze(quarterParseable);
        check(quarterMetrics.delivery.deliveryScore == 25, "80 Hz quarter parseable score");
        close(quarterMetrics.delivery.coverage, 1.0, "80 Hz quarter parseable coverage");
        close(quarterMetrics.delivery.purity, 0.25, "80 Hz quarter parseable purity");

        ScaleRecording parseFirst = shotRecording(20, 30);
        materializeRawPackets(parseFirst);
        RawScalePacket rejected = parseFirst.rawPackets.get(100);
        rejected.rejectionReason = ParseRejectionReason.INVALID_CHECKSUM;
        rejected.weightGrams = parseFirst.rawPackets.get(99).weightGrams;
        ScaleQualityMetrics parseFirstMetrics = ScaleQualityAnalyzer.analyze(parseFirst);
        check(parseFirstMetrics.frameClassification.parseFailure == 1, "parse failure precedes duplicate");

        ScaleRecording trailingOutage = recording(RecordingMode.TRANSPORT_STRESS, 20, 130);
        trailingOutage.samples.removeIf(sample -> sample.monotonicSeconds >= 120);
        ScaleQualityMetrics outageMetrics = ScaleQualityAnalyzer.analyze(trailingOutage);
        check(outageMetrics.delivery.deliveryScore == 92, "trailing outage remains in coverage");
        check(outageMetrics.longestUnservedRunMilliseconds >= 9_950, "trailing outage duration");

        ScaleRecording shortIdle = recording(RecordingMode.IDLE_STABILITY, 1, 3);
        shortIdle.recordingEndMonotonicSeconds = 60.0;
        ScaleQualityMetrics shortIdleMetrics = ScaleQualityAnalyzer.analyze(shortIdle);
        check(!shortIdleMetrics.validity.isValid, "three-frame idle invalid");
        check(shortIdleMetrics.stabilityScore == null, "invalid idle has no score");

        ScaleRecording step = recording(RecordingMode.STEP_RESPONSE, 20, 24);
        for (ScaleSample sample : step.samples) {
            double t = sample.monotonicSeconds;
            sample.weightGrams = t < 5 ? 0 : t < 5.3 ? (t - 5) / 0.3 * 20 : 20;
        }
        ScaleQualityMetrics stepMetrics = ScaleQualityAnalyzer.analyze(step);
        check(stepMetrics.validity.isValid, "step valid");
        check(stepMetrics.stepResponse.stepDetected, "step detected");
        check(stepMetrics.overallScore == null, "step is metrics only");
    }

    private static void testSampleRecordings() {
        java.util.List<SampleRecordingFactory.Example> examples = SampleRecordingFactory.examples();
        check(examples.size() == 3, "three sample recordings");

        ScaleRecording clean = examples.get(0).recording;
        check(clean.device.kind == ScaleKind.WEIGH_MY_BRU_PLUS, "clean example kind");
        check(clean.samples.size() == 360, "clean example samples");
        check(clean.rawPackets.size() > clean.samples.size(), "clean example battery packets");
        check(clean.batteryEvents.size() > 0, "clean example battery events");
        check(clean.samples.get(0).sequence == 0, "clean example sequence");
        check(clean.protocolCapabilities.hasSequence, "clean example sequence capability");
        check(clean.protocolCapabilities.hasDeviceClock, "clean example clock capability");
        check(clean.metrics.validity.isValid, "clean example valid");
        check(clean.metrics.overallScore != null, "clean example score");

        ScaleRecording legacy = examples.get(1).recording;
        check(legacy.device.kind == ScaleKind.WEIGH_MY_BRU, "legacy example kind");
        check(legacy.samples.size() == 249, "legacy example samples");
        check(!legacy.protocolCapabilities.hasSequence, "legacy example has no sequence");
        check(legacy.metrics.validity.isValid, "legacy example valid");

        ScaleRecording noisy = examples.get(2).recording;
        check(noisy.device.kind == ScaleKind.EUREKA, "noisy example kind");
        check(noisy.samples.size() == 330, "noisy example samples");
        check(noisy.rawPackets.size() == noisy.samples.size() + 3, "noisy example rejected packets");
        check(noisy.metrics.rejectedPacketCount == 3, "noisy example rejection count");
        check(noisy.metrics.longGapCount >= 1, "noisy example gap");
    }

    private static void testChartAnalysisFindsGapsAndPacketPenalties() {
        ScaleRecording recording = shotRecording(20, 30);
        recording.samples.removeIf(sample -> sample.monotonicSeconds > 5.0 && sample.monotonicSeconds < 5.5);
        materializeRawPackets(recording);
        RawScalePacket rejected = recording.rawPackets.get(10);
        rejected.rejectionReason = ParseRejectionReason.INVALID_CHECKSUM;
        rejected.weightGrams = null;

        ScaleQualityMetrics metrics = ScaleQualityAnalyzer.analyze(recording);
        AndroidChartAnalysis analysis = ChartAnalysis.create(recording, metrics);

        check(analysis.weightPoints.size() == recording.samples.size(), "chart analysis weight points");
        check(analysis.packetTimeline.scoringGaps.size() == 1, "chart analysis scoring gap");
        check(analysis.packetTimeline.entries.stream().anyMatch(entry -> entry.severity == AndroidPacketSeverity.PENALTY), "chart analysis packet penalty");
        check(analysis.problemWindows.get(0).category == AndroidChartProblemCategory.GAP, "chart analysis problem window");
        check(!analysis.deductionBreakdown.isEmpty(), "chart analysis deductions");
    }

    private static void testLegacyWmbPlusDualTransportUsesTwentyByteStreamOnly() {
        ScaleRecording recording = ScaleRecording.empty(RecordingMode.SHOT);
        recording.device = new ScaleDeviceIdentity();
        recording.device.name = "Legacy WMB+";
        recording.device.identifier = "legacy";
        recording.device.kind = ScaleKind.WEIGH_MY_BRU;
        recording.recordingStartMonotonicSeconds = 0.0;
        recording.recordingEndMonotonicSeconds = 30.0;

        for (int i = 0; i < 300; i++) {
            double baseTime = i / 10.0;
            double weight = i / 100.0;

            ScaleSample twentyByteSample = new ScaleSample();
            twentyByteSample.arrivalTimeMillis = Math.round(baseTime * 1000.0);
            twentyByteSample.monotonicSeconds = baseTime;
            twentyByteSample.scaleKind = ScaleKind.WEIGH_MY_BRU;
            twentyByteSample.weightGrams = weight;

            ScaleSample floatSample = new ScaleSample();
            floatSample.arrivalTimeMillis = Math.round((baseTime + 0.002) * 1000.0);
            floatSample.monotonicSeconds = baseTime + 0.002;
            floatSample.scaleKind = ScaleKind.WEIGH_MY_BRU;
            floatSample.weightGrams = weight;

            recording.samples.add(twentyByteSample);
            recording.samples.add(floatSample);

            RawScalePacket twentyBytePacket = new RawScalePacket();
            twentyBytePacket.arrivalTimeMillis = twentyByteSample.arrivalTimeMillis;
            twentyBytePacket.monotonicSeconds = twentyByteSample.monotonicSeconds;
            twentyBytePacket.scaleKind = ScaleKind.WEIGH_MY_BRU;
            twentyBytePacket.characteristicUuid = ScaleParsers.WMB_WEIGHT20_UUID;
            twentyBytePacket.role = PacketRole.WEIGHT;
            twentyBytePacket.bytesHex = "";
            twentyBytePacket.weightGrams = weight;
            recording.rawPackets.add(twentyBytePacket);

            RawScalePacket floatPacket = new RawScalePacket();
            floatPacket.arrivalTimeMillis = floatSample.arrivalTimeMillis;
            floatPacket.monotonicSeconds = floatSample.monotonicSeconds;
            floatPacket.scaleKind = ScaleKind.WEIGH_MY_BRU;
            floatPacket.characteristicUuid = ScaleParsers.WMB_FLOAT32_UUID;
            floatPacket.role = PacketRole.WEIGHT;
            floatPacket.bytesHex = "";
            floatPacket.weightGrams = weight;
            recording.rawPackets.add(floatPacket);
        }

        ScaleQualityMetrics metrics = ScaleQualityAnalyzer.analyze(recording);
        AndroidChartAnalysis analysis = ChartAnalysis.create(recording, metrics);

        check(metrics.usableSampleCount == 300, "legacy WMB+ usable count");
        double expectedUsableRate = 300.0 / 29.9;
        check(metrics.effectiveSampleRateHz != null
                && Math.abs(metrics.effectiveSampleRateHz - expectedUsableRate) <= 0.01, "legacy WMB+ effective rate");
        check(analysis.weightPoints.size() == 300, "legacy WMB+ chart points");
    }

    private static void testChartAnalysisUsesRecordingStartForEverySeries() {
        ScaleRecording recording = shotRecording(20, 3);
        recording.samples.removeIf(sample -> sample.monotonicSeconds < 1.0);
        materializeRawPackets(recording);
        RawScalePacket metadata = new RawScalePacket();
        metadata.arrivalTimeMillis = 250;
        metadata.monotonicSeconds = 0.25;
        metadata.scaleKind = ScaleKind.WEIGH_MY_BRU;
        metadata.characteristicUuid = "BATTERY";
        metadata.role = PacketRole.BATTERY;
        metadata.bytesHex = "64";
        recording.rawPackets.add(metadata);

        AndroidChartAnalysis analysis = ChartAnalysis.create(
                recording,
                ScaleQualityAnalyzer.analyze(recording)
        );

        close(analysis.weightPoints.get(0).seconds, 1.0, "chart weight origin");
        close(analysis.packetTimeline.entries.get(0).relativeSeconds, 0.25, "chart packet origin");
        close(analysis.packetTimeline.sampleIntervals.get(0).previousRelativeSeconds, 0.0, "chart interval origin");
        close(analysis.packetTimeline.sampleIntervals.get(0).relativeSeconds, 1.0, "chart leading interval end");
        close(analysis.packetTimeline.scoringGaps.get(0).startSeconds, 0.0, "chart leading gap start");
        close(analysis.packetTimeline.getDurationSeconds(), 3.0, "chart recording duration");
    }

    private static void testOfficialAnalysisPayload() {
        ScaleRecording recording = shotRecording(20, 30);
        recording.samples.removeIf(sample -> sample.monotonicSeconds > 5.0 && sample.monotonicSeconds < 5.5);
        materializeRawPackets(recording);
        RawScalePacket rejected = recording.rawPackets.get(10);
        rejected.rejectionReason = ParseRejectionReason.INVALID_CHECKSUM;
        rejected.weightGrams = null;

        OfficialAnalysisPayload payload = OfficialAnalysisPayload.make(recording, 1_785_600_005_000L);

        check(payload.schemaVersion == OfficialAnalysisPayload.SCHEMA_VERSION, "analysis schema version");
        check(recording.id.equals(payload.recordingId), "analysis recording id");
        check(payload.chartAnalysis.schemaVersion == 1, "analysis chart schema");
        check(payload.chartAnalysis.weightPoints.size() == recording.samples.size(), "analysis weight points");
        check(payload.chartAnalysis.packetTimeline.scoringGaps.size() == 1, "analysis scoring gaps");
        check(payload.chartAnalysis.packetTimeline.entries.stream().anyMatch(entry -> "penalty".equals(entry.severity)), "analysis penalty severity");
        check("gap".equals(payload.chartAnalysis.problemWindows.get(0).category), "analysis problem category");
        check(payload.metrics.longGapCount == recording.metrics.longGapCount, "analysis metrics shared");

        try {
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            JsonExporter.writeOfficialAnalysis(recording, output, 1_785_600_005_000L);
            String json = output.toString(java.nio.charset.StandardCharsets.UTF_8);
            writeContractOutput("android-analysis.json", json);
            writeContractOutput(
                    "android-chart-analysis.json",
                    new org.json.JSONObject(json).getJSONObject("chartAnalysis").toString(2)
            );
            check(json.contains("\"chartAnalysis\""), "analysis json chart");
            check(json.contains("\"packetTimeline\""), "analysis json timeline");
            check(json.contains("\"severity\": \"penalty\""), "analysis json penalty");
        } catch (Exception error) {
            throw new AssertionError("Official analysis export failed: " + error.getMessage(), error);
        }

        String fixture = sharedFixture("official-analysis.json");
        check(intField(fixture, "schemaVersion") == OfficialAnalysisPayload.SCHEMA_VERSION, "analysis fixture schema");
        check(stringField(fixture, "recordingId").equals("44444444-4444-4444-8444-444444444444"), "analysis fixture id");
        check(fixture.contains("\"bytesHex\": \"03 0B 00\""), "analysis fixture packet bytes");
    }

    private static void testSharedRecordingFixtures() {
        String ios = sharedFixture("ios-recording.json");
        check(stringField(ios, "id").equals("11111111-aaaa-4aaa-8aaa-111111111111"), "ios fixture id");
        check(stringField(ios, "platform").equals("ios"), "ios fixture platform");
        check(stringField(ios, "title").equals("Fixture iOS WMB+ Shot"), "ios fixture title");
        check(stringField(ios, "mode").equals("shot"), "ios fixture mode");
        check(stringField(ios, "kind").equals("weighMyBruPlus"), "ios fixture protocol kind");
        check(countObjectsInArray(ios, "samples") == 3, "ios fixture samples");
        check(countObjectsInArray(ios, "rawPackets") == 3, "ios fixture packets");
        check(ios.contains("\"arrivalTimeMillis\""), "ios fixture shared time key");
        check(!ios.contains("\"arrivalTime\""), "ios fixture avoids swift date key");

        String android = sharedFixture("android-recording.json");
        check(stringField(android, "id").equals("22222222-bbbb-4bbb-8bbb-222222222222"), "android fixture id");
        check(stringField(android, "platform").equals("android"), "android fixture platform");
        check(stringField(android, "title").equals("Fixture Android Eureka Shot"), "android fixture title");
        check(stringField(android, "kind").equals("eureka"), "android fixture protocol kind");
        check(countObjectsInArray(android, "samples") == 3, "android fixture samples");
        check(countObjectsInArray(android, "rawPackets") == 3, "android fixture packets");
        check(android.contains("\"rejectionReason\": \"invalidLength\""), "android fixture rejection");
    }

    private static void testSharedRecordingImportDecoder() {
        try {
            ScaleRecording ios = SavedRecordingStore.decodeSharedRecording(sharedFixture("ios-recording.json"));
            check("11111111-aaaa-4aaa-8aaa-111111111111".equals(ios.id), "import ios id");
            check("Fixture iOS WMB+ Shot".equals(ios.title), "import ios title");
            check(ios.platform.equals("ios"), "import ios platform");
            check(ios.mode == RecordingMode.SHOT, "import ios mode");
            check(ios.device.kind == ScaleKind.WEIGH_MY_BRU_PLUS, "import ios kind");
            check(ios.samples.size() == 3, "import ios samples");
            check(ios.rawPackets.size() == 3, "import ios packets");
            check(ios.samples.get(0).statusFlags != null && ios.samples.get(0).statusFlags.timerRunning, "import ios status flags");
            check(ios.samples.get(0).diagnosticFlags != null && ios.samples.get(0).diagnosticFlags.recentBump, "import ios diagnostic flags");
            ios.metrics = ScaleQualityAnalyzer.analyze(ios);
            check(ios.metrics.scoringModelVersion.equals(ScaleRecording.SCORING_MODEL_VERSION), "import recalculates model");

            ScaleRecording android = SavedRecordingStore.decodeSharedRecording(sharedFixture("android-recording.json"));
            check("22222222-bbbb-4bbb-8bbb-222222222222".equals(android.id), "import android id");
            check("Fixture Android Eureka Shot".equals(android.title), "import android title");
            check(android.device.kind == ScaleKind.EUREKA, "import android kind");
            check("AA:BB:CC:DD:EE:FF".equals(android.device.identifier), "import android device identifier");
            check(android.rawPackets.get(1).rejectionReason == ParseRejectionReason.INVALID_LENGTH, "import lower-camel rejection");
        } catch (Exception error) {
            throw new AssertionError("Shared recording import decode failed: " + error.getMessage(), error);
        }
    }

    private static void testSharedRecordingImportRejectsInvalidContractValues() {
        String fixture = sharedFixture("android-recording.json");
        expectImportFailure(fixture.replace("\"mode\": \"shot\"", "\"mode\": \"mystery\""), "unknown mode rejected");
        expectImportFailure(fixture.replace("\"schemaVersion\": 6", "\"schemaVersion\": 5"), "old schema rejected");
        expectImportFailure(fixture.replaceFirst("AA 09 41", "AA0941"), "compact hex rejected");
    }

    private static void testAndroidRecordingExportUsesSharedEnumNames() {
        try {
            ScaleRecording recording = shotRecording(20, 30);
            materializeRawPackets(recording);
            recording.rawPackets.get(0).rejectionReason = ParseRejectionReason.INVALID_CRC;
            recording.rawPackets.get(0).weightGrams = null;
            recording.samples.get(0).statusFlags = new ScaleStatusFlags(0xC3);
            recording.samples.get(0).diagnosticFlags = new ScaleDiagnosticFlags(0xED);
            ScaleRecordingEvent backgrounded = new ScaleRecordingEvent();
            backgrounded.type = RecordingEventType.APP_BACKGROUNDED;
            backgrounded.monotonicSeconds = 12.0;
            recording.events.add(backgrounded);
            ScaleRecordingEvent foregrounded = new ScaleRecordingEvent();
            foregrounded.type = RecordingEventType.APP_FOREGROUNDED;
            foregrounded.monotonicSeconds = 13.0;
            recording.events.add(foregrounded);

            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            JsonExporter.writeRecording(recording, output);
            String json = output.toString(java.nio.charset.StandardCharsets.UTF_8);
            writeContractOutput("android-recording.json", json);

            check(json.contains("\"rejectionReason\": \"invalidCRC\""), "recording export shared rejection spelling");
            check(json.contains("\"type\": \"appBackgrounded\""), "recording export background event");
            check(json.contains("\"type\": \"appForegrounded\""), "recording export foreground event");
            check(json.contains("\"statusFlags\""), "recording export status flags");
            check(json.contains("\"diagnosticFlags\""), "recording export diagnostic flags");
            ScaleRecording decoded = SavedRecordingStore.decodeSharedRecording(json);
            check(decoded.rawPackets.get(0).rejectionReason == ParseRejectionReason.INVALID_CRC, "recording import shared rejection spelling");
            check(decoded.events.get(0).type == RecordingEventType.APP_BACKGROUNDED, "recording import background event");
            check(decoded.events.get(1).type == RecordingEventType.APP_FOREGROUNDED, "recording import foreground event");
            check(decoded.samples.get(0).statusFlags != null && decoded.samples.get(0).statusFlags.displayPresent, "recording import status flags");
            check(decoded.samples.get(0).diagnosticFlags != null && decoded.samples.get(0).diagnosticFlags.detected80Sps, "recording import diagnostic flags");
        } catch (Exception error) {
            throw new AssertionError("Android shared enum export failed: " + error.getMessage(), error);
        }
    }

    private static void testAndroidRecordingGzipExportRoundTrips() {
        try {
            ScaleRecording recording = shotRecording(20, 30);
            materializeRawPackets(recording);

            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            JsonExporter.writeRecordingGzip(recording, output);

            String json;
            try (java.util.zip.GZIPInputStream gzip = new java.util.zip.GZIPInputStream(
                    new java.io.ByteArrayInputStream(output.toByteArray())
            )) {
                json = new String(gzip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            }

            ScaleRecording decoded = SavedRecordingStore.decodeSharedRecording(json);
            check(recording.id.equals(decoded.id), "gzip export preserves recording id");
            check(decoded.samples.size() == recording.samples.size(), "gzip export preserves samples");
            check(decoded.rawPackets.size() == recording.rawPackets.size(), "gzip export preserves packets");
        } catch (Exception error) {
            throw new AssertionError("Android gzip export round trip failed: " + error.getMessage(), error);
        }
    }

    private static void testOfficialScorecardPayload() {
        ScaleRecording recording = SampleRecordingFactory.examples().get(0).recording;
        OfficialScorecardPayload payload = OfficialScorecardPayload.make(recording, 1_785_600_005_000L);

        check(payload.schemaVersion == OfficialScorecardPayload.SCHEMA_VERSION, "scorecard schema version");
        check(payload.mode == RecordingMode.SHOT, "scorecard mode");
        check(payload.protocolKind == ScaleKind.WEIGH_MY_BRU_PLUS, "scorecard protocol");
        check(payload.sampleCount == recording.samples.size(), "scorecard samples");
        check(payload.rawPacketCount == recording.rawPackets.size(), "scorecard packets");
        check(ScoringProfile.STANDARD_BENCHMARK_NAME.equals(payload.scoringProfileName), "scorecard profile");
        check(recording.id.equals(payload.recordingId), "scorecard recording id");
        check(payload.score != null, "scorecard score");
        check(payload.validityReasons != null, "scorecard validity reasons");

        try {
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            JsonExporter.writeOfficialScorecard(recording, output, 1_785_600_005_000L);
            writeContractOutput("android-scorecard.json", output.toString(java.nio.charset.StandardCharsets.UTF_8));
        } catch (Exception error) {
            throw new AssertionError("Official scorecard export failed: " + error.getMessage(), error);
        }

        String fixture = sharedFixture("official-scorecard.json");
        check(intField(fixture, "schemaVersion") == OfficialScorecardPayload.SCHEMA_VERSION, "scorecard fixture schema");
        check(stringField(fixture, "recordingId").equals("33333333-3333-3333-3333-333333333333"), "scorecard fixture id");
        check(stringField(fixture, "protocolKind").equals("weighMyBruPlus"), "scorecard fixture protocol");
        check(intField(fixture, "score") == 100, "scorecard fixture score");
    }

    private static void testBackupDeletionByRecordingId() {
        java.nio.file.Path directory = null;
        try {
            directory = java.nio.file.Files.createTempDirectory("scalebench-android-delete-");
            java.nio.file.Path backups = java.nio.file.Files.createDirectories(directory.resolve(".backups"));
            String recordingId = "11111111-aaaa-4aaa-8aaa-111111111111";
            java.nio.file.Path summaryBackup = backups.resolve(recordingId + ".summary.json.1.bak");
            java.nio.file.Path recordingBackup = backups.resolve(recordingId + "-recording.json.2.bak");
            java.nio.file.Path unrelatedBackup = backups.resolve("22222222-bbbb-4bbb-8bbb-222222222222.summary.json.1.bak");
            java.nio.file.Files.write(summaryBackup, "summary".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            java.nio.file.Files.write(recordingBackup, "recording".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            java.nio.file.Files.write(unrelatedBackup, "unrelated".getBytes(java.nio.charset.StandardCharsets.UTF_8));

            SavedRecordingStore.deleteBackupFiles(directory.toFile(), recordingId);

            check(!java.nio.file.Files.exists(summaryBackup), "delete removes summary backup");
            check(!java.nio.file.Files.exists(recordingBackup), "delete removes recording backup");
            check(java.nio.file.Files.exists(unrelatedBackup), "delete preserves unrelated backup");
        } catch (Exception error) {
            throw new AssertionError("Backup deletion failed: " + error.getMessage(), error);
        } finally {
            if (directory != null) {
                try (java.util.stream.Stream<java.nio.file.Path> paths = java.nio.file.Files.walk(directory)) {
                    paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                        try {
                            java.nio.file.Files.deleteIfExists(path);
                        } catch (java.io.IOException ignored) {
                        }
                    });
                } catch (java.io.IOException ignored) {
                }
            }
        }
    }

    private static void testCorruptRecordingRecoversFromNewestReadableBackup() {
        java.nio.file.Path directory = null;
        try {
            directory = java.nio.file.Files.createTempDirectory("scalebench-android-recovery-");
            java.nio.file.Path backups = java.nio.file.Files.createDirectories(directory.resolve(".backups"));
            java.io.File recordingFile = directory.resolve("recording-recording.json.z").toFile();
            ScaleRecording recording = shotRecording(20, 30);
            materializeRawPackets(recording);
            java.io.File validBackup = backups.resolve(recordingFile.getName() + ".2.bak").toFile();
            JsonExporter.writeRecordingForStorage(recording, validBackup);
            java.nio.file.Files.write(
                    recordingFile.toPath(),
                    "{ broken".getBytes(java.nio.charset.StandardCharsets.UTF_8)
            );

            ScaleRecording recovered = SavedRecordingStore.recoverRecordingFromBackup(recordingFile);

            check(recovered != null, "corrupt recording backup recovery");
            check(recording.id.equals(recovered.id), "backup recovery preserves recording id");
            String restoredJson;
            try (java.util.zip.InflaterInputStream input = new java.util.zip.InflaterInputStream(
                    new java.io.FileInputStream(recordingFile)
            )) {
                restoredJson = new String(input.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            }
            ScaleRecording restoredPrimary = SavedRecordingStore.decodeSharedRecording(restoredJson);
            check(recording.id.equals(restoredPrimary.id), "backup recovery restores primary file");
        } catch (Exception error) {
            throw new AssertionError("Recording backup recovery failed: " + error.getMessage(), error);
        } finally {
            if (directory != null) {
                try (java.util.stream.Stream<java.nio.file.Path> paths = java.nio.file.Files.walk(directory)) {
                    paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                        try {
                            java.nio.file.Files.deleteIfExists(path);
                        } catch (Exception ignored) {
                        }
                    });
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static ScaleRecording shotRecording(int hz, int seconds) {
        ScaleRecording recording = recording(RecordingMode.SHOT, hz, seconds);
        for (ScaleSample sample : recording.samples) {
            double weight = sample.monotonicSeconds < 2 ? 0 : Math.min(36, (sample.monotonicSeconds - 2) * 2);
            sample.weightGrams = Math.round(weight * 10) / 10.0;
        }
        return recording;
    }

    private static ScaleRecording recording(RecordingMode mode, int hz, int seconds) {
        ScaleRecording recording = ScaleRecording.empty(mode);
        recording.recordingStartMonotonicSeconds = 0.0;
        recording.recordingEndMonotonicSeconds = (double) seconds;
        for (int i = 0; i < hz * seconds; i++) {
            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = Math.round(i * 1000.0 / hz);
            sample.monotonicSeconds = i / (double) hz;
            sample.scaleKind = ScaleKind.WEIGH_MY_BRU;
            recording.samples.add(sample);
        }
        return recording;
    }

    private static void materializeRawPackets(ScaleRecording recording) {
        recording.rawPackets.clear();
        for (ScaleSample sample : recording.samples) {
            RawScalePacket packet = new RawScalePacket();
            packet.arrivalTimeMillis = sample.arrivalTimeMillis;
            packet.monotonicSeconds = sample.monotonicSeconds;
            packet.scaleKind = sample.scaleKind;
            packet.characteristicUuid = "VECTOR";
            packet.role = PacketRole.WEIGHT;
            packet.bytesHex = "";
            packet.weightGrams = sample.weightGrams;
            packet.sequence = sample.sequence;
            packet.deviceTimestampMilliseconds = sample.deviceTimestampMilliseconds;
            recording.rawPackets.add(packet);
        }
    }

    private static ProtocolScoringCapabilities capabilities(
            boolean checksum, boolean sequence, boolean clock, DeviceClockSemantics semantics
    ) {
        ProtocolScoringCapabilities capabilities = new ProtocolScoringCapabilities();
        capabilities.hasChecksum = checksum;
        capabilities.hasSequence = sequence;
        capabilities.sequenceModulus = sequence ? 256L : null;
        capabilities.hasDeviceClock = clock;
        capabilities.deviceClockSemantics = semantics;
        capabilities.deviceClockModulus = clock ? 1L << 24 : null;
        return capabilities;
    }

    private static byte[] bytes(int... values) {
        byte[] bytes = new byte[values.length];
        for (int i = 0; i < values.length; i++) bytes[i] = (byte) values[i];
        return bytes;
    }

    private static int xor(byte[] bytes, int count) {
        int result = 0;
        for (int i = 0; i < count; i++) result ^= bytes[i] & 0xFF;
        return result & 0xFF;
    }

    private static int additive(byte[] bytes, int count) {
        int result = 0;
        for (int i = 0; i < count; i++) result = (result + (bytes[i] & 0xFF)) & 0xFF;
        return result;
    }

    private static void close(Double actual, double expected, String label) {
        check(actual != null && Math.abs(actual - expected) < 0.001, label + " expected " + expected + " got " + actual);
    }

    private static String sharedFixture(String fileName) {
        try {
            String root = System.getProperty("scalebench.repo.root");
            java.nio.file.Path path = java.nio.file.Paths.get(root, "shared", "fixtures", fileName);
            return new String(java.nio.file.Files.readAllBytes(path), java.nio.charset.StandardCharsets.UTF_8);
        } catch (Exception error) {
            throw new AssertionError("Could not read fixture " + fileName + ": " + error.getMessage());
        }
    }

    private static void writeContractOutput(String fileName, String json) throws Exception {
        String root = System.getProperty("scalebench.repo.root");
        java.nio.file.Path directory = java.nio.file.Paths.get(root, "build", "contract-output");
        java.nio.file.Files.createDirectories(directory);
        java.nio.file.Files.write(
                directory.resolve(fileName),
                json.getBytes(java.nio.charset.StandardCharsets.UTF_8)
        );
    }

    private static void expectImportFailure(String json, String label) {
        try {
            SavedRecordingStore.decodeSharedRecording(json);
            throw new AssertionError(label + " was accepted");
        } catch (AssertionError error) {
            throw error;
        } catch (Exception expected) {
            // Expected contract rejection.
        }
    }

    private static String stringField(String json, String key) {
        java.util.regex.Matcher matcher = java.util.regex.Pattern
                .compile("\"" + java.util.regex.Pattern.quote(key) + "\"\\s*:\\s*\"([^\"]*)\"")
                .matcher(json);
        if (!matcher.find()) throw new AssertionError("Missing string field " + key);
        return matcher.group(1);
    }

    private static int intField(String json, String key) {
        java.util.regex.Matcher matcher = java.util.regex.Pattern
                .compile("\"" + java.util.regex.Pattern.quote(key) + "\"\\s*:\\s*([0-9]+)")
                .matcher(json);
        if (!matcher.find()) throw new AssertionError("Missing int field " + key);
        return Integer.parseInt(matcher.group(1));
    }

    private static int countObjectsInArray(String json, String key) {
        int keyIndex = json.indexOf("\"" + key + "\"");
        if (keyIndex < 0) throw new AssertionError("Missing array " + key);
        int start = json.indexOf('[', keyIndex);
        int end = matchingBracket(json, start);
        String body = json.substring(start + 1, end);
        int depth = 0;
        int count = 0;
        for (int index = 0; index < body.length(); index++) {
            char c = body.charAt(index);
            if (c == '{') {
                if (depth == 0) count++;
                depth++;
            } else if (c == '}') {
                depth--;
            }
        }
        return count;
    }

    private static int matchingBracket(String json, int start) {
        int depth = 0;
        for (int index = start; index < json.length(); index++) {
            char c = json.charAt(index);
            if (c == '[') depth++;
            else if (c == ']') {
                depth--;
                if (depth == 0) return index;
            }
        }
        throw new AssertionError("Unclosed array");
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }
}
