package app.scalebench.android;

import java.util.ArrayList;
import java.util.List;

final class OfficialAnalysisPayload {
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
    ScaleQualityMetrics metrics;
    SharedChartAnalysisPayload chartAnalysis;

    static OfficialAnalysisPayload make(ScaleRecording recording, long generatedAtMillis) {
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);
        ScaleQualityMetrics metrics = recording.metrics;

        OfficialAnalysisPayload payload = new OfficialAnalysisPayload();
        payload.appName = recording.appName;
        payload.scoringModelVersion = recording.scoringModelVersion;
        payload.scoringProfileName = recording.scoringProfile.name;
        payload.recordingId = recording.id;
        payload.generatedAtMillis = generatedAtMillis;
        payload.platform = recording.platform;
        payload.mode = recording.mode;
        payload.protocolKind = recording.device != null
                ? recording.device.kind
                : recording.samples.isEmpty() ? ScaleKind.UNKNOWN : recording.samples.get(recording.samples.size() - 1).scaleKind;
        payload.deviceName = recording.device == null ? "Unknown device" : recording.device.name;
        payload.metrics = metrics;
        payload.chartAnalysis = new SharedChartAnalysisPayload(ChartAnalysis.create(recording, metrics));
        return payload;
    }
}

final class SharedChartAnalysisPayload {
    final int schemaVersion = 1;
    final List<SharedChartPointPayload> weightPoints;
    final List<SharedChartPointPayload> flowPoints;
    final SharedPacketTimelinePayload packetTimeline;
    final List<SharedProblemWindowPayload> problemWindows;
    final List<SharedDeductionPayload> deductionBreakdown;
    final AndroidSignalDiagnostics signalDiagnostics;

    SharedChartAnalysisPayload(AndroidChartAnalysis analysis) {
        weightPoints = new ArrayList<>();
        for (ChartPoint point : analysis.weightPoints) weightPoints.add(new SharedChartPointPayload(point));
        flowPoints = new ArrayList<>();
        for (ChartPoint point : analysis.flowPoints) flowPoints.add(new SharedChartPointPayload(point));
        packetTimeline = new SharedPacketTimelinePayload(analysis.packetTimeline);
        problemWindows = new ArrayList<>();
        for (ChartWindow window : analysis.problemWindows) problemWindows.add(new SharedProblemWindowPayload(window));
        deductionBreakdown = new ArrayList<>();
        for (AndroidChartDeduction deduction : analysis.deductionBreakdown) {
            deductionBreakdown.add(new SharedDeductionPayload(deduction));
        }
        signalDiagnostics = analysis.signalDiagnostics;
    }
}

final class SharedChartPointPayload {
    final double seconds;
    final double value;

    SharedChartPointPayload(ChartPoint point) {
        seconds = point.seconds;
        value = point.value;
    }
}

final class SharedPacketTimelinePayload {
    final List<SharedPacketTimelineEntryPayload> entries;
    final List<SharedSampleIntervalPayload> sampleIntervals;
    final List<SharedScoringGapPayload> scoringGaps;
    final double longGapThresholdMilliseconds;
    final double durationSeconds;

    SharedPacketTimelinePayload(AndroidPacketTimeline timeline) {
        entries = new ArrayList<>();
        for (AndroidPacketTimelineEntry entry : timeline.entries) entries.add(new SharedPacketTimelineEntryPayload(entry));
        sampleIntervals = new ArrayList<>();
        for (AndroidSampleInterval interval : timeline.sampleIntervals) sampleIntervals.add(new SharedSampleIntervalPayload(interval));
        scoringGaps = new ArrayList<>();
        for (AndroidScoringGap gap : timeline.scoringGaps) scoringGaps.add(new SharedScoringGapPayload(gap));
        longGapThresholdMilliseconds = timeline.thresholdMs;
        durationSeconds = timeline.getDurationSeconds();
    }
}

final class SharedPacketTimelineEntryPayload {
    final int index;
    final double relativeSeconds;
    final Double previousRelativeSeconds;
    final Double intervalMilliseconds;
    final String role;
    final String bytesHex;
    final String rejectionReason;
    final Integer sequence;
    final Double weightGrams;
    final String severity;
    final String lane;
    final List<String> evidence;
    final List<PacketFieldAnnotation> fields;

    SharedPacketTimelineEntryPayload(AndroidPacketTimelineEntry entry) {
        index = entry.id;
        relativeSeconds = entry.relativeSeconds;
        previousRelativeSeconds = entry.previousRelativeSeconds;
        intervalMilliseconds = entry.intervalMs;
        role = entry.roleLabel;
        bytesHex = ScaleParsers.normalizeHex(entry.bytesHex);
        rejectionReason = entry.rejectionReason == null ? null : SharedAnalysisContract.rejectionReasonName(entry.rejectionReason);
        sequence = entry.sequence;
        weightGrams = entry.weightGrams;
        severity = SharedAnalysisContract.severityName(entry.severity);
        lane = SharedAnalysisContract.laneName(entry.lane);
        evidence = entry.evidence;
        fields = entry.fields;
    }
}

final class SharedSampleIntervalPayload {
    final int index;
    final double previousRelativeSeconds;
    final double relativeSeconds;
    final double intervalMilliseconds;
    final String severity;

    SharedSampleIntervalPayload(AndroidSampleInterval interval) {
        index = interval.index;
        previousRelativeSeconds = interval.previousRelativeSeconds;
        relativeSeconds = interval.relativeSeconds;
        intervalMilliseconds = interval.intervalMs;
        severity = SharedAnalysisContract.severityName(interval.severity);
    }
}

final class SharedScoringGapPayload {
    final int index;
    final double startRelativeSeconds;
    final double endRelativeSeconds;
    final double intervalMilliseconds;

    SharedScoringGapPayload(AndroidScoringGap gap) {
        index = gap.index;
        startRelativeSeconds = gap.startSeconds;
        endRelativeSeconds = gap.endSeconds;
        intervalMilliseconds = gap.intervalMs;
    }
}

final class SharedProblemWindowPayload {
    final String id;
    final String title;
    final String category;
    final String severity;
    final double startSeconds;
    final double endSeconds;
    final Integer relatedPacketIndex;

    SharedProblemWindowPayload(ChartWindow window) {
        id = window.category.name() + "-" + Math.round(window.startSeconds * 1000.0);
        title = window.title;
        category = SharedAnalysisContract.lowerCamelEnum(window.category.name());
        severity = SharedAnalysisContract.severityName(window.severity);
        startSeconds = window.startSeconds;
        endSeconds = window.endSeconds;
        relatedPacketIndex = window.relatedPacketIndex;
    }
}

final class SharedDeductionPayload {
    final String category;
    final String title;
    final String detail;
    final Integer pointsLost;
    final String severity;

    SharedDeductionPayload(AndroidChartDeduction deduction) {
        category = SharedAnalysisContract.lowerCamelEnum(deduction.category.name());
        title = deduction.title;
        detail = deduction.detail;
        pointsLost = deduction.pointsLost;
        severity = SharedAnalysisContract.severityName(deduction.severity);
    }
}

final class SharedAnalysisContract {
    private SharedAnalysisContract() {
    }

    static String severityName(AndroidPacketSeverity severity) {
        switch (severity) {
            case NORMAL: return "normal";
            case INFO: return "info";
            case WARNING: return "warning";
            case PENALTY: return "penalty";
            default: throw new IllegalStateException("Unknown severity");
        }
    }

    static String laneName(AndroidPacketLane lane) {
        switch (lane) {
            case WEIGHT: return "weight";
            case METADATA: return "metadata";
            case CONTROL: return "control";
            case PENALTY: return "penalty";
            case UNKNOWN: return "unknown";
            default: throw new IllegalStateException("Unknown lane");
        }
    }

    static String rejectionReasonName(String value) {
        if ("INVALID_CRC".equals(value)) return "invalidCRC";
        return lowerCamelEnum(value);
    }

    static String lowerCamelEnum(String value) {
        StringBuilder result = new StringBuilder();
        boolean capitalizeNext = false;
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (c == '_') {
                capitalizeNext = true;
                continue;
            }
            if (result.length() == 0) result.append(Character.toLowerCase(c));
            else if (capitalizeNext) {
                result.append(Character.toUpperCase(c));
                capitalizeNext = false;
            } else {
                result.append(Character.toLowerCase(c));
            }
        }
        return result.toString();
    }
}
