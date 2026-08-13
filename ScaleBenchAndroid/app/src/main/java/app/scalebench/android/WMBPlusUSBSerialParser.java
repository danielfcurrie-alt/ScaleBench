package app.scalebench.android;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

final class WMBPlusUSBSerialParser {
	    static final String PROTOCOL_NAME = "WMB+ USB Serial";
	    static final String DEVICE_NAME = "WMB+ USB";
	    static final int BAUD = 115_200;
	    static final String HEADER = "WMBP_WEIGHT_V1_HEADER,ms,seq,weight_g,flow_gps,status,quality,battery_pct,hx711_hz,dropped";
	    static final int STATUS_HX711_CONNECTED = 0x0001;

    private Long previousDropped;

    void reset() {
        previousDropped = null;
    }

    ParseResult parse(String line, long hostReceivedAtMillis, double hostMonotonicSeconds) {
        if (!line.startsWith("WMBP_WEIGHT_V1,")) {
            return ParseResult.ignored();
        }
        String[] values = line.split(",", -1);
        if (values.length != 10) {
            return ParseResult.rejected("Expected 10 CSV fields");
        }

        try {
            long firmwareMillis = parseUnsigned32(values[1], "ms");
            long sequenceNumber = parseUnsigned32(values[2], "seq");
            double weightGrams = finiteDouble(values[3], "weight_g");
            double flowGramsPerSecond = finiteDouble(values[4], "flow_gps");
            int statusRaw = parseStatus(values[5]);
            int firmwareQuality = parseIntRange(values[6], "quality", 0, 100);
            int rawBattery = parseInt(values[7], "battery_pct");
            boolean batteryValid = has(statusRaw, 0x0040);
            if (batteryValid && (rawBattery < 0 || rawBattery > 100)) {
                return ParseResult.rejected("battery_pct outside 0...100");
            }
            double hx711Hz = finiteDouble(values[8], "hx711_hz");
            if (hx711Hz < 0) {
                return ParseResult.rejected("hx711_hz must be nonnegative");
            }
            long droppedCumulative = parseUnsigned32(values[9], "dropped");
            long droppedDelta = 0;
            if (previousDropped != null && droppedCumulative > previousDropped) {
                droppedDelta = droppedCumulative - previousDropped;
            }
            previousDropped = droppedCumulative;

            USBSerialSampleMetadata metadata = new USBSerialSampleMetadata();
            metadata.firmwareMillis = firmwareMillis;
            metadata.sequenceNumber = sequenceNumber;
            metadata.usbStatusRaw = statusRaw;
            metadata.usbStatusLabels.addAll(statusLabels(statusRaw));
            metadata.firmwareQuality = firmwareQuality;
            metadata.hx711Hz = hx711Hz;
            metadata.usbDroppedCumulative = droppedCumulative;
            metadata.usbDroppedDelta = droppedDelta;
            metadata.hostReceivedAtMillis = hostReceivedAtMillis;

            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = hostReceivedAtMillis;
            sample.monotonicSeconds = hostMonotonicSeconds;
            sample.scaleKind = ScaleKind.WEIGH_MY_BRU_PLUS;
            sample.weightGrams = weightGrams;
            sample.deviceTimestampMilliseconds = firmwareMillis;
            sample.sequence = null;
            sample.batteryPercent = batteryValid ? rawBattery : null;
            sample.flowGramsPerSecond = flowGramsPerSecond;
            sample.firmwareQualityScore = firmwareQuality;
            sample.detectedSampleRateHz = hx711Hz > 0 ? (int) Math.round(hx711Hz) : null;
            sample.statusFlags = new ScaleStatusFlags(statusFlagsByte(statusRaw));
            sample.diagnosticFlags = new ScaleDiagnosticFlags(diagnosticFlagsByte(statusRaw, hx711Hz));
            sample.usbSerial = metadata;

            RawScalePacket packet = new RawScalePacket();
            packet.arrivalTimeMillis = hostReceivedAtMillis;
            packet.monotonicSeconds = hostMonotonicSeconds;
            packet.scaleKind = ScaleKind.WEIGH_MY_BRU_PLUS;
            packet.characteristicUuid = PROTOCOL_NAME;
            packet.role = PacketRole.WEIGHT;
            packet.bytesHex = ScaleParsers.hex(line.getBytes(StandardCharsets.UTF_8));
            packet.weightGrams = weightGrams;
            packet.sequence = null;
            packet.deviceTimestampMilliseconds = firmwareMillis;
            packet.usbSerial = metadata;
            packet.fields.addAll(annotations(values));

            return ParseResult.sample(sample, packet);
        } catch (IllegalArgumentException error) {
            return ParseResult.rejected(error.getMessage());
        }
    }

    private static int statusFlagsByte(int statusRaw) {
        int value = 0;
        if (has(statusRaw, 0x0001)) value |= 0x02;
        if (has(statusRaw, 0x0040)) value |= 0x40;
        return value;
    }

    private static int diagnosticFlagsByte(int statusRaw, double hx711Hz) {
        int value = 0x20 | 0x40 | 0x80;
        if (has(statusRaw, 0x0004)) value |= 0x01;
        if (hx711Hz > 0) value |= 0x04;
        if (hx711Hz >= 60) value |= 0x08;
        if (hx711Hz >= 8 && hx711Hz <= 12) value |= 0x10;
        return value;
    }

    private static List<String> statusLabels(int statusRaw) {
        List<String> labels = new ArrayList<>();
        addLabel(labels, statusRaw, 0x0001, "HX711 connected");
        addLabel(labels, statusRaw, 0x0002, "BLE connected");
        addLabel(labels, statusRaw, 0x0004, "Recent bump");
        addLabel(labels, statusRaw, 0x0008, "Recent glitch");
        addLabel(labels, statusRaw, 0x0010, "Zero clamped");
        addLabel(labels, statusRaw, 0x0020, "Auto-zero active");
        addLabel(labels, statusRaw, 0x0040, "Battery valid");
        addLabel(labels, statusRaw, 0x0080, "Charging");
        addLabel(labels, statusRaw, 0x0100, "WiFi radio on");
        return labels;
    }

    private static void addLabel(List<String> labels, int statusRaw, int flag, String label) {
        if (has(statusRaw, flag)) labels.add(label);
    }

    private static boolean has(int value, int flag) {
        return (value & flag) != 0;
    }

    private static long parseUnsigned32(String value, String field) {
        try {
            long parsed = Long.parseLong(value);
            if (parsed < 0 || parsed > 0xFFFF_FFFFL) {
                throw new IllegalArgumentException(field + " outside UInt32 range");
            }
            return parsed;
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException(field + " is not an integer");
        }
    }

    private static int parseStatus(String value) {
        if (!value.startsWith("0x") && !value.startsWith("0X")) {
            throw new IllegalArgumentException("status must be hex");
        }
        try {
            int parsed = Integer.parseInt(value.substring(2), 16);
            if (parsed < 0 || parsed > 0xFFFF) {
                throw new IllegalArgumentException("status outside UInt16 range");
            }
            return parsed;
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException("status must be hex");
        }
    }

    private static int parseInt(String value, String field) {
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException(field + " is not an integer");
        }
    }

    private static int parseIntRange(String value, String field, int min, int max) {
        int parsed = parseInt(value, field);
        if (parsed < min || parsed > max) {
            throw new IllegalArgumentException(field + " outside " + min + "..." + max);
        }
        return parsed;
    }

    private static double finiteDouble(String value, String field) {
        try {
            double parsed = Double.parseDouble(value);
            if (!Double.isFinite(parsed)) {
                throw new IllegalArgumentException(field + " is not finite");
            }
            return parsed;
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException(field + " is not a number");
        }
    }

    private static List<PacketFieldAnnotation> annotations(String[] values) {
        String[] labels = {
                "Type", "Firmware millis", "Sequence", "Weight", "Flow",
                "Status", "Firmware quality", "Battery", "HX711 cadence", "USB dropped"
        };
        PacketFieldSemantic[] semantics = {
                PacketFieldSemantic.HEADER, PacketFieldSemantic.TIMESTAMP, PacketFieldSemantic.SEQUENCE,
                PacketFieldSemantic.WEIGHT, PacketFieldSemantic.FLOW, PacketFieldSemantic.STATUS,
                PacketFieldSemantic.QUALITY, PacketFieldSemantic.BATTERY, PacketFieldSemantic.SAMPLE_RATE,
                PacketFieldSemantic.PAYLOAD
        };
        List<PacketFieldAnnotation> result = new ArrayList<>();
        int offset = 0;
        for (int i = 0; i < values.length; i++) {
            int length = values[i].getBytes(StandardCharsets.UTF_8).length;
            result.add(PacketFieldAnnotation.of(offset, offset + length, labels[i], values[i], semantics[i]));
            offset += length + 1;
        }
        return result;
    }

	    static final class ParseResult {
        final boolean ignored;
        final ScaleSample sample;
        final RawScalePacket packet;
        final String rejectionReason;

        private ParseResult(boolean ignored, ScaleSample sample, RawScalePacket packet, String rejectionReason) {
            this.ignored = ignored;
            this.sample = sample;
            this.packet = packet;
            this.rejectionReason = rejectionReason;
        }

        static ParseResult ignored() {
            return new ParseResult(true, null, null, null);
        }

        static ParseResult sample(ScaleSample sample, RawScalePacket packet) {
            return new ParseResult(false, sample, packet, null);
        }

        static ParseResult rejected(String reason) {
            return new ParseResult(false, null, null, reason);
	    }
	}
}
