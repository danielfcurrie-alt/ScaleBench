package app.scalebench.android;

import android.util.JsonWriter;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.zip.DeflaterOutputStream;
import java.util.zip.GZIPOutputStream;

final class JsonExporter {
    private JsonExporter() {
    }

    static void writeRecording(ScaleRecording recording, File file) throws IOException {
        writeRecording(recording, file, true);
    }

    static void writeRecordingForStorage(ScaleRecording recording, File file) throws IOException {
        File temporary = temporaryFileFor(file);
        try {
            try (OutputStream output = new DeflaterOutputStream(new FileOutputStream(temporary))) {
                writeRecording(recording, output, false);
            }
            replaceAtomically(temporary, file);
        } finally {
            Files.deleteIfExists(temporary.toPath());
        }
    }

    private static void writeRecording(ScaleRecording recording, File file, boolean prettyPrinted) throws IOException {
        File temporary = temporaryFileFor(file);
        try {
            try (OutputStream output = new FileOutputStream(temporary)) {
                writeRecording(recording, output, prettyPrinted);
            }
            replaceAtomically(temporary, file);
        } finally {
            Files.deleteIfExists(temporary.toPath());
        }
    }

    static void writeUtf8Atomically(String value, File file) throws IOException {
        File temporary = temporaryFileFor(file);
        try {
            try (OutputStreamWriter writer = new OutputStreamWriter(
                    new FileOutputStream(temporary),
                    StandardCharsets.UTF_8
            )) {
                writer.write(value);
            }
            replaceAtomically(temporary, file);
        } finally {
            Files.deleteIfExists(temporary.toPath());
        }
    }

    static void copyAtomically(File source, File destination) throws IOException {
        File temporary = temporaryFileFor(destination);
        try {
            Files.copy(source.toPath(), temporary.toPath(), StandardCopyOption.REPLACE_EXISTING);
            replaceAtomically(temporary, destination);
        } finally {
            Files.deleteIfExists(temporary.toPath());
        }
    }

    private static File temporaryFileFor(File destination) throws IOException {
        File parent = destination.getAbsoluteFile().getParentFile();
        if (parent == null) throw new IOException("Destination has no parent directory");
        if (!parent.exists() && !parent.mkdirs()) {
            throw new IOException("Could not create " + parent.getPath());
        }
        return File.createTempFile("." + destination.getName() + "-", ".tmp", parent);
    }

    private static void replaceAtomically(File source, File destination) throws IOException {
        try {
            Files.move(
                    source.toPath(),
                    destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING
            );
        } catch (AtomicMoveNotSupportedException ignored) {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
    }

    static void writeRecording(ScaleRecording recording, OutputStream output) throws IOException {
        writeRecording(recording, output, true);
    }

    static void writeRecordingGzip(ScaleRecording recording, OutputStream output) throws IOException {
        try (GZIPOutputStream gzip = new GZIPOutputStream(output)) {
            writeRecording(recording, gzip, true);
        }
    }

    private static void writeRecording(ScaleRecording recording, OutputStream output, boolean prettyPrinted) throws IOException {
        try (JsonWriter writer = new JsonWriter(new OutputStreamWriter(output, StandardCharsets.UTF_8))) {
            if (prettyPrinted) {
                writer.setIndent("  ");
            }
            writer.beginObject();
            writer.name("id").value(recording.id);
            writer.name("schemaVersion").value(recording.schemaVersion);
            writer.name("appName").value(recording.appName);
            writer.name("appVersion").value(recording.appVersion);
            writer.name("appBuild").value(recording.appBuild);
            writer.name("platform").value(recording.platform);
            writer.name("scoringModelVersion").value(recording.scoringModelVersion);
            if (recording.source == RecordingSource.USB_SERIAL) {
                writer.name("source").value(recording.source.wireValue);
                nullable(writer, "protocol", recording.protocolName);
                nullable(writer, "serialBaud", recording.serialBaud);
            }
            nullable(writer, "title", recording.title);
            writer.name("mode").value(modeName(recording.mode));
            writer.name("startedAtMillis").value(recording.startedAtMillis);
            if (recording.endedAtMillis != null) writer.name("endedAtMillis").value(recording.endedAtMillis);
            nullable(writer, "recordingStartMonotonicSeconds", recording.recordingStartMonotonicSeconds);
            nullable(writer, "recordingEndMonotonicSeconds", recording.recordingEndMonotonicSeconds);
            writer.name("notes").value(recording.notes);
            writer.name("scoringProfile").beginObject();
            writer.name("name").value(recording.scoringProfile.name);
            writer.endObject();
            if (recording.device != null) {
                writer.name("device").beginObject();
                writer.name("name").value(recording.device.name);
                writer.name("identifier").value(recording.device.identifier);
                writer.name("kind").value(scaleKindName(recording.device.kind));
                writer.name("advertisedServices").beginArray();
                for (String service : recording.device.advertisedServices) writer.value(service);
                writer.endArray();
                writer.endObject();
            }
            if (recording.protocolCapabilities != null) {
                ProtocolScoringCapabilities capabilities = recording.protocolCapabilities;
                writer.name("protocolCapabilities").beginObject();
                writer.name("hasChecksum").value(capabilities.hasChecksum);
                writer.name("hasSequence").value(capabilities.hasSequence);
                nullable(writer, "sequenceModulus", capabilities.sequenceModulus);
                writer.name("hasDeviceClock").value(capabilities.hasDeviceClock);
                writer.name("deviceClockSemantics").value(clockSemanticsName(capabilities.deviceClockSemantics));
                nullable(writer, "deviceClockModulus", capabilities.deviceClockModulus);
                writer.endObject();
            }
            writer.name("link").beginObject();
            nullable(writer, "requestedConnectionPriority", recording.link.requestedConnectionPriority);
            nullable(writer, "requestedMtu", recording.link.requestedMtu);
            nullable(writer, "negotiatedMtu", recording.link.negotiatedMtu);
            writer.endObject();
            writeMetrics(writer, recording.metrics);
            writer.name("samples").beginArray();
            for (ScaleSample sample : recording.samples) writeSample(writer, sample);
            writer.endArray();
            writer.name("batteryEvents").beginArray();
            for (ScaleBatteryEvent event : recording.batteryEvents) {
                writer.beginObject();
                writer.name("arrivalTimeMillis").value(event.arrivalTimeMillis);
                writer.name("monotonicSeconds").value(event.monotonicSeconds);
                writer.name("scaleKind").value(scaleKindName(event.scaleKind));
                writer.name("percent").value(event.percent);
                writer.endObject();
            }
            writer.endArray();
            writer.name("events").beginArray();
            for (ScaleRecordingEvent event : recording.events) {
                writer.beginObject();
                writer.name("type").value(eventTypeName(event.type));
                writer.name("monotonicSeconds").value(event.monotonicSeconds);
                writer.endObject();
            }
            writer.endArray();
            writer.name("rawPackets").beginArray();
            for (RawScalePacket packet : recording.rawPackets) writeRawPacket(writer, packet, prettyPrinted);
            writer.endArray();
            writer.endObject();
        }
    }

    static void writeOfficialAnalysis(ScaleRecording recording, OutputStream output, long generatedAtMillis) throws IOException {
        OfficialAnalysisPayload payload = OfficialAnalysisPayload.make(recording, generatedAtMillis);
        try (JsonWriter writer = new JsonWriter(new OutputStreamWriter(output, StandardCharsets.UTF_8))) {
            writer.setIndent("  ");
            writer.beginObject();
            writer.name("schemaVersion").value(payload.schemaVersion);
            writer.name("appName").value(payload.appName);
            writer.name("scoringModelVersion").value(payload.scoringModelVersion);
            writer.name("scoringProfileName").value(payload.scoringProfileName);
            writer.name("recordingId").value(payload.recordingId);
            writer.name("generatedAtMillis").value(payload.generatedAtMillis);
            writer.name("platform").value(payload.platform);
            writer.name("mode").value(modeName(payload.mode));
            writer.name("protocolKind").value(scaleKindName(payload.protocolKind));
            writer.name("deviceName").value(payload.deviceName);
            writeMetrics(writer, payload.metrics);
            writeChartAnalysis(writer, payload.chartAnalysis);
            writer.endObject();
        }
    }

    static void writeOfficialScorecard(ScaleRecording recording, OutputStream output, long generatedAtMillis) throws IOException {
        OfficialScorecardPayload payload = OfficialScorecardPayload.make(recording, generatedAtMillis);
        try (JsonWriter writer = new JsonWriter(new OutputStreamWriter(output, StandardCharsets.UTF_8))) {
            writer.setIndent("  ");
            writer.beginObject();
            writer.name("schemaVersion").value(payload.schemaVersion);
            writer.name("appName").value(payload.appName);
            writer.name("scoringModelVersion").value(payload.scoringModelVersion);
            writer.name("scoringProfileName").value(payload.scoringProfileName);
            writer.name("recordingId").value(payload.recordingId);
            writer.name("generatedAtMillis").value(payload.generatedAtMillis);
            writer.name("platform").value(payload.platform);
            writer.name("mode").value(modeName(payload.mode));
            writer.name("protocolKind").value(scaleKindName(payload.protocolKind));
            writer.name("deviceName").value(payload.deviceName);
            writer.name("scoreTitle").value(payload.scoreTitle);
            nullable(writer, "score", payload.score);
            writer.name("scoreIsUpperBound").value(payload.scoreIsUpperBound);
            writer.name("valid").value(payload.valid);
            writer.name("validityReasons").beginArray();
            for (String reason : payload.validityReasons) writer.value(reason);
            writer.endArray();
            nullable(writer, "coverage", payload.coverage);
            nullable(writer, "purity", payload.purity);
            writer.name("verificationCoveragePercent").value(payload.verificationCoveragePercent);
            nullable(writer, "sampleRateHz", payload.sampleRateHz);
            nullable(writer, "deviceCadenceHz", payload.deviceCadenceHz);
            nullable(writer, "receivedSampleRateHz", payload.receivedSampleRateHz);
            nullable(writer, "p95IntervalMilliseconds", payload.p95IntervalMilliseconds);
            nullable(writer, "maxGapMilliseconds", payload.maxGapMilliseconds);
            writer.name("longGapCount").value(payload.longGapCount);
            writer.name("missingSequenceCount").value(payload.missingSequenceCount);
            writer.name("rejectedPacketCount").value(payload.rejectedPacketCount);
            writer.name("sampleCount").value(payload.sampleCount);
            writer.name("rawPacketCount").value(payload.rawPacketCount);
            writer.name("notes").value(payload.notes);
            writer.endObject();
        }
    }

    private static void writeChartAnalysis(JsonWriter writer, SharedChartAnalysisPayload analysis) throws IOException {
        writer.name("chartAnalysis").beginObject();
        writer.name("schemaVersion").value(analysis.schemaVersion);
        writer.name("weightPoints").beginArray();
        for (SharedChartPointPayload point : analysis.weightPoints) writeChartPoint(writer, point);
        writer.endArray();
        writer.name("flowPoints").beginArray();
        for (SharedChartPointPayload point : analysis.flowPoints) writeChartPoint(writer, point);
        writer.endArray();
        writer.name("packetTimeline").beginObject();
        writer.name("entries").beginArray();
        for (SharedPacketTimelineEntryPayload entry : analysis.packetTimeline.entries) {
            writer.beginObject();
            writer.name("index").value(entry.index);
            writer.name("relativeSeconds").value(entry.relativeSeconds);
            nullable(writer, "previousRelativeSeconds", entry.previousRelativeSeconds);
            nullable(writer, "intervalMilliseconds", entry.intervalMilliseconds);
            writer.name("role").value(entry.role);
            writer.name("bytesHex").value(entry.bytesHex);
            nullable(writer, "rejectionReason", entry.rejectionReason);
            nullable(writer, "sequence", entry.sequence);
            nullable(writer, "weightGrams", entry.weightGrams);
            writer.name("severity").value(entry.severity);
            writer.name("lane").value(entry.lane);
            writePacketFields(writer, entry.fields);
            writer.name("evidence").beginArray();
            for (String value : entry.evidence) writer.value(value);
            writer.endArray();
            writer.endObject();
        }
        writer.endArray();
        writer.name("sampleIntervals").beginArray();
        for (SharedSampleIntervalPayload interval : analysis.packetTimeline.sampleIntervals) {
            writer.beginObject();
            writer.name("index").value(interval.index);
            writer.name("previousRelativeSeconds").value(interval.previousRelativeSeconds);
            writer.name("relativeSeconds").value(interval.relativeSeconds);
            writer.name("intervalMilliseconds").value(interval.intervalMilliseconds);
            writer.name("severity").value(interval.severity);
            writer.endObject();
        }
        writer.endArray();
        writer.name("scoringGaps").beginArray();
        for (SharedScoringGapPayload gap : analysis.packetTimeline.scoringGaps) {
            writer.beginObject();
            writer.name("index").value(gap.index);
            writer.name("startRelativeSeconds").value(gap.startRelativeSeconds);
            writer.name("endRelativeSeconds").value(gap.endRelativeSeconds);
            writer.name("intervalMilliseconds").value(gap.intervalMilliseconds);
            writer.endObject();
        }
        writer.endArray();
        writer.name("longGapThresholdMilliseconds").value(analysis.packetTimeline.longGapThresholdMilliseconds);
        writer.name("durationSeconds").value(analysis.packetTimeline.durationSeconds);
        writer.endObject();
        writer.name("problemWindows").beginArray();
        for (SharedProblemWindowPayload window : analysis.problemWindows) {
            writer.beginObject();
            writer.name("id").value(window.id);
            writer.name("title").value(window.title);
            writer.name("category").value(window.category);
            writer.name("severity").value(window.severity);
            writer.name("startSeconds").value(window.startSeconds);
            writer.name("endSeconds").value(window.endSeconds);
            nullable(writer, "relatedPacketIndex", window.relatedPacketIndex);
            writer.endObject();
        }
        writer.endArray();
        writer.name("deductionBreakdown").beginArray();
        for (SharedDeductionPayload deduction : analysis.deductionBreakdown) {
            writer.beginObject();
            writer.name("category").value(deduction.category);
            writer.name("title").value(deduction.title);
            writer.name("detail").value(deduction.detail);
            nullable(writer, "pointsLost", deduction.pointsLost);
            writer.name("severity").value(deduction.severity);
            writer.endObject();
        }
        writer.endArray();
        writeSignalDiagnostics(writer, analysis.signalDiagnostics);
        writer.endObject();
    }

    private static void writeSignalDiagnostics(JsonWriter writer, AndroidSignalDiagnostics diagnostics) throws IOException {
        writer.name("signalDiagnostics").beginObject();
        if (diagnostics.flowValidation != null) {
            AndroidFlowValidationDiagnostics flow = diagnostics.flowValidation;
            writer.name("flowValidation").beginObject();
            writer.name("sampleCount").value(flow.sampleCount);
            writer.name("medianAbsoluteErrorGramsPerSecond").value(flow.medianAbsoluteErrorGramsPerSecond);
            nullable(writer, "lagMilliseconds", flow.lagMilliseconds);
            nullable(writer, "correlation", flow.correlation);
            writer.endObject();
        }
        if (diagnostics.clockSkew != null) {
            AndroidClockSkewDiagnostics clock = diagnostics.clockSkew;
            writer.name("clockSkew").beginObject();
            writer.name("sampleCount").value(clock.sampleCount);
            writer.name("skewPartsPerMillion").value(clock.skewPartsPerMillion);
            writer.endObject();
        }
        if (diagnostics.packetCoalescing != null) {
            AndroidPacketCoalescingDiagnostics packet = diagnostics.packetCoalescing;
            writer.name("packetCoalescing").beginObject();
            writer.name("observedFrameRateHz").value(packet.observedFrameRateHz);
            writer.name("servedSlotRateHz").value(packet.servedSlotRateHz);
            writer.name("framesPerServedSlot").value(packet.framesPerServedSlot);
            writer.endObject();
        }
        if (diagnostics.streamQuality != null) {
            AndroidStreamQualityDiagnostics stream = diagnostics.streamQuality;
            writer.name("streamQuality").beginObject();
            writer.name("implausibleCount").value(stream.implausibleCount);
            nullable(writer, "implausibleMeanErrorGrams", stream.implausibleMeanErrorGrams);
            nullable(writer, "implausibleStdDevGrams", stream.implausibleStdDevGrams);
            nullable(writer, "implausibleP95ErrorGrams", stream.implausibleP95ErrorGrams);
            nullable(writer, "implausibleMaxErrorGrams", stream.implausibleMaxErrorGrams);
            writer.name("implausibleRatePerSecond").value(stream.implausibleRatePerSecond);
            writer.name("longestImplausibleRunMilliseconds").value(stream.longestImplausibleRunMilliseconds);
            nullable(writer, "activePourNegativeStepCount", stream.activePourNegativeStepCount);
            nullable(writer, "activePourNegativeStepTotalGrams", stream.activePourNegativeStepTotalGrams);
            nullable(writer, "activePourAbsStepP95Grams", stream.activePourAbsStepP95Grams);
            writer.name("duplicateRunMaxMilliseconds").value(stream.duplicateRunMaxMilliseconds);
            nullable(writer, "freezeThenReleaseMaxGrams", stream.freezeThenReleaseMaxGrams);
            nullable(writer, "effectiveOutputRateHz", stream.effectiveOutputRateHz);
            writer.name("truthUnavailable").value(stream.truthUnavailable);
            writer.endObject();
        }
        writer.endObject();
    }

    private static void writeChartPoint(JsonWriter writer, SharedChartPointPayload point) throws IOException {
        writer.beginObject();
        writer.name("seconds").value(point.seconds);
        writer.name("value").value(point.value);
        writer.endObject();
    }

    private static void writeMetrics(JsonWriter writer, ScaleQualityMetrics metrics) throws IOException {
        writer.name("metrics").beginObject();
        nullable(writer, "scoringModelVersion", metrics.scoringModelVersion);
        nullable(writer, "scoringProfileName", metrics.scoringProfileName);
        if (metrics.validity != null) {
            writer.name("validity").beginObject();
            writer.name("isValid").value(metrics.validity.isValid);
            writer.name("reasons").beginArray();
            for (String reason : metrics.validity.reasons) writer.value(reason);
            writer.endArray();
            writer.endObject();
        }
        if (metrics.delivery != null) {
            writer.name("delivery").beginObject();
            writer.name("applicable").value(metrics.delivery.applicable);
            nullable(writer, "deliveryScore", metrics.delivery.deliveryScore);
            nullable(writer, "coverage", metrics.delivery.coverage);
            nullable(writer, "purity", metrics.delivery.purity);
            nullable(writer, "purityIsUpperBound", metrics.delivery.purityIsUpperBound);
            writer.endObject();
        }
        if (metrics.frameClassification != null) {
            writer.name("frameClassification").beginObject();
            writer.name("usable").value(metrics.frameClassification.usable);
            writer.name("parseFailure").value(metrics.frameClassification.parseFailure);
            writer.name("outOfOrder").value(metrics.frameClassification.outOfOrder);
            writer.name("stale").value(metrics.frameClassification.stale);
            writer.name("duplicate").value(metrics.frameClassification.duplicate);
            writer.name("implausible").value(metrics.frameClassification.implausible);
            writer.endObject();
        }
        if (metrics.protocolVerification != null) {
            writer.name("protocolVerification").beginObject();
            writer.name("verifiableClasses").beginArray();
            for (String value : metrics.protocolVerification.verifiableClasses) writer.value(value);
            writer.endArray();
            writer.name("unverifiableClasses").beginArray();
            for (String value : metrics.protocolVerification.unverifiableClasses) writer.value(value);
            writer.endArray();
            writer.name("verificationCoveragePercent").value(metrics.protocolVerification.verificationCoveragePercent);
            writer.name("purityIsUpperBound").value(metrics.protocolVerification.purityIsUpperBound);
            writer.endObject();
        }
        nullable(writer, "signalUnreconstructable", metrics.signalUnreconstructable);
        nullable(writer, "overallScore", metrics.overallScore);
        nullable(writer, "transportScore", metrics.transportScore);
        nullable(writer, "stabilityScore", metrics.stabilityScore);
        nullable(writer, "metadataScore", metrics.metadataScore);
        nullable(writer, "effectiveSampleRateHz", metrics.effectiveSampleRateHz);
        nullable(writer, "packetIntervalP50Milliseconds", metrics.packetIntervalP50Milliseconds);
        nullable(writer, "packetIntervalP95Milliseconds", metrics.packetIntervalP95Milliseconds);
        nullable(writer, "packetIntervalMaxMilliseconds", metrics.packetIntervalMaxMilliseconds);
        writer.name("longGapCount").value(metrics.longGapCount);
        writer.name("missingSequenceCount").value(metrics.missingSequenceCount);
        writer.name("duplicateOrOutOfOrderTimestampCount").value(metrics.duplicateOrOutOfOrderTimestampCount);
        writer.name("rejectedPacketCount").value(metrics.rejectedPacketCount);
        nullable(writer, "idleNoisePeakToPeakGrams", metrics.idleNoisePeakToPeakGrams);
        nullable(writer, "idleNoiseStandardDeviationGrams", metrics.idleNoiseStandardDeviationGrams);
        nullable(writer, "driftGramsPerMinute", metrics.driftGramsPerMinute);
        nullable(writer, "batteryMinPercent", metrics.batteryMinPercent);
        nullable(writer, "batteryMaxPercent", metrics.batteryMaxPercent);
        nullable(writer, "firmwareQualityAverage", metrics.firmwareQualityAverage);
        writer.name("firmwareBumpCount").value(metrics.firmwareBumpCount);
        nullable(writer, "relevantWeightFrameCount", metrics.relevantWeightFrameCount);
        nullable(writer, "excludedFrameCount", metrics.excludedFrameCount);
        nullable(writer, "usableSampleCount", metrics.usableSampleCount);
        nullable(writer, "recordingSpanSeconds", metrics.recordingSpanSeconds);
        nullable(writer, "recordingBoundaryInferred", metrics.recordingBoundaryInferred);
        nullable(writer, "frameRateHz", metrics.frameRateHz);
        nullable(writer, "usableRateHz", metrics.usableRateHz);
        nullable(writer, "estimatedResolutionGrams", metrics.estimatedResolutionGrams);
        nullable(writer, "slotCount", metrics.slotCount);
        nullable(writer, "servedSlots", metrics.servedSlots);
        nullable(writer, "longestUnservedRunMilliseconds", metrics.longestUnservedRunMilliseconds);
        nullable(writer, "robustCoefficientOfVariation", metrics.robustCoefficientOfVariation);
        nullable(writer, "disconnectCount", metrics.disconnectCount);
        nullable(writer, "idleNoiseScore", metrics.idleNoiseScore);
        nullable(writer, "idleDriftScore", metrics.idleDriftScore);
        nullable(writer, "idleAnalysedSampleCount", metrics.idleAnalysedSampleCount);
        nullable(writer, "idleResolutionGrams", metrics.idleResolutionGrams);
        if (metrics.stepResponse != null) {
            StepResponseMetrics step = metrics.stepResponse;
            writer.name("stepResponse").beginObject();
            writer.name("stepDetected").value(step.stepDetected);
            nullable(writer, "onsetSecondsFromRecordingStart", step.onsetSecondsFromRecordingStart);
            nullable(writer, "baselineGrams", step.baselineGrams);
            nullable(writer, "finalGrams", step.finalGrams);
            nullable(writer, "amplitudeGrams", step.amplitudeGrams);
            nullable(writer, "riseTime10To90Seconds", step.riseTime10To90Seconds);
            nullable(writer, "settlingTimeSeconds", step.settlingTimeSeconds);
            nullable(writer, "overshootPercent", step.overshootPercent);
            writer.endObject();
        }
        writer.endObject();
    }

    private static void writeSample(JsonWriter writer, ScaleSample sample) throws IOException {
        writer.beginObject();
        writer.name("arrivalTimeMillis").value(sample.arrivalTimeMillis);
        writer.name("monotonicSeconds").value(sample.monotonicSeconds);
        writer.name("scaleKind").value(scaleKindName(sample.scaleKind));
        writer.name("weightGrams").value(sample.weightGrams);
        nullable(writer, "deviceTimestampMilliseconds", sample.deviceTimestampMilliseconds);
        nullable(writer, "sequence", sample.sequence);
        nullable(writer, "batteryPercent", sample.batteryPercent);
        nullable(writer, "flowGramsPerSecond", sample.flowGramsPerSecond);
        nullable(writer, "firmwareQualityScore", sample.firmwareQualityScore);
        nullable(writer, "detectedSampleRateHz", sample.detectedSampleRateHz);
        if (sample.statusFlags != null) writeStatusFlags(writer, sample.statusFlags);
        if (sample.diagnosticFlags != null) writeDiagnosticFlags(writer, sample.diagnosticFlags);
        writeUSBSerialMetadata(writer, sample.usbSerial);
        writer.endObject();
    }

    private static void writeStatusFlags(JsonWriter writer, ScaleStatusFlags flags) throws IOException {
        writer.name("statusFlags").beginObject();
        writer.name("timerRunning").value(flags.timerRunning);
        writer.name("hx711Connected").value(flags.hx711Connected);
        writer.name("tarePending").value(flags.tarePending);
        writer.name("atomicTareStartPending").value(flags.atomicTareStartPending);
        writer.name("batteryLow").value(flags.batteryLow);
        writer.name("batteryCritical").value(flags.batteryCritical);
        writer.name("batteryPresent").value(flags.batteryPresent);
        writer.name("displayPresent").value(flags.displayPresent);
        writer.endObject();
    }

    private static void writeDiagnosticFlags(JsonWriter writer, ScaleDiagnosticFlags flags) throws IOException {
        writer.name("diagnosticFlags").beginObject();
        writer.name("recentBump").value(flags.recentBump);
        writer.name("longGapSeen").value(flags.longGapSeen);
        writer.name("cadenceValid").value(flags.cadenceValid);
        writer.name("detected80SPS").value(flags.detected80Sps);
        writer.name("detected10SPS").value(flags.detected10Sps);
        writer.name("qualityValid").value(flags.qualityValid);
        writer.name("flowPresent").value(flags.flowPresent);
        writer.name("extensionPresent").value(flags.extensionPresent);
        writer.endObject();
    }

    private static void writeRawPacket(JsonWriter writer, RawScalePacket packet, boolean includeFieldAnnotations) throws IOException {
        writer.beginObject();
        writer.name("arrivalTimeMillis").value(packet.arrivalTimeMillis);
        writer.name("monotonicSeconds").value(packet.monotonicSeconds);
        writer.name("scaleKind").value(scaleKindName(packet.scaleKind));
        writer.name("characteristicUUID").value(packet.characteristicUuid);
        writer.name("role").value(packetRoleName(packet.role));
        writer.name("bytesHex").value(ScaleParsers.normalizeHex(packet.bytesHex));
        if (packet.rejectionReason != null) writer.name("rejectionReason").value(rejectionReasonName(packet.rejectionReason));
        nullable(writer, "weightGrams", packet.weightGrams);
        nullable(writer, "sequence", packet.sequence);
        nullable(writer, "deviceTimestampMilliseconds", packet.deviceTimestampMilliseconds);
        if (includeFieldAnnotations) {
            writePacketFields(writer, ScaleParsers.packetFields(packet));
        }
        writeUSBSerialMetadata(writer, packet.usbSerial);
        writer.endObject();
    }

    private static void writeUSBSerialMetadata(
            JsonWriter writer,
            USBSerialSampleMetadata metadata
    ) throws IOException {
        if (metadata == null) return;
        writer.name("firmwareMillis").value(metadata.firmwareMillis);
        writer.name("sequenceNumber").value(metadata.sequenceNumber);
        writer.name("usbStatusRaw").value(metadata.usbStatusRaw);
        writer.name("usbStatusLabels").beginArray();
        for (String label : metadata.usbStatusLabels) writer.value(label);
        writer.endArray();
        writer.name("firmwareQuality").value(metadata.firmwareQuality);
        writer.name("hx711Hz").value(metadata.hx711Hz);
        writer.name("usbDroppedCumulative").value(metadata.usbDroppedCumulative);
        writer.name("usbDroppedDelta").value(metadata.usbDroppedDelta);
        writer.name("hostReceivedAt").value(metadata.hostReceivedAtMillis);
    }

    private static void writePacketFields(JsonWriter writer, java.util.List<PacketFieldAnnotation> fields) throws IOException {
        writer.name("fields").beginArray();
        for (PacketFieldAnnotation field : fields) {
            writer.beginObject();
            writer.name("startByte").value(field.startByte);
            writer.name("endByteExclusive").value(field.endByteExclusive);
            writer.name("label").value(field.label);
            writer.name("decodedValue").value(field.decodedValue);
            writer.name("semantic").value(SharedAnalysisContract.lowerCamelEnum(field.semantic.name()));
            writer.endObject();
        }
        writer.endArray();
    }

    private static void nullable(JsonWriter writer, String name, Number value) throws IOException {
        writer.name(name);
        if (value == null) writer.nullValue();
        else writer.value(value);
    }

    private static void nullable(JsonWriter writer, String name, Boolean value) throws IOException {
        writer.name(name);
        if (value == null) writer.nullValue();
        else writer.value(value);
    }

    private static void nullable(JsonWriter writer, String name, String value) throws IOException {
        writer.name(name);
        if (value == null) writer.nullValue();
        else writer.value(value);
    }

    private static String modeName(RecordingMode mode) {
        switch (mode) {
            case SHOT: return "shot";
            case TRANSPORT_STRESS: return "transportStress";
            case IDLE_STABILITY: return "idleStability";
            case STEP_RESPONSE: return "stepResponse";
            case TARE_LATENCY: return "tareLatency";
            case BATTERY_STABILITY: return "batteryStability";
            default: throw new IllegalStateException("Unknown recording mode");
        }
    }

    private static String eventTypeName(RecordingEventType type) {
        switch (type) {
            case DISCONNECT: return "disconnect";
            case RECONNECT: return "reconnect";
            case APP_BACKGROUNDED: return "appBackgrounded";
            case APP_FOREGROUNDED: return "appForegrounded";
            default: throw new IllegalStateException("Unknown recording event type");
        }
    }

    private static String scaleKindName(ScaleKind kind) {
        switch (kind) {
            case BOOKOO: return "bookoo";
            case BOOKOO_MINI: return "bookooMini";
            case BOOKOO_ULTRA: return "bookooUltra";
            case WEIGH_MY_BRU: return "weighMyBru";
            case WEIGH_MY_BRU_PLUS: return "weighMyBruPlus";
            case EUREKA: return "eureka";
            case ACAIA: return "acaia";
            case DECENT: return "decent";
            case ESPRESSI: return "espressi";
            case DIFLUID: return "difluid";
            case DIFLUID_TI: return "difluidTi";
            case FELICITA: return "felicita";
            case FUTULA: return "futula";
            case SKALE2: return "skale2";
            case TIMEMORE_DOT: return "timemoreDot";
            case UNKNOWN: return "unknown";
            default: throw new IllegalStateException("Unknown scale kind");
        }
    }

    private static String clockSemanticsName(DeviceClockSemantics semantics) {
        if (semantics == DeviceClockSemantics.FREE_RUNNING) return "freeRunning";
        if (semantics == DeviceClockSemantics.SHOT_TIMER) return "shotTimer";
        return "none";
    }

    private static String packetRoleName(PacketRole role) {
        switch (role) {
            case WEIGHT: return "weight";
            case CAPABILITIES: return "capabilities";
            case BATTERY: return "battery";
            case COMMAND_ACK: return "commandAck";
            case UNKNOWN: return "unknown";
            default: throw new IllegalStateException("Unknown packet role");
        }
    }

    private static String rejectionReasonName(ParseRejectionReason reason) {
        switch (reason) {
            case INVALID_LENGTH: return "invalidLength";
            case INVALID_PRODUCT: return "invalidProduct";
            case INVALID_MESSAGE_TYPE: return "invalidMessageType";
            case INVALID_CHECKSUM: return "invalidChecksum";
            case INVALID_HEADER: return "invalidHeader";
            case INVALID_UNIT: return "invalidUnit";
            case INVALID_RANGE: return "invalidRange";
            case INVALID_CRC: return "invalidCRC";
            case INVALID_FLOAT: return "invalidFloat";
            case UNSUPPORTED_FRAME: return "unsupportedFrame";
            case UNSUPPORTED_CHARACTERISTIC: return "unsupportedCharacteristic";
            default: throw new IllegalStateException("Unknown rejection reason");
        }
    }
}
