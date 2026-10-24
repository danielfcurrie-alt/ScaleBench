package app.scalebench.android;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

final class SampleRecordingFactory {
    static final class Example {
        final String title;
        final String notes;
        final ScaleRecording recording;

        Example(String title, String notes, ScaleRecording recording) {
            this.title = title;
            this.notes = notes;
            this.recording = recording;
        }
    }

    private static final long STARTED_AT_MILLIS = 1_785_600_000_000L;

    private SampleRecordingFactory() {
    }

    static List<Example> examples() {
        return Arrays.asList(
                cleanWmbPlusPour(),
                legacyWmbPour(),
                noisySoloBaristaPour()
        );
    }

    private static Example cleanWmbPlusPour() {
        return makeExample(
                "Example · Clean WMB+ Pour",
                "Synthetic example. Clean WMB+ style stream with sequence numbers, device timestamps, battery, flow, and firmware quality.",
                ScaleKind.WEIGH_MY_BRU_PLUS,
                "Example WMB+ Scale",
                Arrays.asList(ScaleParsers.WMB_SERVICE_UUID),
                30.0,
                12.0,
                86,
                true,
                96,
                null,
                new double[0]
        );
    }

    private static Example legacyWmbPour() {
        return makeExample(
                "Example · Legacy WMB Pour",
                "Synthetic example. Simple WeighMyBru-style stream with good cadence but limited metadata.",
                ScaleKind.WEIGH_MY_BRU,
                "Example WeighMyBru",
                Arrays.asList(ScaleParsers.WMB_SERVICE_UUID),
                30.0,
                8.3,
                null,
                false,
                null,
                null,
                new double[0]
        );
    }

    private static Example noisySoloBaristaPour() {
        return makeExample(
                "Example · Noisy Solo Barista Pour",
                "Synthetic example. Solo Barista/Eureka-style stream with an intentional gap and rejected packets so the visualizer has red/orange score evidence.",
                ScaleKind.EUREKA,
                "Example Solo Barista",
                Arrays.asList("FFF0"),
                30.0,
                11.0,
                null,
                false,
                null,
                14.0,
                new double[] {8.4, 14.2, 22.1}
        );
    }

    private static Example makeExample(
            String title,
            String notes,
            ScaleKind kind,
            String deviceName,
            List<String> advertisedServices,
            double durationSeconds,
            double sampleRateHz,
            Integer batteryStart,
            boolean includeMetadata,
            Integer qualityScore,
            Double gapAtSeconds,
            double[] rejectedPacketTimes
    ) {
        double interval = 1.0 / sampleRateHz;
        int sampleCount = (int) (durationSeconds * sampleRateHz);
        List<ScaleSample> samples = new ArrayList<>();
        List<RawScalePacket> rawPackets = new ArrayList<>();
        List<ScaleBatteryEvent> batteryEvents = new ArrayList<>();
        int sequence = 0;

        for (int index = 0; index < sampleCount; index++) {
            double seconds = index * interval;
            if (gapAtSeconds != null && seconds > gapAtSeconds) {
                seconds += 1.15;
            }

            double progress = Math.min(1.0, seconds / durationSeconds);
            double weight = shotWeight(progress, seconds);
            double flow = shotFlow(progress);
            Integer battery = batteryStart == null ? null : Math.max(0, batteryStart - (int) (progress * 2.0));

            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = STARTED_AT_MILLIS + Math.round(seconds * 1000.0);
            sample.monotonicSeconds = seconds;
            sample.scaleKind = kind;
            sample.weightGrams = weight;
            sample.deviceTimestampMilliseconds = includeMetadata
                    ? Math.round(seconds * 1000.0) & 0x00FF_FFFFL
                    : null;
            sample.sequence = includeMetadata ? sequence : null;
            sample.batteryPercent = battery;
            sample.flowGramsPerSecond = includeMetadata ? flow : null;
            sample.firmwareQualityScore = qualityScore;
            sample.detectedSampleRateHz = includeMetadata ? (int) Math.round(sampleRateHz) : null;
            sample.statusFlags = includeMetadata ? new ScaleStatusFlags(0xC3) : null;
            sample.diagnosticFlags = includeMetadata ? new ScaleDiagnosticFlags(0xF4) : null;
            samples.add(sample);

            RawScalePacket weightPacket = new RawScalePacket();
            weightPacket.arrivalTimeMillis = sample.arrivalTimeMillis;
            weightPacket.monotonicSeconds = sample.monotonicSeconds;
            weightPacket.scaleKind = kind;
            weightPacket.characteristicUuid = characteristicUuid(kind);
            weightPacket.role = PacketRole.WEIGHT;
            weightPacket.bytesHex = packetHex(
                    kind,
                    index,
                    weight,
                    sample.deviceTimestampMilliseconds,
                    sample.sequence,
                    sample.batteryPercent,
                    sample.flowGramsPerSecond,
                    sample.firmwareQualityScore,
                    includeMetadata
            );
            weightPacket.weightGrams = sample.weightGrams;
            weightPacket.sequence = sample.sequence;
            weightPacket.deviceTimestampMilliseconds = sample.deviceTimestampMilliseconds;
            rawPackets.add(weightPacket);

            if (includeMetadata && index % 80 == 0 && battery != null) {
                double batteryTime = sample.monotonicSeconds + 0.003;
                ScaleBatteryEvent batteryEvent = new ScaleBatteryEvent();
                batteryEvent.arrivalTimeMillis = sample.arrivalTimeMillis + 3;
                batteryEvent.monotonicSeconds = batteryTime;
                batteryEvent.scaleKind = kind;
                batteryEvent.percent = battery;
                batteryEvents.add(batteryEvent);

                RawScalePacket batteryPacket = new RawScalePacket();
                batteryPacket.arrivalTimeMillis = batteryEvent.arrivalTimeMillis;
                batteryPacket.monotonicSeconds = batteryTime;
                batteryPacket.scaleKind = kind;
                batteryPacket.characteristicUuid = ScaleParsers.BATTERY_LEVEL_UUID;
                batteryPacket.role = PacketRole.BATTERY;
                batteryPacket.bytesHex = String.format(Locale.US, "%02X", battery);
                rawPackets.add(batteryPacket);
            }

            sequence = (sequence + 1) & 0xFF;
        }

        for (int index = 0; index < rejectedPacketTimes.length; index++) {
            ParseRejectionReason reason = index % 2 == 0
                    ? ParseRejectionReason.INVALID_HEADER
                    : ParseRejectionReason.INVALID_LENGTH;
            double rejectedTime = rejectedPacketTimes[index];
            RawScalePacket rejected = new RawScalePacket();
            rejected.arrivalTimeMillis = STARTED_AT_MILLIS + Math.round(rejectedTime * 1000.0);
            rejected.monotonicSeconds = rejectedTime;
            rejected.scaleKind = kind;
            rejected.characteristicUuid = characteristicUuid(kind);
            rejected.role = PacketRole.WEIGHT;
            rejected.bytesHex = rejectedPacketHex(kind, 9_000 + index, reason);
            rejected.rejectionReason = reason;
            rawPackets.add(rejected);
        }

        rawPackets.sort(Comparator.comparingDouble(packet -> packet.monotonicSeconds));

        ScaleRecording recording = ScaleRecording.empty(RecordingMode.SHOT);
        recording.startedAtMillis = STARTED_AT_MILLIS;
        recording.endedAtMillis = STARTED_AT_MILLIS + Math.round(rawPackets.isEmpty() ? durationSeconds * 1000.0 : rawPackets.get(rawPackets.size() - 1).monotonicSeconds * 1000.0);
        recording.recordingStartMonotonicSeconds = 0.0;
        recording.recordingEndMonotonicSeconds = durationSeconds + (gapAtSeconds == null ? 0.0 : 1.15);
        recording.notes = notes;

        ScaleDeviceIdentity device = new ScaleDeviceIdentity();
        device.name = deviceName;
        device.identifier = deterministicDeviceId(deviceName);
        device.kind = kind;
        device.advertisedServices = new ArrayList<>(advertisedServices);
        recording.device = device;

        recording.rawPackets.addAll(rawPackets);
        recording.samples.addAll(samples);
        recording.batteryEvents.addAll(batteryEvents);

        if (includeMetadata) {
            WmbPlusCapabilities capabilities = new WmbPlusCapabilities();
            capabilities.payloadVersion = 1;
            capabilities.protocolMajor = 1;
            capabilities.protocolMinor = 0;
            capabilities.featureMask = 0x0000_3105L;
            capabilities.preferredAtomicCommand = 0x07;
            capabilities.preferredAtomicData1 = 0x00;
            capabilities.extensionPacketVersion = 1;
            capabilities.extensionPacketLength = 20;
            recording.capabilities = capabilities;
        }

        ProtocolScoringCapabilities protocolCapabilities = new ProtocolScoringCapabilities();
        protocolCapabilities.hasChecksum = kind == ScaleKind.WEIGH_MY_BRU || kind == ScaleKind.WEIGH_MY_BRU_PLUS;
        protocolCapabilities.hasSequence = includeMetadata;
        protocolCapabilities.sequenceModulus = includeMetadata ? 256L : null;
        protocolCapabilities.hasDeviceClock = includeMetadata;
        protocolCapabilities.deviceClockSemantics = includeMetadata ? DeviceClockSemantics.FREE_RUNNING : DeviceClockSemantics.NONE;
        protocolCapabilities.deviceClockModulus = includeMetadata ? 1L << 24 : null;
        recording.protocolCapabilities = protocolCapabilities;
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);

        return new Example(title, notes, recording);
    }

    private static double shotWeight(double progress, double seconds) {
        double preinfusion = Math.max(0.0, Math.min(1.0, (progress - 0.10) / 0.18));
        double ramp = 1.0 / (1.0 + Math.exp(-9.0 * (progress - 0.52)));
        double base = 38.0 * Math.max(preinfusion * 0.35, ramp);
        double ripple = Math.sin(seconds * 2.4) * 0.025 + Math.sin(seconds * 0.67) * 0.018;
        return Math.max(0.0, base + ripple);
    }

    private static double shotFlow(double progress) {
        if (progress < 0.12) return 0.0;
        if (progress < 0.35) return 1.1 + progress * 3.2;
        if (progress < 0.78) return 2.2 - (progress - 0.35) * 0.8;
        return Math.max(0.4, 1.5 - (progress - 0.78) * 3.2);
    }

    private static String characteristicUuid(ScaleKind kind) {
        if (kind == ScaleKind.WEIGH_MY_BRU || kind == ScaleKind.WEIGH_MY_BRU_PLUS) {
            return ScaleParsers.WMB_WEIGHT20_UUID;
        }
        if (kind == ScaleKind.EUREKA) {
            return ScaleParsers.EUREKA_NOTIFY_UUID;
        }
        return "SYNTHETIC";
    }

    private static String packetHex(
            ScaleKind kind,
            int index,
            double weight,
            Long deviceTimestamp,
            Integer sequence,
            Integer battery,
            Double flow,
            Integer quality,
            boolean includeMetadata
    ) {
        return ScaleParsers.hex(packetBytes(kind, index, weight, deviceTimestamp, sequence, battery, flow, quality, includeMetadata));
    }

    private static byte[] packetBytes(
            ScaleKind kind,
            int index,
            double weight,
            Long deviceTimestamp,
            Integer sequence,
            Integer battery,
            Double flow,
            Integer quality,
            boolean includeMetadata
    ) {
        if (kind == ScaleKind.WEIGH_MY_BRU || kind == ScaleKind.WEIGH_MY_BRU_PLUS) {
            byte[] bytes = new byte[20];
            bytes[0] = 0x03;
            bytes[1] = 0x0B;
            long timestamp = (deviceTimestamp == null ? index * 100L : deviceTimestamp) & 0x00FF_FFFFL;
            bytes[2] = (byte) ((timestamp >> 16) & 0xFF);
            bytes[3] = (byte) ((timestamp >> 8) & 0xFF);
            bytes[4] = (byte) (timestamp & 0xFF);
            bytes[5] = (byte) (includeMetadata ? 1 : 0);
            writeSignedCenti(weight, 6, 7, 8, 9, bytes);
            if (includeMetadata) {
                writeSignedCenti(flow == null ? 0.0 : flow, 10, -1, 11, 12, bytes);
                bytes[13] = (byte) clampByte(battery);
                bytes[14] = (byte) (sequence == null ? index : sequence);
                bytes[15] = (byte) 0xC3;
                bytes[16] = (byte) clampByte(quality);
                bytes[17] = 12;
                bytes[18] = (byte) 0xF4;
            }
            bytes[19] = (byte) xorChecksum(bytes, bytes.length - 1);
            return bytes;
        }
        if (kind == ScaleKind.EUREKA) {
            byte[] bytes = new byte[11];
            bytes[0] = (byte) 0xAA;
            bytes[1] = 0x09;
            bytes[2] = 0x41;
            bytes[6] = (byte) (weight < 0 ? 1 : 0);
            int magnitude = Math.max(0, Math.min(0xFFFF, (int) Math.round(Math.abs(weight) * 10.0)));
            bytes[7] = (byte) (magnitude & 0xFF);
            bytes[8] = (byte) ((magnitude >> 8) & 0xFF);
            return bytes;
        }
        return new byte[] {(byte) (index & 0xFF)};
    }

    private static String rejectedPacketHex(ScaleKind kind, int index, ParseRejectionReason reason) {
        byte[] bytes = packetBytes(kind, index, 0.0, null, null, null, null, null, false);
        if (reason == ParseRejectionReason.INVALID_LENGTH && bytes.length > 0) {
            bytes = Arrays.copyOf(bytes, bytes.length - 1);
        } else if (bytes.length > 0) {
            bytes[0] = (byte) (bytes[0] ^ 0xFF);
        }
        return ScaleParsers.hex(bytes);
    }

    private static void writeSignedCenti(
            double value,
            int signIndex,
            int highIndex,
            int midIndex,
            int lowIndex,
            byte[] bytes
    ) {
        int magnitude = Math.max(0, Math.min(0x00FF_FFFF, (int) Math.round(Math.abs(value) * 100.0)));
        bytes[signIndex] = (byte) (value < 0 ? 0x2D : 0x2B);
        if (highIndex >= 0) {
            bytes[highIndex] = (byte) ((magnitude >> 16) & 0xFF);
        }
        bytes[midIndex] = (byte) ((magnitude >> 8) & 0xFF);
        bytes[lowIndex] = (byte) (magnitude & 0xFF);
    }

    private static int xorChecksum(byte[] bytes, int count) {
        int checksum = 0;
        for (int index = 0; index < count; index++) {
            checksum ^= bytes[index] & 0xFF;
        }
        return checksum & 0xFF;
    }

    private static int clampByte(Integer value) {
        return value == null ? 0 : Math.max(0, Math.min(255, value));
    }

    private static String deterministicDeviceId(String name) {
        if ("Example WMB+ Scale".equals(name)) return "20000000-0000-0000-0000-000000000001";
        if ("Example WeighMyBru".equals(name)) return "20000000-0000-0000-0000-000000000002";
        return "20000000-0000-0000-0000-000000000003";
    }
}
