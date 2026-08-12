package app.scalebench.android;

import java.util.ArrayList;
import java.util.List;

final class OfficialScorecardPayload {
    static final int SCHEMA_VERSION = 1;

    int schemaVersion = SCHEMA_VERSION;
    String appName;
    String scoringModelVersion;
    String scoringProfileName;
    String recordingId;
    long generatedAtMillis;
    String platform;
    RecordingMode mode;
    ScaleKind protocolKind;
    String deviceName;
    String scoreTitle;
    Integer score;
    boolean scoreIsUpperBound;
    boolean valid;
    List<String> validityReasons = new ArrayList<>();
    int verificationCoveragePercent;
    Double coverage;
    Double purity;
    Double sampleRateHz;
    Double p95IntervalMilliseconds;
    Double maxGapMilliseconds;
    int longGapCount;
    int missingSequenceCount;
    int rejectedPacketCount;
    int sampleCount;
    int rawPacketCount;
    String notes;

    static OfficialScorecardPayload make(ScaleRecording recording, long generatedAtMillis) {
        recording.scoringProfile = ScoringProfile.standard();
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);
        ScaleQualityMetrics metrics = recording.metrics;

        OfficialScorecardPayload payload = new OfficialScorecardPayload();
        payload.appName = recording.appName;
        payload.scoringModelVersion = recording.scoringModelVersion;
        payload.scoringProfileName = recording.scoringProfile.name;
        payload.recordingId = recording.id;
        payload.generatedAtMillis = generatedAtMillis;
        payload.platform = "android";
        payload.mode = recording.mode;
        payload.protocolKind = recording.device != null
                ? recording.device.kind
                : recording.samples.isEmpty() ? ScaleKind.UNKNOWN : recording.samples.get(recording.samples.size() - 1).scaleKind;
        payload.deviceName = recording.device == null ? "Unknown device" : recording.device.name;
        payload.scoreTitle = recording.mode == RecordingMode.IDLE_STABILITY ? "Idle Stability" : "Delivery";
        payload.score = metrics.overallScore;
        payload.scoreIsUpperBound = metrics.delivery != null && Boolean.TRUE.equals(metrics.delivery.purityIsUpperBound);
        payload.valid = metrics.validity != null && metrics.validity.isValid;
        if (metrics.validity != null) payload.validityReasons = new ArrayList<>(metrics.validity.reasons);
        payload.verificationCoveragePercent = metrics.protocolVerification == null
                ? 0 : metrics.protocolVerification.verificationCoveragePercent;
        payload.coverage = metrics.delivery == null ? null : metrics.delivery.coverage;
        payload.purity = metrics.delivery == null ? null : metrics.delivery.purity;
        payload.sampleRateHz = metrics.effectiveSampleRateHz;
        payload.p95IntervalMilliseconds = metrics.packetIntervalP95Milliseconds;
        payload.maxGapMilliseconds = metrics.packetIntervalMaxMilliseconds;
        payload.longGapCount = metrics.longGapCount;
        payload.missingSequenceCount = metrics.missingSequenceCount;
        payload.rejectedPacketCount = metrics.rejectedPacketCount;
        payload.sampleCount = recording.samples.size();
        payload.rawPacketCount = recording.rawPackets.size();
        payload.notes = recording.notes;
        return payload;
    }
}
