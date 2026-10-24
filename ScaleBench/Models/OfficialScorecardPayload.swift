import Foundation

struct OfficialScorecardPayload: Codable, Equatable {
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
    var scoreTitle: String
    var score: Int?
    var scoreIsUpperBound: Bool
    var valid: Bool
    var validityReasons: [String]
    var coverage: Double?
    var purity: Double?
    var verificationCoveragePercent: Int?
    var sampleRateHz: Double?
    var deviceCadenceHz: Double?
    var receivedSampleRateHz: Double?
    var p95IntervalMilliseconds: Double?
    var maxGapMilliseconds: Double?
    var longGapCount: Int
    var missingSequenceCount: Int
    var rejectedPacketCount: Int
    var sampleCount: Int
    var rawPacketCount: Int
    var notes: String

    static func make(from recording: ScaleRecording, generatedAt: Date = Date()) -> OfficialScorecardPayload {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? generatedAt
        finalized.scoringProfile = .standard
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized, profile: .standard)
        let metrics = finalized.metrics
        return OfficialScorecardPayload(
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
            scoreTitle: finalized.mode == .idleStability ? "Idle Stability" : "Delivery",
            score: metrics.overallScore,
            scoreIsUpperBound: metrics.delivery?.purityIsUpperBound == true,
            valid: metrics.validity?.isValid == true,
            validityReasons: metrics.validity?.reasons ?? [],
            coverage: metrics.delivery?.coverage,
            purity: metrics.delivery?.purity,
            verificationCoveragePercent: metrics.protocolVerification?.verificationCoveragePercent,
            sampleRateHz: metrics.effectiveSampleRateHz,
            deviceCadenceHz: Self.usbDeviceCadenceHz(finalized),
            receivedSampleRateHz: Self.usbReceivedSampleRateHz(finalized),
            p95IntervalMilliseconds: metrics.packetIntervalP95Milliseconds,
            maxGapMilliseconds: metrics.packetIntervalMaxMilliseconds,
            longGapCount: metrics.longGapCount,
            missingSequenceCount: metrics.missingSequenceCount,
            rejectedPacketCount: metrics.rejectedPacketCount,
            sampleCount: finalized.samples.count,
            rawPacketCount: finalized.rawPackets.count,
            notes: finalized.notes
        )
    }

    private static func usbDeviceCadenceHz(_ recording: ScaleRecording) -> Double? {
        guard recording.source == .usbSerial else { return nil }
        let values = recording.samples.compactMap { $0.usbSerial?.hx711Hz }.filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func usbReceivedSampleRateHz(_ recording: ScaleRecording) -> Double? {
        guard recording.source == .usbSerial,
              let first = recording.samples.first?.monotonicSeconds,
              let last = recording.samples.last?.monotonicSeconds,
              last > first else { return nil }
        return Double(recording.samples.count) / (last - first)
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
