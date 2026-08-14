package app.scalebench.android;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

final class ScaleParsers {
    static final String WMB_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
    static final String WMB_WEIGHT20_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
    static final String WMB_COMMAND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
    static final String WMB_FLOAT32_UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E";
    static final String WMB_CAPABILITIES_UUID = "6E400005-B5A3-F393-E0A9-E50E24DCCA9E";
    static final String BATTERY_SERVICE_UUID = "180F";
    static final String BATTERY_LEVEL_UUID = "2A19";

    static final String BOOKOO_SERVICE_UUID = "0FFE";
    static final String BOOKOO_NOTIFY_UUID = "FF11";
    static final String BOOKOO_WRITE_UUID = "FF12";

    static final String ACAIA_SERVICE_UUID = "1820";
    static final String ACAIA_FULL_SERVICE_UUID = "00001820-0000-1000-8000-00805F9B34FB";
    static final String ACAIA_LEGACY_SERVICE_UUID = "49535343-FE7D-4AE5-8FA9-9FAFD205E455";
    static final String ACAIA_MODERN_CHAR_UUID = "2A80";
    static final String ACAIA_FULL_MODERN_CHAR_UUID = "00002A80-0000-1000-8000-00805F9B34FB";
    static final String ACAIA_LEGACY_NOTIFY_UUID = "49535343-1E4D-4BD9-BA61-23C647249616";
    static final String ACAIA_LEGACY_WRITE_UUID = "49535343-8841-43F4-A8D4-ECBE34729BB3";

    static final String DECENT_SERVICE_UUID = "FFF0";
    static final String DECENT_NOTIFY_UUID = "FFF4";
    static final String DECENT_WRITE_UUID = "36F5";
    static final String DIFLUID_SERVICE_UUID = "00EE";
    static final String DIFLUID_TI_SERVICE_UUID = "00DD";
    static final String DIFLUID_CHAR_UUID = "AA01";
    static final String EUREKA_NOTIFY_UUID = "FFF1";
    static final String EUREKA_WRITE_UUID = "FFF2";
    static final String FELICITA_SERVICE_UUID = "FFE0";
    static final String FELICITA_CHAR_UUID = "FFE1";
    static final String FUTULA_NOTIFY_UUID = "FFF4";
    static final String FUTULA_WRITE_UUID = "FFF1";
    static final String SKALE2_SERVICE_UUID = "FF08";
    static final String SKALE2_NOTIFY_UUID = "EF81";
    static final String SKALE2_WRITE_UUID = "EF80";
    static final String TIMEMORE_NOTIFY_UUID = "FFF1";
    static final String TIMEMORE_WRITE_UUID = "FFF2";

    static final byte[] WMB_ATOMIC_TARE_AND_START = new byte[] {0x03, 0x0A, 0x07, 0x00, 0x00, 0x0E};
    static final byte[] BOOKOO_TARE_AND_START = new byte[] {0x03, 0x0A, 0x07, 0x00, 0x00, 0x00};
    static final byte[] ACAIA_NOTIFICATION_REQUEST = acaiaFrame(0x0C, new int[] {0x09, 0x00, 0x01, 0x01, 0x02, 0x02, 0x05, 0x03, 0x04});
    static final byte[] DECENT_LEDS_ON = frameWithXor(new int[] {0x03, 0x0A, 0x01, 0x01, 0x00, 0x01});
    static final byte[] DIFLUID_CONFIG_1 = bytes(0xDF, 0xDF, 0x01, 0x04, 0x01, 0x00, 0xC4);
    static final byte[] DIFLUID_CONFIG_2 = bytes(0xDF, 0xDF, 0x01, 0x00, 0x01, 0x01, 0xC1);
    static final byte[] DIFLUID_REQUEST_STATUS = bytes(0xDF, 0xDF, 0x03, 0x05, 0x00, 0xC6);
    static final byte[] FUTULA_SET_GRAMS = bytes(0xFD, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF9);
    static final byte[][] SKALE2_INITIAL_COMMANDS = new byte[][] {bytes(0xED), bytes(0xEC), bytes(0x03)};
    static final byte[] TIMEMORE_SET_GRAMS = timemoreFrame(0x03, 0x06, new int[] {0x00});
    static final byte[] TIMEMORE_SET_STANDARD_MODE = timemoreFrame(0x03, 0x08, new int[] {0x01, 0x00});

    private ScaleParsers() {
    }

    static ScaleKind identify(String name, Iterable<String> services) {
        String lower = name == null ? "" : name.toLowerCase(Locale.US);
        if (lower.contains("weighmybru+")) return ScaleKind.WEIGH_MY_BRU_PLUS;
        if (lower.contains("weighmybru") || hasService(services, WMB_SERVICE_UUID)) return ScaleKind.WEIGH_MY_BRU;
        if (lower.contains("bookoo") || hasService(services, BOOKOO_SERVICE_UUID)) return identifyBookooKind(name);
        if (acaiaNameMatches(name) || hasService(services, ACAIA_SERVICE_UUID) || hasService(services, ACAIA_FULL_SERVICE_UUID)) return ScaleKind.ACAIA;
        if (felicitaNameMatches(lower) || hasService(services, FELICITA_SERVICE_UUID)) return ScaleKind.FELICITA;
        if (hasService(services, SKALE2_SERVICE_UUID) || lower.startsWith("skale")) return ScaleKind.SKALE2;
        if (hasService(services, DIFLUID_TI_SERVICE_UUID) || lower.contains("microbalance ti") || lower.contains("mb ti")) return ScaleKind.DIFLUID_TI;
        if (hasService(services, DIFLUID_SERVICE_UUID) || lower.contains("microbalance")) return ScaleKind.DIFLUID;
        if (lower.startsWith("decent")) return ScaleKind.DECENT;
        if (lower.startsWith("espressiscale")) return ScaleKind.ESPRESSI;
        if (futulaNameMatches(lower)) return ScaleKind.FUTULA;
        if (eurekaNameMatches(lower)) return ScaleKind.EUREKA;
        if (timemoreNameMatches(lower)) return ScaleKind.TIMEMORE_DOT;
        return ScaleKind.UNKNOWN;
    }

    static ScaleKind identifyBookooKind(String name) {
        String lower = name == null ? "" : name.toLowerCase(Locale.US);
        if (lower.contains("ultra")) return ScaleKind.BOOKOO_ULTRA;
        if (lower.contains("mini")) return ScaleKind.BOOKOO_MINI;
        return ScaleKind.BOOKOO;
    }

    static WmbPlusCapabilities parseCapabilities(byte[] bytes) {
        if (bytes.length != 16) return null;
        if (u(bytes[0]) != 0x03 || u(bytes[1]) != 0x0C) return null;
        if (xorChecksum(bytes, bytes.length - 1) != u(bytes[15])) return null;

        WmbPlusCapabilities c = new WmbPlusCapabilities();
        c.payloadVersion = u(bytes[2]);
        c.protocolMajor = u(bytes[4]);
        c.protocolMinor = u(bytes[5]);
        c.featureMask = u(bytes[6]) | (long) u(bytes[7]) << 8 | (long) u(bytes[8]) << 16 | (long) u(bytes[9]) << 24;
        c.preferredAtomicCommand = u(bytes[10]);
        c.preferredAtomicData1 = u(bytes[11]);
        c.extensionPacketVersion = u(bytes[12]);
        c.extensionPacketLength = u(bytes[13]);
        return c;
    }

    static ParserResult parseWmb20(byte[] bytes, WmbPlusCapabilities capabilities, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length != 20) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        if (u(bytes[0]) != 0x03) return ParserResult.rejected(ParseRejectionReason.INVALID_PRODUCT);
        if (u(bytes[1]) != 0x0B) return ParserResult.rejected(ParseRejectionReason.INVALID_MESSAGE_TYPE);
        if (xorChecksum(bytes, bytes.length - 1) != u(bytes[19])) return ParserResult.rejected(ParseRejectionReason.INVALID_CHECKSUM);

        boolean hasExtension = capabilities != null && capabilities.supportsExtendedPacket() && u(bytes[5]) == capabilities.extensionPacketVersion;
        ScaleSample sample = new ScaleSample();
        sample.arrivalTimeMillis = arrivalMillis;
        sample.monotonicSeconds = monotonicSeconds;
        sample.scaleKind = hasExtension ? ScaleKind.WEIGH_MY_BRU_PLUS : ScaleKind.WEIGH_MY_BRU;
        sample.weightGrams = signedCentiValue(u(bytes[6]), u(bytes[7]), u(bytes[8]), u(bytes[9]));
        if (hasExtension) {
            sample.deviceTimestampMilliseconds = uint24(u(bytes[2]), u(bytes[3]), u(bytes[4]));
            sample.flowGramsPerSecond = signedCentiValue(u(bytes[10]), 0, u(bytes[11]), u(bytes[12]));
            int battery = u(bytes[13]);
            sample.batteryPercent = battery <= 100 ? battery : null;
            sample.sequence = u(bytes[14]);
            sample.statusFlags = new ScaleStatusFlags(u(bytes[15]));
            int quality = u(bytes[16]);
            sample.firmwareQualityScore = quality <= 100 ? quality : null;
            sample.detectedSampleRateHz = u(bytes[17]) == 0 ? null : u(bytes[17]);
            sample.diagnosticFlags = new ScaleDiagnosticFlags(u(bytes[18]));
        }
        return ParserResult.sample(sample);
    }

    static ParserResult parseDecentEspressi(byte[] bytes, ScaleKind activeKind, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length < 4) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        if (u(bytes[1]) != 0xCE && u(bytes[1]) != 0xCA) return ParserResult.rejected(ParseRejectionReason.UNSUPPORTED_FRAME);
        short raw = (short) ((u(bytes[2]) << 8) | u(bytes[3]));
        Long timestamp = null;
        if (bytes.length >= 10 && u(bytes[6]) < 60 && u(bytes[7]) < 10) {
            double seconds = u(bytes[5]) * 60.0 + u(bytes[6]) + u(bytes[7]) / 10.0;
            timestamp = Math.round(seconds * 1000.0);
        }
        ScaleSample sample = new ScaleSample();
        sample.arrivalTimeMillis = arrivalMillis;
        sample.monotonicSeconds = monotonicSeconds;
        sample.scaleKind = activeKind == ScaleKind.ESPRESSI ? ScaleKind.ESPRESSI : ScaleKind.DECENT;
        sample.weightGrams = raw / 10.0;
        sample.deviceTimestampMilliseconds = timestamp;
        return ParserResult.sample(sample);
    }

    static ParserResult parseDiFluid(byte[] bytes, ScaleKind activeKind, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length < 6) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        if (u(bytes[0]) != 0xDF || u(bytes[1]) != 0xDF) return ParserResult.rejected(ParseRejectionReason.INVALID_HEADER);
        if (!hasAdditiveChecksum(bytes)) return ParserResult.rejected(ParseRejectionReason.INVALID_CHECKSUM);
        if (u(bytes[2]) == 0x03 && u(bytes[3]) == 0x00) {
            if (bytes.length < 19 || u(bytes[4]) < 13) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
            if (u(bytes[17]) != 0x00) return ParserResult.rejected(ParseRejectionReason.INVALID_UNIT);
            int raw = (int) (((long) u(bytes[5]) << 24) | ((long) u(bytes[6]) << 16) | ((long) u(bytes[7]) << 8) | u(bytes[8]));
            short rawFlow = (short) ((u(bytes[9]) << 8) | u(bytes[10]));
            long timestamp = ((long) u(bytes[13]) << 24) | ((long) u(bytes[14]) << 16) | ((long) u(bytes[15]) << 8) | u(bytes[16]);
            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = arrivalMillis;
            sample.monotonicSeconds = monotonicSeconds;
            sample.scaleKind = activeKind == ScaleKind.DIFLUID_TI ? ScaleKind.DIFLUID_TI : ScaleKind.DIFLUID;
            sample.weightGrams = raw / 10.0;
            sample.deviceTimestampMilliseconds = timestamp;
            double flow = rawFlow / 10.0;
            sample.flowGramsPerSecond = Math.abs(flow) < 50 ? flow : null;
            sample.diagnosticFlags = new ScaleDiagnosticFlags(0x40);
            return ParserResult.sample(sample);
        }
        if (u(bytes[2]) == 0x03 && u(bytes[3]) == 0x05) {
            if (bytes.length < 14 || u(bytes[4]) < 8) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
            int battery = u(bytes[6]);
            return battery <= 100 ? ParserResult.battery(battery) : ParserResult.rejected(ParseRejectionReason.INVALID_RANGE);
        }
        return ParserResult.rejected(ParseRejectionReason.UNSUPPORTED_FRAME);
    }

    static ParserResult parseEureka(byte[] bytes, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length != 11) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        if (u(bytes[0]) != 0xAA || u(bytes[2]) != 0x41) return ParserResult.rejected(ParseRejectionReason.INVALID_HEADER);
        double sign = u(bytes[6]) != 0 ? -1.0 : 1.0;
        int raw = u(bytes[7]) | (u(bytes[8]) << 8);
        ScaleSample sample = baseSample(arrivalMillis, monotonicSeconds, ScaleKind.EUREKA, sign * raw / 10.0);
        return ParserResult.sample(sample);
    }

    static ParserResult parseFelicita(byte[] bytes, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length != 18) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        int raw = 0;
        for (int i = 3; i <= 8; i++) {
            int digit = u(bytes[i]);
            if (digit < 0x30 || digit > 0x39) return ParserResult.rejected(ParseRejectionReason.INVALID_RANGE);
            raw = raw * 10 + digit - 0x30;
        }
        double grams = raw / 100.0;
        ScaleSample sample = baseSample(arrivalMillis, monotonicSeconds, ScaleKind.FELICITA, u(bytes[2]) == 0x2D ? -grams : grams);
        return ParserResult.sample(sample);
    }

    static ParserResult parseFutula(byte[] bytes, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length < 9) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        int raw = u(bytes[3]) | (u(bytes[4]) << 8);
        double grams = raw / 10.0;
        ScaleSample sample = baseSample(arrivalMillis, monotonicSeconds, ScaleKind.FUTULA, u(bytes[5]) != 0 ? -grams : grams);
        return ParserResult.sample(sample);
    }

    static ParserResult parseSkale2(byte[] bytes, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length < 3) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        short raw = (short) (u(bytes[1]) | (u(bytes[2]) << 8));
        return ParserResult.sample(baseSample(arrivalMillis, monotonicSeconds, ScaleKind.SKALE2, raw / 10.0));
    }

    static ParserResult parseWmbFloat32(byte[] bytes, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length != 4) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        float value = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getFloat();
        if (!Float.isFinite(value)) return ParserResult.rejected(ParseRejectionReason.INVALID_FLOAT);
        ScaleSample sample = new ScaleSample();
        sample.arrivalTimeMillis = arrivalMillis;
        sample.monotonicSeconds = monotonicSeconds;
        sample.scaleKind = ScaleKind.WEIGH_MY_BRU;
        sample.weightGrams = value;
        return ParserResult.sample(sample);
    }

    static ParserResult parseBookoo(byte[] bytes, ScaleKind activeKind, long arrivalMillis, double monotonicSeconds) {
        if (bytes.length != 20) return ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH);
        if (u(bytes[0]) != 0x03) return ParserResult.rejected(ParseRejectionReason.INVALID_PRODUCT);
        if (u(bytes[1]) != 0x0B) return ParserResult.rejected(ParseRejectionReason.INVALID_MESSAGE_TYPE);
        if (xorChecksum(bytes, bytes.length - 1) != u(bytes[19])) return ParserResult.rejected(ParseRejectionReason.INVALID_CHECKSUM);

        ScaleSample sample = new ScaleSample();
        sample.arrivalTimeMillis = arrivalMillis;
        sample.monotonicSeconds = monotonicSeconds;
        sample.scaleKind = activeKind == ScaleKind.BOOKOO_MINI || activeKind == ScaleKind.BOOKOO_ULTRA ? activeKind : ScaleKind.BOOKOO;
        sample.deviceTimestampMilliseconds = uint24(u(bytes[2]), u(bytes[3]), u(bytes[4]));
        sample.weightGrams = signedCentiValue(u(bytes[6]), u(bytes[7]), u(bytes[8]), u(bytes[9]));
        double flow = signedCentiValue(u(bytes[10]), 0, u(bytes[11]), u(bytes[12]));
        sample.flowGramsPerSecond = Double.isFinite(flow) && Math.abs(flow) < 50 ? flow : null;
        int battery = u(bytes[13]);
        sample.batteryPercent = battery <= 100 ? battery : null;
        int flags = 0x40;
        if (sample.scaleKind == ScaleKind.BOOKOO_MINI || sample.scaleKind == ScaleKind.BOOKOO_ULTRA) flags |= 0x80;
        if (u(bytes[17]) <= 1) flags |= 0x04;
        sample.diagnosticFlags = new ScaleDiagnosticFlags(flags);
        return ParserResult.sample(sample);
    }

    static String hex(byte[] bytes) {
        StringBuilder builder = new StringBuilder(Math.max(0, bytes.length * 3 - 1));
        for (int index = 0; index < bytes.length; index++) {
            if (index > 0) builder.append(' ');
            builder.append(String.format(Locale.US, "%02X", u(bytes[index])));
        }
        return builder.toString();
    }

    static byte[] parseHex(String value) {
        if (value == null) return null;
        String compact = value.replaceAll("\\s", "");
        if (compact.isEmpty() || compact.length() % 2 != 0) return null;
        byte[] result = new byte[compact.length() / 2];
        try {
            for (int index = 0; index < result.length; index++) {
                result[index] = (byte) Integer.parseInt(compact.substring(index * 2, index * 2 + 2), 16);
            }
        } catch (NumberFormatException exception) {
            return null;
        }
        return result;
    }

    static String normalizeHex(String value) {
        byte[] bytes = parseHex(value);
        return bytes == null ? value : hex(bytes);
    }

    static List<PacketFieldAnnotation> packetFields(
            ScaleKind kind,
            String characteristicUuid,
            byte[] bytes
    ) {
        if (bytes == null || bytes.length == 0) return new ArrayList<>();
        String uuid = shortUuid(characteristicUuid == null ? "" : characteristicUuid);
        if (uuid.equals(shortUuid(BATTERY_LEVEL_UUID))) {
            return fields(field(0, 1, "Battery", u(bytes[0]) + "%", PacketFieldSemantic.BATTERY));
        }
        if (uuid.equals(shortUuid(WMB_CAPABILITIES_UUID)) && bytes.length == 16) return wmbCapabilitiesFields(bytes);
        if (uuid.equals(shortUuid(WMB_FLOAT32_UUID)) && bytes.length == 4) {
            float value = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getFloat();
            return fields(field(0, 4, "Weight", Float.isFinite(value) ? grams(value) : "invalid float", PacketFieldSemantic.WEIGHT));
        }
        if (uuid.equals(shortUuid(WMB_WEIGHT20_UUID)) && bytes.length == 20) {
            return wmbWeightFields(bytes, kind == ScaleKind.WEIGH_MY_BRU_PLUS);
        }
        if (kind == null) kind = ScaleKind.UNKNOWN;
        switch (kind) {
            case BOOKOO:
            case BOOKOO_MINI:
            case BOOKOO_ULTRA:
                return bytes.length == 20 ? bookooFields(bytes) : new ArrayList<>();
            case WEIGH_MY_BRU:
            case WEIGH_MY_BRU_PLUS:
                return bytes.length == 20 ? wmbWeightFields(bytes, kind == ScaleKind.WEIGH_MY_BRU_PLUS) : new ArrayList<>();
            case EUREKA:
                return eurekaFields(bytes);
            case DECENT:
            case ESPRESSI:
                return decentFields(bytes);
            case DIFLUID:
            case DIFLUID_TI:
                return diFluidFields(bytes);
            case FELICITA:
                return felicitaFields(bytes);
            case FUTULA:
                return futulaFields(bytes);
            case SKALE2:
                return skale2Fields(bytes);
            case ACAIA:
                return acaiaFields(bytes);
            case TIMEMORE_DOT:
                return timemoreFields(bytes);
            case UNKNOWN:
            default:
                return new ArrayList<>();
        }
    }

    static List<PacketFieldAnnotation> packetFields(RawScalePacket packet) {
        if (packet == null) return new ArrayList<>();
        if (!packet.fields.isEmpty()) return new ArrayList<>(packet.fields);
        byte[] bytes = parseHex(packet.bytesHex);
        return bytes == null
                ? new ArrayList<>()
                : packetFields(packet.scaleKind, packet.characteristicUuid, bytes);
    }

    private static List<PacketFieldAnnotation> wmbWeightFields(byte[] bytes, boolean extended) {
        double weight = signedCentiValue(u(bytes[6]), u(bytes[7]), u(bytes[8]), u(bytes[9]));
        List<PacketFieldAnnotation> result = fields(
                field(0, 2, "Header", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 5, extended ? "Timestamp" : "Protocol data", extended ? uint24(u(bytes[2]), u(bytes[3]), u(bytes[4])) + " ms" : rangeHex(bytes, 2, 5), extended ? PacketFieldSemantic.TIMESTAMP : PacketFieldSemantic.PAYLOAD),
                field(5, 6, extended ? "Packet version" : "Protocol data", extended ? Integer.toString(u(bytes[5])) : rangeHex(bytes, 5, 6), PacketFieldSemantic.PAYLOAD),
                field(6, 10, "Weight", grams(weight), PacketFieldSemantic.WEIGHT)
        );
        if (extended) {
            double flow = signedCentiValue(u(bytes[10]), 0, u(bytes[11]), u(bytes[12]));
            result.add(field(10, 13, "Flow", rate(flow), PacketFieldSemantic.FLOW));
            result.add(field(13, 14, "Battery", u(bytes[13]) + "%", PacketFieldSemantic.BATTERY));
            result.add(field(14, 15, "Sequence", Integer.toString(u(bytes[14])), PacketFieldSemantic.SEQUENCE));
            result.add(field(15, 16, "Status", rangeHex(bytes, 15, 16), PacketFieldSemantic.STATUS));
            result.add(field(16, 17, "Quality", u(bytes[16]) + "%", PacketFieldSemantic.QUALITY));
            result.add(field(17, 18, "Sample rate", u(bytes[17]) + " Hz", PacketFieldSemantic.SAMPLE_RATE));
            result.add(field(18, 19, "Diagnostics", diagnosticFlagsDescription(u(bytes[18])), PacketFieldSemantic.STATUS));
        } else {
            result.add(field(10, 19, "Protocol data", rangeHex(bytes, 10, 19), PacketFieldSemantic.PAYLOAD));
        }
        result.add(field(19, 20, "Checksum", rangeHex(bytes, 19, 20), PacketFieldSemantic.CHECKSUM));
        return result;
    }

    private static List<PacketFieldAnnotation> wmbCapabilitiesFields(byte[] bytes) {
        long featureMask = u(bytes[6]) | (long) u(bytes[7]) << 8 | (long) u(bytes[8]) << 16 | (long) u(bytes[9]) << 24;
        return fields(
                field(0, 2, "Header", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 3, "Payload version", Integer.toString(u(bytes[2])), PacketFieldSemantic.PAYLOAD),
                field(3, 4, "Reserved", rangeHex(bytes, 3, 4), PacketFieldSemantic.PAYLOAD),
                field(4, 6, "Protocol version", u(bytes[4]) + "." + u(bytes[5]), PacketFieldSemantic.PAYLOAD),
                field(6, 10, "Feature mask", String.format(Locale.US, "0x%08X", featureMask), PacketFieldSemantic.STATUS),
                field(10, 12, "Atomic command", rangeHex(bytes, 10, 12), PacketFieldSemantic.PAYLOAD),
                field(12, 13, "Extension version", Integer.toString(u(bytes[12])), PacketFieldSemantic.PAYLOAD),
                field(13, 14, "Extension length", u(bytes[13]) + " bytes", PacketFieldSemantic.PAYLOAD),
                field(14, 15, "Reserved", rangeHex(bytes, 14, 15), PacketFieldSemantic.PAYLOAD),
                field(15, 16, "Checksum", rangeHex(bytes, 15, 16), PacketFieldSemantic.CHECKSUM)
        );
    }

    private static List<PacketFieldAnnotation> bookooFields(byte[] bytes) {
        double weight = signedCentiValue(u(bytes[6]), u(bytes[7]), u(bytes[8]), u(bytes[9]));
        double flow = signedCentiValue(u(bytes[10]), 0, u(bytes[11]), u(bytes[12]));
        return fields(
                field(0, 2, "Header", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 5, "Timestamp", uint24(u(bytes[2]), u(bytes[3]), u(bytes[4])) + " ms", PacketFieldSemantic.TIMESTAMP),
                field(5, 6, "Protocol data", rangeHex(bytes, 5, 6), PacketFieldSemantic.PAYLOAD),
                field(6, 10, "Weight", grams(weight), PacketFieldSemantic.WEIGHT),
                field(10, 13, "Flow", rate(flow), PacketFieldSemantic.FLOW),
                field(13, 14, "Battery", u(bytes[13]) + "%", PacketFieldSemantic.BATTERY),
                field(14, 19, "Protocol data", rangeHex(bytes, 14, 19), PacketFieldSemantic.PAYLOAD),
                field(19, 20, "Checksum", rangeHex(bytes, 19, 20), PacketFieldSemantic.CHECKSUM)
        );
    }

    private static List<PacketFieldAnnotation> eurekaFields(byte[] bytes) {
        if (bytes.length != 11) return new ArrayList<>();
        int raw = u(bytes[7]) | u(bytes[8]) << 8;
        double weight = (u(bytes[6]) == 0 ? 1.0 : -1.0) * raw / 10.0;
        return fields(
                field(0, 3, "Header", rangeHex(bytes, 0, 3), PacketFieldSemantic.HEADER),
                field(3, 6, "Protocol data", rangeHex(bytes, 3, 6), PacketFieldSemantic.PAYLOAD),
                field(6, 7, "Sign", u(bytes[6]) == 0 ? "positive" : "negative", PacketFieldSemantic.WEIGHT),
                field(7, 9, "Weight", grams(weight), PacketFieldSemantic.WEIGHT),
                field(9, 11, "Protocol data", rangeHex(bytes, 9, 11), PacketFieldSemantic.PAYLOAD)
        );
    }

    private static List<PacketFieldAnnotation> decentFields(byte[] bytes) {
        if (bytes.length < 4) return new ArrayList<>();
        short raw = (short) (u(bytes[2]) << 8 | u(bytes[3]));
        List<PacketFieldAnnotation> result = fields(
                field(0, 2, "Message", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 4, "Weight", grams(raw / 10.0), PacketFieldSemantic.WEIGHT)
        );
        if (bytes.length >= 8 && u(bytes[6]) < 60 && u(bytes[7]) < 10) {
            if (bytes.length > 4) result.add(field(4, 5, "Protocol data", rangeHex(bytes, 4, 5), PacketFieldSemantic.PAYLOAD));
            double seconds = u(bytes[5]) * 60.0 + u(bytes[6]) + u(bytes[7]) / 10.0;
            result.add(field(5, 8, "Timer", String.format(Locale.US, "%.1f s", seconds), PacketFieldSemantic.TIMESTAMP));
            if (bytes.length > 8) result.add(field(8, bytes.length, "Protocol data", rangeHex(bytes, 8, bytes.length), PacketFieldSemantic.PAYLOAD));
        } else if (bytes.length > 4) {
            result.add(field(4, bytes.length, "Protocol data", rangeHex(bytes, 4, bytes.length), PacketFieldSemantic.PAYLOAD));
        }
        return result;
    }

    private static List<PacketFieldAnnotation> diFluidFields(byte[] bytes) {
        if (bytes.length < 6) return new ArrayList<>();
        List<PacketFieldAnnotation> result = fields(
                field(0, 2, "Header", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 4, "Message", rangeHex(bytes, 2, 4), PacketFieldSemantic.PAYLOAD),
                field(4, 5, "Payload length", u(bytes[4]) + " bytes", PacketFieldSemantic.PAYLOAD)
        );
        if (u(bytes[2]) == 0x03 && u(bytes[3]) == 0x00 && bytes.length >= 19) {
            int raw = u(bytes[5]) << 24 | u(bytes[6]) << 16 | u(bytes[7]) << 8 | u(bytes[8]);
            short rawFlow = (short) (u(bytes[9]) << 8 | u(bytes[10]));
            long timestamp = (long) u(bytes[13]) << 24 | (long) u(bytes[14]) << 16 | (long) u(bytes[15]) << 8 | u(bytes[16]);
            result.add(field(5, 9, "Weight", grams(raw / 10.0), PacketFieldSemantic.WEIGHT));
            result.add(field(9, 11, "Flow", rate(rawFlow / 10.0), PacketFieldSemantic.FLOW));
            result.add(field(11, 13, "Protocol data", rangeHex(bytes, 11, 13), PacketFieldSemantic.PAYLOAD));
            result.add(field(13, 17, "Timestamp", timestamp + " ms", PacketFieldSemantic.TIMESTAMP));
            result.add(field(17, 18, "Unit", u(bytes[17]) == 0 ? "grams" : rangeHex(bytes, 17, 18), PacketFieldSemantic.UNIT));
            if (bytes.length > 19) result.add(field(18, bytes.length - 1, "Protocol data", rangeHex(bytes, 18, bytes.length - 1), PacketFieldSemantic.PAYLOAD));
        } else if (u(bytes[2]) == 0x03 && u(bytes[3]) == 0x05 && bytes.length >= 14) {
            result.add(field(5, 6, "Protocol data", rangeHex(bytes, 5, 6), PacketFieldSemantic.PAYLOAD));
            result.add(field(6, 7, "Battery", u(bytes[6]) + "%", PacketFieldSemantic.BATTERY));
            if (bytes.length > 8) result.add(field(7, bytes.length - 1, "Protocol data", rangeHex(bytes, 7, bytes.length - 1), PacketFieldSemantic.PAYLOAD));
        } else if (bytes.length > 6) {
            result.add(field(5, bytes.length - 1, "Protocol data", rangeHex(bytes, 5, bytes.length - 1), PacketFieldSemantic.PAYLOAD));
        }
        result.add(field(bytes.length - 1, bytes.length, "Checksum", rangeHex(bytes, bytes.length - 1, bytes.length), PacketFieldSemantic.CHECKSUM));
        return result;
    }

    private static List<PacketFieldAnnotation> felicitaFields(byte[] bytes) {
        if (bytes.length != 18) return new ArrayList<>();
        int raw = 0;
        boolean hasValidDigits = true;
        for (int index = 3; index <= 8; index++) {
            hasValidDigits &= u(bytes[index]) >= 0x30 && u(bytes[index]) <= 0x39;
            raw = raw * 10 + Math.max(0, u(bytes[index]) - 0x30);
        }
        double weight = (u(bytes[2]) == 0x2D ? -1.0 : 1.0) * raw / 100.0;
        return fields(
                field(0, 2, "Protocol data", rangeHex(bytes, 0, 2), PacketFieldSemantic.PAYLOAD),
                field(2, 3, "Sign", u(bytes[2]) == 0x2D ? "negative" : "positive", PacketFieldSemantic.WEIGHT),
                field(3, 9, "Weight", hasValidDigits ? grams(weight) : "invalid digits", PacketFieldSemantic.WEIGHT),
                field(9, 18, "Protocol data", rangeHex(bytes, 9, 18), PacketFieldSemantic.PAYLOAD)
        );
    }

    private static List<PacketFieldAnnotation> futulaFields(byte[] bytes) {
        if (bytes.length < 9) return new ArrayList<>();
        int raw = u(bytes[3]) | u(bytes[4]) << 8;
        double weight = (u(bytes[5]) == 0 ? 1.0 : -1.0) * raw / 10.0;
        return fields(
                field(0, 3, "Protocol data", rangeHex(bytes, 0, 3), PacketFieldSemantic.PAYLOAD),
                field(3, 5, "Weight", grams(weight), PacketFieldSemantic.WEIGHT),
                field(5, 6, "Sign", u(bytes[5]) == 0 ? "positive" : "negative", PacketFieldSemantic.WEIGHT),
                field(6, bytes.length, "Protocol data", rangeHex(bytes, 6, bytes.length), PacketFieldSemantic.PAYLOAD)
        );
    }

    private static List<PacketFieldAnnotation> skale2Fields(byte[] bytes) {
        if (bytes.length < 3) return new ArrayList<>();
        short raw = (short) (u(bytes[1]) | u(bytes[2]) << 8);
        List<PacketFieldAnnotation> result = fields(
                field(0, 1, "Message", rangeHex(bytes, 0, 1), PacketFieldSemantic.HEADER),
                field(1, 3, "Weight", grams(raw / 10.0), PacketFieldSemantic.WEIGHT)
        );
        if (bytes.length > 3) result.add(field(3, bytes.length, "Protocol data", rangeHex(bytes, 3, bytes.length), PacketFieldSemantic.PAYLOAD));
        return result;
    }

    private static List<PacketFieldAnnotation> acaiaFields(byte[] bytes) {
        if (bytes.length < 6 || u(bytes[0]) != 0xEF || u(bytes[1]) != 0xDD) return new ArrayList<>();
        int payloadLength = u(bytes[3]);
        if (bytes.length != payloadLength + 6) return new ArrayList<>();
        List<PacketFieldAnnotation> result = fields(
                field(0, 2, "Header", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 3, "Message", rangeHex(bytes, 2, 3), PacketFieldSemantic.PAYLOAD),
                field(3, 4, "Payload length", payloadLength + " bytes", PacketFieldSemantic.PAYLOAD)
        );
        if (u(bytes[2]) == 0x0C && payloadLength >= 4) {
            short raw = (short) (u(bytes[4]) | u(bytes[5]) << 8);
            double value = Math.abs((double) raw) / Math.pow(10.0, u(bytes[6]));
            if ((u(bytes[7]) & 0x02) != 0) value = -value;
            result.add(field(4, 6, "Weight", grams(value), PacketFieldSemantic.WEIGHT));
            result.add(field(6, 7, "Decimal places", Integer.toString(u(bytes[6])), PacketFieldSemantic.UNIT));
            result.add(field(7, 8, "Status", rangeHex(bytes, 7, 8), PacketFieldSemantic.STATUS));
            if (payloadLength > 4) result.add(field(8, 4 + payloadLength, "Protocol data", rangeHex(bytes, 8, 4 + payloadLength), PacketFieldSemantic.PAYLOAD));
        } else if (payloadLength > 0) {
            result.add(field(4, 4 + payloadLength, "Payload", rangeHex(bytes, 4, 4 + payloadLength), PacketFieldSemantic.PAYLOAD));
        }
        result.add(field(bytes.length - 2, bytes.length, "Checksum", rangeHex(bytes, bytes.length - 2, bytes.length), PacketFieldSemantic.CHECKSUM));
        return result;
    }

    private static List<PacketFieldAnnotation> timemoreFields(byte[] bytes) {
        if (bytes.length < 8 || u(bytes[0]) != 0xA5 || u(bytes[1]) != 0x5A) return new ArrayList<>();
        int payloadLength = u(bytes[4]) << 8 | u(bytes[5]);
        if (bytes.length != payloadLength + 8) return new ArrayList<>();
        List<PacketFieldAnnotation> result = fields(
                field(0, 2, "Header", rangeHex(bytes, 0, 2), PacketFieldSemantic.HEADER),
                field(2, 3, "Opcode", rangeHex(bytes, 2, 3), PacketFieldSemantic.PAYLOAD),
                field(3, 4, "Command", rangeHex(bytes, 3, 4), PacketFieldSemantic.PAYLOAD),
                field(4, 6, "Payload length", payloadLength + " bytes", PacketFieldSemantic.PAYLOAD)
        );
        if (u(bytes[3]) == 0x01 && payloadLength >= 4) {
            int raw = u(bytes[6]) << 24 | u(bytes[7]) << 16 | u(bytes[8]) << 8 | u(bytes[9]);
            result.add(field(6, 10, "Weight", grams(raw / 10.0), PacketFieldSemantic.WEIGHT));
            if (payloadLength > 4) result.add(field(10, 6 + payloadLength, "Protocol data", rangeHex(bytes, 10, 6 + payloadLength), PacketFieldSemantic.PAYLOAD));
        } else if (u(bytes[3]) == 0x05 && payloadLength >= 2) {
            result.add(field(6, 7, "Protocol data", rangeHex(bytes, 6, 7), PacketFieldSemantic.PAYLOAD));
            result.add(field(7, 8, "Battery", u(bytes[7]) + "%", PacketFieldSemantic.BATTERY));
            if (payloadLength > 2) result.add(field(8, 6 + payloadLength, "Protocol data", rangeHex(bytes, 8, 6 + payloadLength), PacketFieldSemantic.PAYLOAD));
        } else if (payloadLength > 0) {
            result.add(field(6, 6 + payloadLength, "Payload", rangeHex(bytes, 6, 6 + payloadLength), PacketFieldSemantic.PAYLOAD));
        }
        result.add(field(bytes.length - 2, bytes.length, "CRC", rangeHex(bytes, bytes.length - 2, bytes.length), PacketFieldSemantic.CHECKSUM));
        return result;
    }

    private static PacketFieldAnnotation field(int start, int end, String label, String value, PacketFieldSemantic semantic) {
        return PacketFieldAnnotation.of(start, end, label, value, semantic);
    }

    private static List<PacketFieldAnnotation> fields(PacketFieldAnnotation... fields) {
        return new ArrayList<>(Arrays.asList(fields));
    }

    private static String rangeHex(byte[] bytes, int start, int end) {
        if (start < 0 || end > bytes.length || start >= end) return "";
        return hex(Arrays.copyOfRange(bytes, start, end));
    }

    private static String grams(double value) {
        return String.format(Locale.US, "%.2f g", value);
    }

    private static String rate(double value) {
        return String.format(Locale.US, "%.2f g/s", value);
    }

    private static String diagnosticFlagsDescription(int value) {
        List<String> labels = new ArrayList<>();
        if ((value & 0x01) != 0) labels.add("recent bump");
        if ((value & 0x02) != 0) labels.add("long gap seen");
        if ((value & 0x04) != 0) labels.add("cadence valid");
        if ((value & 0x08) != 0) labels.add("80 SPS");
        if ((value & 0x10) != 0) labels.add("10 SPS");
        if ((value & 0x20) != 0) labels.add("quality valid");
        if ((value & 0x40) != 0) labels.add("flow present");
        if ((value & 0x80) != 0) labels.add("extension present");
        String prefix = String.format(Locale.US, "0x%02X", value);
        return labels.isEmpty() ? prefix : prefix + " · " + String.join(", ", labels);
    }

    static String shortUuid(String uuid) {
        String upper = uuid == null ? "" : uuid.toUpperCase(Locale.US);
        String suffix = "-0000-1000-8000-00805F9B34FB";
        if (upper.startsWith("0000") && upper.endsWith(suffix)) {
            return upper.substring(4, 8);
        }
        return upper;
    }

    static boolean uuidMatches(String actual, String expected) {
        String a = shortUuid(actual);
        String e = shortUuid(expected);
        return a.equals(e) || actual.equalsIgnoreCase(expected);
    }

    static byte[] acaiaIdentifyCommand(boolean isPyxis) {
        int[] payload = new int[15];
        Arrays.fill(payload, isPyxis ? -1 : 0x2D);
        if (isPyxis) {
            byte[] pyxis = "012345678901234".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            for (int i = 0; i < payload.length; i++) payload[i] = pyxis[i];
        }
        return acaiaFrame(0x0B, payload);
    }

    static byte[] timemoreFrame(int opcode, int command, int[] payload) {
        byte[] frame = new byte[8 + payload.length];
        frame[0] = (byte) 0xA5;
        frame[1] = 0x5A;
        frame[2] = (byte) opcode;
        frame[3] = (byte) command;
        frame[4] = (byte) ((payload.length >> 8) & 0xFF);
        frame[5] = (byte) (payload.length & 0xFF);
        for (int i = 0; i < payload.length; i++) frame[6 + i] = (byte) payload[i];
        int crc = crc16(frame, frame.length - 2);
        frame[frame.length - 2] = (byte) ((crc >> 8) & 0xFF);
        frame[frame.length - 1] = (byte) (crc & 0xFF);
        return frame;
    }

    static int crc16(byte[] bytes, int count) {
        int crc = 0xFFFF;
        for (int i = 0; i < count; i++) {
            crc ^= u(bytes[i]);
            for (int bit = 0; bit < 8; bit++) {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
            }
        }
        return crc & 0xFFFF;
    }

    private static boolean hasService(Iterable<String> services, String wanted) {
        for (String service : services) {
            if (uuidMatches(service, wanted)) return true;
        }
        return false;
    }

    private static ScaleSample baseSample(long arrivalMillis, double monotonicSeconds, ScaleKind kind, double grams) {
        ScaleSample sample = new ScaleSample();
        sample.arrivalTimeMillis = arrivalMillis;
        sample.monotonicSeconds = monotonicSeconds;
        sample.scaleKind = kind;
        sample.weightGrams = grams;
        return sample;
    }

    private static boolean acaiaNameMatches(String name) {
        if (name == null || name.length() < 5) return false;
        String prefix = name.substring(0, 5).toUpperCase(Locale.US);
        return prefix.equals("ACAIA") || prefix.equals("LUNAR") || prefix.equals("PYXIS")
                || prefix.equals("PROCH") || prefix.equals("PEARL") || prefix.equals("CINCO");
    }

    private static boolean eurekaNameMatches(String lower) {
        return lower.equals("cfs-9002") || lower.equals("lsj-001") || lower.contains("eureka") || lower.contains("solo");
    }

    private static boolean felicitaNameMatches(String lower) {
        return lower.contains("felicita") || lower.contains("arc") || lower.contains("incline");
    }

    private static boolean futulaNameMatches(String lower) {
        return lower.contains("lfsmart scale") || lower.contains("lefu");
    }

    private static boolean timemoreNameMatches(String lower) {
        String[] tokens = lower.split("[^a-z0-9]+");
        boolean hasDot = false;
        boolean hasBrand = false;
        for (String token : tokens) {
            if (token.equals("tes017")) return true;
            if (token.equals("dot")) hasDot = true;
            if (token.equals("timemore") || token.equals("black")) hasBrand = true;
        }
        return lower.equals("dot") || (hasDot && hasBrand);
    }

    private static int xorChecksum(byte[] bytes, int count) {
        int result = 0;
        for (int i = 0; i < count; i++) result ^= u(bytes[i]);
        return result & 0xFF;
    }

    private static boolean hasAdditiveChecksum(byte[] bytes) {
        int checksum = u(bytes[bytes.length - 1]);
        int sum = 0;
        for (int i = 0; i < bytes.length - 1; i++) sum = (sum + u(bytes[i])) & 0xFF;
        return sum == checksum;
    }

    private static byte[] acaiaFrame(int type, int[] payload) {
        byte[] packet = new byte[5 + payload.length];
        packet[0] = (byte) 0xEF;
        packet[1] = (byte) 0xDD;
        packet[2] = (byte) type;
        int even = 0;
        int odd = 0;
        for (int i = 0; i < payload.length; i++) {
            packet[3 + i] = (byte) payload[i];
            if (i % 2 == 0) even = (even + payload[i]) & 0xFF;
            else odd = (odd + payload[i]) & 0xFF;
        }
        packet[3 + payload.length] = (byte) even;
        packet[4 + payload.length] = (byte) odd;
        return packet;
    }

    private static byte[] frameWithXor(int[] payload) {
        byte[] frame = new byte[payload.length + 1];
        int checksum = 0;
        for (int i = 0; i < payload.length; i++) {
            frame[i] = (byte) payload[i];
            checksum ^= payload[i];
        }
        frame[payload.length] = (byte) checksum;
        return frame;
    }

    private static byte[] bytes(int... values) {
        byte[] bytes = new byte[values.length];
        for (int i = 0; i < values.length; i++) bytes[i] = (byte) values[i];
        return bytes;
    }

    private static long uint24(int high, int mid, int low) {
        return (long) high << 16 | (long) mid << 8 | low;
    }

    private static double signedCentiValue(int signByte, int high, int mid, int low) {
        long raw = (long) high << 16 | (long) mid << 8 | low;
        double sign = signByte == 0x2D ? -1.0 : 1.0;
        return sign * raw / 100.0;
    }

    private static int u(byte b) {
        return b & 0xFF;
    }
}

final class ParserResult {
    final ScaleSample sample;
    final Integer batteryPercent;
    final ParseRejectionReason rejectionReason;

    private ParserResult(ScaleSample sample, Integer batteryPercent, ParseRejectionReason rejectionReason) {
        this.sample = sample;
        this.batteryPercent = batteryPercent;
        this.rejectionReason = rejectionReason;
    }

    static ParserResult sample(ScaleSample sample) {
        return new ParserResult(sample, null, null);
    }

    static ParserResult battery(int percent) {
        return new ParserResult(null, percent, null);
    }

    static ParserResult rejected(ParseRejectionReason reason) {
        return new ParserResult(null, null, reason);
    }

    boolean isSample() {
        return sample != null;
    }

    boolean isBattery() {
        return batteryPercent != null;
    }
}

final class AcaiaCodec {
    private final List<Byte> buffer = new ArrayList<>();

    List<ParserResult> receive(byte[] data, long arrivalMillis, double monotonicSeconds) {
        for (byte b : data) buffer.add(b);
        List<ParserResult> results = new ArrayList<>();
        while (true) {
            if (buffer.size() < 2) return results;
            int start = findAcaiaStart();
            if (start < 0) {
                byte last = buffer.get(buffer.size() - 1);
                buffer.clear();
                if ((last & 0xFF) == 0xEF) buffer.add(last);
                return results;
            }
            if (start > 0) {
                for (int i = 0; i < start; i++) buffer.remove(0);
            }
            if (buffer.size() < 4) return results;
            int payloadLength = buffer.get(3) & 0xFF;
            if (payloadLength > 64) {
                buffer.remove(0);
                results.add(ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH));
                continue;
            }
            int frameLength = 4 + payloadLength + 2;
            if (buffer.size() < frameLength) return results;
            byte[] frame = take(frameLength);
            results.add(parseFrame(frame, arrivalMillis, monotonicSeconds));
        }
    }

    private ParserResult parseFrame(byte[] frame, long arrivalMillis, double monotonicSeconds) {
        if (frame.length < 9 || (frame[0] & 0xFF) != 0xEF || (frame[1] & 0xFF) != 0xDD) return ParserResult.rejected(ParseRejectionReason.INVALID_HEADER);
        if ((frame[2] & 0xFF) != 0x0C) return ParserResult.rejected(ParseRejectionReason.UNSUPPORTED_FRAME);
        if (!hasValidChecksum(frame)) return ParserResult.rejected(ParseRejectionReason.INVALID_CHECKSUM);
        short raw = (short) ((frame[4] & 0xFF) | ((frame[5] & 0xFF) << 8));
        int divisor = frame[6] & 0xFF;
        boolean isNegative = (frame[7] & 0x02) != 0;
        double grams = Math.abs((double) raw) / Math.pow(10.0, divisor);
        if (isNegative) grams = -grams;
        if (!Double.isFinite(grams)) return ParserResult.rejected(ParseRejectionReason.INVALID_RANGE);
        return ParserResult.sample(ScaleParsersBase.sample(arrivalMillis, monotonicSeconds, ScaleKind.ACAIA, grams));
    }

    private boolean hasValidChecksum(byte[] frame) {
        int payloadLength = frame[3] & 0xFF;
        int checksumStart = 4 + payloadLength;
        if (frame.length < checksumStart + 2) return false;
        int even = 0;
        int odd = 0;
        for (int i = 4; i < checksumStart; i++) {
            if ((i - 4) % 2 == 0) even = (even + (frame[i] & 0xFF)) & 0xFF;
            else odd = (odd + (frame[i] & 0xFF)) & 0xFF;
        }
        return (frame[checksumStart] & 0xFF) == even && (frame[checksumStart + 1] & 0xFF) == odd;
    }

    private int findAcaiaStart() {
        for (int i = 0; i < buffer.size() - 1; i++) {
            if ((buffer.get(i) & 0xFF) == 0xEF && (buffer.get(i + 1) & 0xFF) == 0xDD) return i;
        }
        return -1;
    }

    private byte[] take(int count) {
        byte[] bytes = new byte[count];
        for (int i = 0; i < count; i++) bytes[i] = buffer.remove(0);
        return bytes;
    }
}

final class TimemoreDotCodec {
    private final List<Byte> buffer = new ArrayList<>();

    List<ParserResult> receive(byte[] data, long arrivalMillis, double monotonicSeconds) {
        for (byte b : data) buffer.add(b);
        List<ParserResult> results = new ArrayList<>();
        while (true) {
            if (buffer.size() < 2) return results;
            if (!startsWithHeader()) {
                discardUntilPotentialHeader();
                results.add(ParserResult.rejected(ParseRejectionReason.INVALID_HEADER));
                continue;
            }
            if (buffer.size() < 8) return results;
            int payloadLength = ((buffer.get(4) & 0xFF) << 8) | (buffer.get(5) & 0xFF);
            if (payloadLength > 64) {
                buffer.remove(0);
                results.add(ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH));
                continue;
            }
            int frameLength = 8 + payloadLength;
            if (buffer.size() < frameLength) return results;
            byte[] frame = take(frameLength);
            int expected = ScaleParsers.crc16(frame, frame.length - 2);
            int actual = ((frame[frameLength - 2] & 0xFF) << 8) | (frame[frameLength - 1] & 0xFF);
            if (expected != actual) {
                results.add(ParserResult.rejected(ParseRejectionReason.INVALID_CRC));
                continue;
            }
            results.addAll(decode(frame, payloadLength, arrivalMillis, monotonicSeconds));
        }
    }

    private List<ParserResult> decode(byte[] frame, int payloadLength, long arrivalMillis, double monotonicSeconds) {
        int opcode = frame[2] & 0xFF;
        int command = frame[3] & 0xFF;
        List<ParserResult> results = new ArrayList<>();
        if (opcode != 0x01 && opcode != 0x02) {
            results.add(ParserResult.rejected(ParseRejectionReason.UNSUPPORTED_FRAME));
            return results;
        }
        if (command == 0x01) {
            if (payloadLength < 8) {
                results.add(ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH));
                return results;
            }
            int raw = ((frame[6] & 0xFF) << 24) | ((frame[7] & 0xFF) << 16) | ((frame[8] & 0xFF) << 8) | (frame[9] & 0xFF);
            double grams = raw / 10.0;
            if (!Double.isFinite(grams) || Math.abs(grams) > 10_000) results.add(ParserResult.rejected(ParseRejectionReason.INVALID_RANGE));
            else results.add(ParserResult.sample(ScaleParsersBase.sample(arrivalMillis, monotonicSeconds, ScaleKind.TIMEMORE_DOT, grams)));
        } else if (command == 0x05) {
            if (payloadLength < 2) results.add(ParserResult.rejected(ParseRejectionReason.INVALID_LENGTH));
            else {
                int percent = frame[7] & 0xFF;
                results.add(percent <= 100 ? ParserResult.battery(percent) : ParserResult.rejected(ParseRejectionReason.INVALID_RANGE));
            }
        } else {
            results.add(ParserResult.rejected(ParseRejectionReason.UNSUPPORTED_FRAME));
        }
        return results;
    }

    private boolean startsWithHeader() {
        return (buffer.get(0) & 0xFF) == 0xA5 && (buffer.get(1) & 0xFF) == 0x5A;
    }

    private void discardUntilPotentialHeader() {
        int index = -1;
        for (int i = 1; i < buffer.size(); i++) {
            if ((buffer.get(i) & 0xFF) == 0xA5) {
                index = i;
                break;
            }
        }
        if (index >= 0) {
            for (int i = 0; i < index; i++) buffer.remove(0);
        } else {
            byte last = buffer.get(buffer.size() - 1);
            buffer.clear();
            if ((last & 0xFF) == 0xA5) buffer.add(last);
        }
    }

    private byte[] take(int count) {
        byte[] bytes = new byte[count];
        for (int i = 0; i < count; i++) bytes[i] = buffer.remove(0);
        return bytes;
    }
}

final class ScaleParsersBase {
    private ScaleParsersBase() {
    }

    static ScaleSample sample(long arrivalMillis, double monotonicSeconds, ScaleKind kind, double grams) {
        ScaleSample sample = new ScaleSample();
        sample.arrivalTimeMillis = arrivalMillis;
        sample.monotonicSeconds = monotonicSeconds;
        sample.scaleKind = kind;
        sample.weightGrams = grams;
        return sample;
    }
}
