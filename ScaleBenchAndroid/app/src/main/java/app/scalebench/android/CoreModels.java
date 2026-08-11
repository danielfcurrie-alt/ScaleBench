package app.scalebench.android;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

enum ScaleKind {
    UNKNOWN("Unknown"),
    BOOKOO("BooKoo Standard"),
    BOOKOO_MINI("BooKoo Mini Native"),
    BOOKOO_ULTRA("BooKoo Ultra Native"),
    WEIGH_MY_BRU("WeighMyBru"),
    WEIGH_MY_BRU_PLUS("WeighMyBru+"),
    EUREKA("Eureka / Solo Barista"),
    ACAIA("Acaia"),
    DECENT("Decent Scale"),
    ESPRESSI("Espressi Scale"),
    DIFLUID("DiFluid Microbalance"),
    DIFLUID_TI("DiFluid Microbalance Ti"),
    FELICITA("Felicita"),
    FUTULA("Futula / LFSmart / Lefu"),
    SKALE2("Skale2"),
    TIMEMORE_DOT("Timemore Dot");

    final String displayName;

    ScaleKind(String displayName) {
        this.displayName = displayName;
    }
}

enum RecordingMode {
    IDLE_STABILITY("Idle Stability"),
    SHOT("Shot / Pour"),
    TARE_LATENCY("Tare Latency"),
    TRANSPORT_STRESS("Transport Stress"),
    BATTERY_STABILITY("Battery Logging");

    final String displayName;

    RecordingMode(String displayName) {
        this.displayName = displayName;
    }
}

enum PacketRole {
    WEIGHT, CAPABILITIES, BATTERY, COMMAND_ACK, UNKNOWN
}

enum ParseRejectionReason {
    INVALID_LENGTH,
    INVALID_PRODUCT,
    INVALID_MESSAGE_TYPE,
    INVALID_CHECKSUM,
    INVALID_HEADER,
    INVALID_UNIT,
    INVALID_RANGE,
    INVALID_CRC,
    INVALID_FLOAT,
    UNSUPPORTED_FRAME,
    UNSUPPORTED_CHARACTERISTIC
}

final class DiscoveredScale {
    final String address;
    final String name;
    final ScaleKind kind;
    final int rssi;
    final List<String> advertisedServices;

    DiscoveredScale(String address, String name, ScaleKind kind, int rssi, List<String> advertisedServices) {
        this.address = address;
        this.name = name;
        this.kind = kind;
        this.rssi = rssi;
        this.advertisedServices = advertisedServices;
    }
}

final class ScaleDeviceIdentity {
    String name;
    String identifier;
    ScaleKind kind;
    List<String> advertisedServices;
}

final class ScaleStatusFlags {
    final boolean timerRunning;
    final boolean hx711Connected;
    final boolean tarePending;
    final boolean atomicTareStartPending;
    final boolean batteryLow;
    final boolean batteryCritical;
    final boolean batteryPresent;
    final boolean displayPresent;

    ScaleStatusFlags(int value) {
        timerRunning = (value & 0x01) != 0;
        hx711Connected = (value & 0x02) != 0;
        tarePending = (value & 0x04) != 0;
        atomicTareStartPending = (value & 0x08) != 0;
        batteryLow = (value & 0x10) != 0;
        batteryCritical = (value & 0x20) != 0;
        batteryPresent = (value & 0x40) != 0;
        displayPresent = (value & 0x80) != 0;
    }
}

final class ScaleDiagnosticFlags {
    final boolean recentBump;
    final boolean longGapSeen;
    final boolean cadenceValid;
    final boolean detected80Sps;
    final boolean detected10Sps;
    final boolean qualityValid;
    final boolean flowPresent;
    final boolean extensionPresent;

    ScaleDiagnosticFlags(int value) {
        recentBump = (value & 0x01) != 0;
        longGapSeen = (value & 0x02) != 0;
        cadenceValid = (value & 0x04) != 0;
        detected80Sps = (value & 0x08) != 0;
        detected10Sps = (value & 0x10) != 0;
        qualityValid = (value & 0x20) != 0;
        flowPresent = (value & 0x40) != 0;
        extensionPresent = (value & 0x80) != 0;
    }
}

final class WmbPlusCapabilities {
    int payloadVersion;
    int protocolMajor;
    int protocolMinor;
    long featureMask;
    int preferredAtomicCommand;
    int preferredAtomicData1;
    int extensionPacketVersion;
    int extensionPacketLength;

    boolean supportsExtendedPacket() {
        return hasFeature(8) && extensionPacketVersion == 1 && extensionPacketLength == 20;
    }

    private boolean hasFeature(int bit) {
        return (featureMask & (1L << bit)) != 0;
    }
}

final class ScaleSample {
    final String id = UUID.randomUUID().toString();
    long arrivalTimeMillis;
    double monotonicSeconds;
    ScaleKind scaleKind;
    double weightGrams;
    Long deviceTimestampMilliseconds;
    Integer sequence;
    Integer batteryPercent;
    Double flowGramsPerSecond;
    Integer firmwareQualityScore;
    Integer detectedSampleRateHz;
    ScaleStatusFlags statusFlags;
    ScaleDiagnosticFlags diagnosticFlags;
}

final class ScaleBatteryEvent {
    final String id = UUID.randomUUID().toString();
    long arrivalTimeMillis;
    double monotonicSeconds;
    ScaleKind scaleKind;
    int percent;
}

final class RawScalePacket {
    final String id = UUID.randomUUID().toString();
    long arrivalTimeMillis;
    double monotonicSeconds;
    ScaleKind scaleKind;
    String characteristicUuid;
    PacketRole role;
    String bytesHex;
    ParseRejectionReason rejectionReason;
}

final class ScaleQualityMetrics {
    Integer overallScore;
    Integer transportScore;
    Integer stabilityScore;
    Integer metadataScore;
    Double effectiveSampleRateHz;
    Double packetIntervalP50Milliseconds;
    Double packetIntervalP95Milliseconds;
    Double packetIntervalMaxMilliseconds;
    int longGapCount;
    int missingSequenceCount;
    int duplicateOrOutOfOrderTimestampCount;
    int rejectedPacketCount;
    Double idleNoisePeakToPeakGrams;
    Double idleNoiseStandardDeviationGrams;
    Double driftGramsPerMinute;
    Integer batteryMinPercent;
    Integer batteryMaxPercent;
    Double firmwareQualityAverage;
    int firmwareBumpCount;

    static ScaleQualityMetrics empty() {
        return new ScaleQualityMetrics();
    }
}

final class ScoringProfile {
    static final String STANDARD_BENCHMARK_NAME = "ScaleBench Standard v1";

    String name;
    double transportWeight;
    double stabilityWeight;
    double metadataWeight;
    double minimumLongGapMilliseconds;
    double longGapMultiplier;
    int longGapPenalty;
    int missingSequencePenalty;
    int timestampIssuePenalty;
    double rejectedPacketRatePenaltyScale;
    double idleNoiseFreePeakToPeakGrams;
    double idleNoisePeakToPeakPenaltyScale;
    double idleStandardDeviationFreeGrams;
    double idleStandardDeviationPenaltyScale;
    double driftPenaltyScale;

    static ScoringProfile standard() {
        ScoringProfile p = new ScoringProfile();
        p.name = STANDARD_BENCHMARK_NAME;
        p.transportWeight = 0.50;
        p.stabilityWeight = 0.35;
        p.metadataWeight = 0.15;
        p.minimumLongGapMilliseconds = 300;
        p.longGapMultiplier = 3;
        p.longGapPenalty = 5;
        p.missingSequencePenalty = 3;
        p.timestampIssuePenalty = 4;
        p.rejectedPacketRatePenaltyScale = 100;
        p.idleNoiseFreePeakToPeakGrams = 0.20;
        p.idleNoisePeakToPeakPenaltyScale = 10;
        p.idleStandardDeviationFreeGrams = 0.05;
        p.idleStandardDeviationPenaltyScale = 50;
        p.driftPenaltyScale = 4;
        return p;
    }

    ScoringProfile normalized() {
        ScoringProfile copy = copy();
        double tw = nonnegativeFinite(transportWeight, 0);
        double sw = nonnegativeFinite(stabilityWeight, 0);
        double mw = nonnegativeFinite(metadataWeight, 0);
        double total = tw + sw + mw;
        if (total <= 0 || !Double.isFinite(total)) {
            return standard();
        }
        copy.transportWeight = tw / total;
        copy.stabilityWeight = sw / total;
        copy.metadataWeight = mw / total;
        copy.minimumLongGapMilliseconds = nonnegativeFinite(copy.minimumLongGapMilliseconds, 300);
        copy.longGapMultiplier = nonnegativeFinite(copy.longGapMultiplier, 3);
        copy.longGapPenalty = Math.max(0, copy.longGapPenalty);
        copy.missingSequencePenalty = Math.max(0, copy.missingSequencePenalty);
        copy.timestampIssuePenalty = Math.max(0, copy.timestampIssuePenalty);
        copy.rejectedPacketRatePenaltyScale = nonnegativeFinite(copy.rejectedPacketRatePenaltyScale, 100);
        copy.idleNoiseFreePeakToPeakGrams = nonnegativeFinite(copy.idleNoiseFreePeakToPeakGrams, 0.20);
        copy.idleNoisePeakToPeakPenaltyScale = nonnegativeFinite(copy.idleNoisePeakToPeakPenaltyScale, 10);
        copy.idleStandardDeviationFreeGrams = nonnegativeFinite(copy.idleStandardDeviationFreeGrams, 0.05);
        copy.idleStandardDeviationPenaltyScale = nonnegativeFinite(copy.idleStandardDeviationPenaltyScale, 50);
        copy.driftPenaltyScale = nonnegativeFinite(copy.driftPenaltyScale, 4);
        return copy;
    }

    private ScoringProfile copy() {
        ScoringProfile p = new ScoringProfile();
        p.name = name;
        p.transportWeight = transportWeight;
        p.stabilityWeight = stabilityWeight;
        p.metadataWeight = metadataWeight;
        p.minimumLongGapMilliseconds = minimumLongGapMilliseconds;
        p.longGapMultiplier = longGapMultiplier;
        p.longGapPenalty = longGapPenalty;
        p.missingSequencePenalty = missingSequencePenalty;
        p.timestampIssuePenalty = timestampIssuePenalty;
        p.rejectedPacketRatePenaltyScale = rejectedPacketRatePenaltyScale;
        p.idleNoiseFreePeakToPeakGrams = idleNoiseFreePeakToPeakGrams;
        p.idleNoisePeakToPeakPenaltyScale = idleNoisePeakToPeakPenaltyScale;
        p.idleStandardDeviationFreeGrams = idleStandardDeviationFreeGrams;
        p.idleStandardDeviationPenaltyScale = idleStandardDeviationPenaltyScale;
        p.driftPenaltyScale = driftPenaltyScale;
        return p;
    }

    private static double nonnegativeFinite(double value, double fallback) {
        return Double.isFinite(value) ? Math.max(0, value) : fallback;
    }
}

final class ScaleRecording {
    static final int SCHEMA_VERSION = 4;

    final String id = UUID.randomUUID().toString();
    int schemaVersion = SCHEMA_VERSION;
    String appName = "ScaleBench Android";
    String appVersion = "0.1.0";
    RecordingMode mode;
    ScaleDeviceIdentity device;
    long startedAtMillis;
    Long endedAtMillis;
    String notes = "";
    final List<RawScalePacket> rawPackets = new ArrayList<>();
    final List<ScaleSample> samples = new ArrayList<>();
    final List<ScaleBatteryEvent> batteryEvents = new ArrayList<>();
    WmbPlusCapabilities capabilities;
    ScoringProfile scoringProfile = ScoringProfile.standard();
    ScaleQualityMetrics metrics = ScaleQualityMetrics.empty();

    static ScaleRecording empty(RecordingMode mode) {
        ScaleRecording recording = new ScaleRecording();
        recording.mode = mode;
        recording.startedAtMillis = System.currentTimeMillis();
        return recording;
    }

    String defaultTitle() {
        String protocol = device != null ? device.kind.displayName
                : samples.isEmpty() ? "Unknown Scale" : samples.get(samples.size() - 1).scaleKind.displayName;
        return String.format(Locale.US, "%s - %s", protocol, mode.displayName);
    }
}

final class SavedRecordingSummary {
    String id;
    long savedAtMillis;
    String title;
    String notes;
    String recordingFileName;
    ScaleKind protocolKind;
    RecordingMode mode;
    Integer score;
    int sampleCount;
    int rawPacketCount;
}
