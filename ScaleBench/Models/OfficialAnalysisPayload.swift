import Foundation

struct OfficialAnalysisPayload: Codable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var appName: String
    var scoringModelVersion: String
    var scoringProfileName: String
    var recordingId: UUID
    var generatedAtMillis: Int64
    var platform: String
    var mode: RecordingMode
    var protocolKind: ScaleKind
    var deviceName: String
    var metrics: ScaleQualityMetrics
    var chartAnalysis: SharedChartAnalysisPayload

    static func make(from recording: ScaleRecording, generatedAt: Date = Date()) -> OfficialAnalysisPayload {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? generatedAt
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized, profile: finalized.scoringProfile)
        let metrics = finalized.metrics
        let analysis = ChartAnalysis.make(recording: finalized, metrics: metrics)

        return OfficialAnalysisPayload(
            schemaVersion: schemaVersion,
            appName: finalized.appName,
            scoringModelVersion: finalized.scoringModelVersion,
            scoringProfileName: finalized.scoringProfile.name,
            recordingId: finalized.id,
            generatedAtMillis: Int64((generatedAt.timeIntervalSince1970 * 1_000).rounded()),
            platform: finalized.platform,
            mode: finalized.mode,
            protocolKind: finalized.device?.kind ?? finalized.samples.last?.scaleKind ?? .unknown,
            deviceName: finalized.device?.name ?? "Unknown device",
            metrics: metrics,
            chartAnalysis: SharedChartAnalysisPayload(analysis: analysis)
        )
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct SharedChartAnalysisPayload: Codable, Equatable {
    var schemaVersion: Int
    var weightPoints: [SharedChartPointPayload]
    var flowPoints: [SharedChartPointPayload]
    var packetTimeline: SharedPacketTimelinePayload
    var problemWindows: [SharedProblemWindowPayload]
    var deductionBreakdown: [SharedDeductionPayload]
    var signalDiagnostics: SignalDiagnostics

    init(analysis: ChartAnalysis) {
        schemaVersion = ChartAnalysis.schemaVersion
        weightPoints = analysis.weightPoints.map(SharedChartPointPayload.init)
        flowPoints = analysis.flowPoints.map(SharedChartPointPayload.init)
        packetTimeline = SharedPacketTimelinePayload(timeline: analysis.packetTimeline)
        problemWindows = analysis.problemWindows.map(SharedProblemWindowPayload.init)
        deductionBreakdown = analysis.deductionBreakdown.map(SharedDeductionPayload.init)
        signalDiagnostics = analysis.signalDiagnostics
    }
}

struct SharedChartPointPayload: Codable, Equatable {
    var seconds: Double
    var value: Double

    init(point: ChartPoint) {
        seconds = point.seconds
        value = point.value
    }
}

struct SharedPacketTimelinePayload: Codable, Equatable {
    var entries: [SharedPacketTimelineEntryPayload]
    var sampleIntervals: [SharedSampleIntervalPayload]
    var scoringGaps: [SharedScoringGapPayload]
    var longGapThresholdMilliseconds: Double
    var durationSeconds: Double

    init(timeline: PacketTimeline) {
        entries = timeline.entries.map(SharedPacketTimelineEntryPayload.init)
        sampleIntervals = timeline.sampleIntervals.map(SharedSampleIntervalPayload.init)
        scoringGaps = timeline.scoringGaps.map(SharedScoringGapPayload.init)
        longGapThresholdMilliseconds = timeline.longGapThresholdMilliseconds
        durationSeconds = timeline.durationSeconds
    }
}

struct SharedPacketTimelineEntryPayload: Codable, Equatable {
    var index: Int
    var relativeSeconds: Double
    var previousRelativeSeconds: Double?
    var intervalMilliseconds: Double?
    var role: PacketRole
    var bytesHex: String
    var rejectionReason: ParseRejectionReason?
    var sequence: UInt8?
    var weightGrams: Double?
    var severity: String
    var lane: String
    var evidence: [String]
    var fields: [PacketFieldAnnotation]

    init(entry: PacketTimelineEntry) {
        index = entry.index
        relativeSeconds = entry.relativeSeconds
        previousRelativeSeconds = entry.previousRelativeSeconds
        intervalMilliseconds = entry.intervalMilliseconds
        role = entry.packet.role
        bytesHex = PacketFieldDecoder.normalizedHex(entry.packet.bytesHex)
        rejectionReason = entry.packet.rejectionReason
        sequence = entry.packet.sequence
        weightGrams = entry.packet.weightGrams
        severity = entry.severity.contractValue
        lane = entry.lane.contractValue
        evidence = entry.evidence
        fields = PacketFieldDecoder.annotations(for: entry.packet)
    }
}

struct SharedSampleIntervalPayload: Codable, Equatable {
    var index: Int
    var previousRelativeSeconds: Double
    var relativeSeconds: Double
    var intervalMilliseconds: Double
    var severity: String

    init(entry: SampleIntervalEntry) {
        index = entry.index
        previousRelativeSeconds = entry.previousRelativeSeconds
        relativeSeconds = entry.relativeSeconds
        intervalMilliseconds = entry.intervalMilliseconds
        severity = entry.severity.contractValue
    }
}

struct SharedScoringGapPayload: Codable, Equatable {
    var index: Int
    var startRelativeSeconds: Double
    var endRelativeSeconds: Double
    var intervalMilliseconds: Double

    init(gap: ScoringGap) {
        index = gap.id
        startRelativeSeconds = gap.startRelativeSeconds
        endRelativeSeconds = gap.endRelativeSeconds
        intervalMilliseconds = gap.intervalMilliseconds
    }
}

struct SharedProblemWindowPayload: Codable, Equatable {
    var id: String
    var title: String
    var category: String
    var severity: String
    var startSeconds: Double
    var endSeconds: Double
    var relatedPacketIndex: Int?

    init(window: ChartProblemWindow) {
        id = window.id
        title = window.title
        category = window.category.rawValue
        severity = window.severity.contractValue
        startSeconds = window.startSeconds
        endSeconds = window.endSeconds
        relatedPacketIndex = window.relatedPacketIndex
    }
}

struct SharedDeductionPayload: Codable, Equatable {
    var category: String
    var title: String
    var detail: String
    var pointsLost: Int?
    var severity: String

    init(deduction: ChartDeduction) {
        category = deduction.category.rawValue
        title = deduction.title
        detail = deduction.detail
        pointsLost = deduction.pointsLost
        severity = deduction.severity.contractValue
    }
}

private extension PacketSeverity {
    var contractValue: String {
        switch self {
        case .normal: "normal"
        case .info: "info"
        case .warning: "warning"
        case .penalty: "penalty"
        }
    }
}

private extension PacketLane {
    var contractValue: String {
        switch self {
        case .weight: "weight"
        case .metadata: "metadata"
        case .control: "control"
        case .penalty: "penalty"
        case .unknown: "unknown"
        }
    }
}
