package app.scalebench.android;

import android.util.JsonWriter;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

final class JsonExporter {
    private JsonExporter() {
    }

    static void writeRecording(ScaleRecording recording, File file) throws IOException {
        try (JsonWriter writer = new JsonWriter(new FileWriter(file))) {
            writer.setIndent("  ");
            writer.beginObject();
            writer.name("schemaVersion").value(recording.schemaVersion);
            writer.name("appName").value(recording.appName);
            writer.name("appVersion").value(recording.appVersion);
            writer.name("mode").value(recording.mode.name());
            writer.name("startedAtMillis").value(recording.startedAtMillis);
            if (recording.endedAtMillis != null) writer.name("endedAtMillis").value(recording.endedAtMillis);
            writer.name("notes").value(recording.notes);
            writer.name("scoringProfile").beginObject();
            writer.name("name").value(recording.scoringProfile.name);
            writer.endObject();
            if (recording.device != null) {
                writer.name("device").beginObject();
                writer.name("name").value(recording.device.name);
                writer.name("identifier").value(recording.device.identifier);
                writer.name("kind").value(recording.device.kind.name());
                writer.name("advertisedServices").beginArray();
                for (String service : recording.device.advertisedServices) writer.value(service);
                writer.endArray();
                writer.endObject();
            }
            writeMetrics(writer, recording.metrics);
            writer.name("samples").beginArray();
            for (ScaleSample sample : recording.samples) writeSample(writer, sample);
            writer.endArray();
            writer.name("batteryEvents").beginArray();
            for (ScaleBatteryEvent event : recording.batteryEvents) {
                writer.beginObject();
                writer.name("arrivalTimeMillis").value(event.arrivalTimeMillis);
                writer.name("monotonicSeconds").value(event.monotonicSeconds);
                writer.name("scaleKind").value(event.scaleKind.name());
                writer.name("percent").value(event.percent);
                writer.endObject();
            }
            writer.endArray();
            writer.name("rawPackets").beginArray();
            for (RawScalePacket packet : recording.rawPackets) writeRawPacket(writer, packet);
            writer.endArray();
            writer.endObject();
        }
    }

    private static void writeMetrics(JsonWriter writer, ScaleQualityMetrics metrics) throws IOException {
        writer.name("metrics").beginObject();
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
        writer.endObject();
    }

    private static void writeSample(JsonWriter writer, ScaleSample sample) throws IOException {
        writer.beginObject();
        writer.name("arrivalTimeMillis").value(sample.arrivalTimeMillis);
        writer.name("monotonicSeconds").value(sample.monotonicSeconds);
        writer.name("scaleKind").value(sample.scaleKind.name());
        writer.name("weightGrams").value(sample.weightGrams);
        nullable(writer, "deviceTimestampMilliseconds", sample.deviceTimestampMilliseconds);
        nullable(writer, "sequence", sample.sequence);
        nullable(writer, "batteryPercent", sample.batteryPercent);
        nullable(writer, "flowGramsPerSecond", sample.flowGramsPerSecond);
        nullable(writer, "firmwareQualityScore", sample.firmwareQualityScore);
        nullable(writer, "detectedSampleRateHz", sample.detectedSampleRateHz);
        writer.endObject();
    }

    private static void writeRawPacket(JsonWriter writer, RawScalePacket packet) throws IOException {
        writer.beginObject();
        writer.name("arrivalTimeMillis").value(packet.arrivalTimeMillis);
        writer.name("monotonicSeconds").value(packet.monotonicSeconds);
        writer.name("scaleKind").value(packet.scaleKind.name());
        writer.name("characteristicUUID").value(packet.characteristicUuid);
        writer.name("role").value(packet.role.name());
        writer.name("bytesHex").value(packet.bytesHex);
        if (packet.rejectionReason != null) writer.name("rejectionReason").value(packet.rejectionReason.name());
        writer.endObject();
    }

    private static void nullable(JsonWriter writer, String name, Number value) throws IOException {
        writer.name(name);
        if (value == null) writer.nullValue();
        else writer.value(value);
    }
}

