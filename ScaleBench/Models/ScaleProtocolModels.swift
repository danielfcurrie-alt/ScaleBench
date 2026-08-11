import Foundation

enum ScaleKind: String, Codable, CaseIterable, Identifiable {
    case unknown
    case bookoo
    case bookooMini
    case bookooUltra
    case weighMyBru
    case weighMyBruPlus
    case eureka
    case acaia
    case decent
    case espressi
    case difluid
    case difluidTi
    case felicita
    case futula
    case skale2
    case timemoreDot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .bookoo: "BooKoo Standard"
        case .bookooMini: "BooKoo Mini Native"
        case .bookooUltra: "BooKoo Ultra Native"
        case .weighMyBru: "WeighMyBru"
        case .weighMyBruPlus: "WeighMyBru+"
        case .eureka: "Eureka / Solo Barista"
        case .acaia: "Acaia"
        case .decent: "Decent Scale"
        case .espressi: "Espressi Scale"
        case .difluid: "DiFluid Microbalance"
        case .difluidTi: "DiFluid Microbalance Ti"
        case .felicita: "Felicita"
        case .futula: "Futula / LFSmart / Lefu"
        case .skale2: "Skale2"
        case .timemoreDot: "Timemore Dot"
        }
    }
}

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case idleStability
    case shot
    case tareLatency
    case transportStress
    case batteryStability

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idleStability: "Idle Stability"
        case .shot: "Shot / Pour"
        case .tareLatency: "Tare Latency"
        case .transportStress: "Transport Stress"
        case .batteryStability: "Battery Stability"
        }
    }
}

enum ScoringPreset: String, Codable, CaseIterable, Identifiable {
    case standard
    case strict
    case transportFocused

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: ScoringProfile.standardBenchmarkName
        case .strict: "Strict"
        case .transportFocused: "Transport Focused"
        }
    }

    var profile: ScoringProfile {
        switch self {
        case .standard: .standard
        case .strict: .strict
        case .transportFocused: .transportFocused
        }
    }
}

struct ScoringProfile: Codable, Equatable {
    static let standardBenchmarkName = "ScaleBench Standard v1"

    var name: String
    var transportWeight: Double
    var stabilityWeight: Double
    var metadataWeight: Double
    var minimumLongGapMilliseconds: Double
    var longGapMultiplier: Double
    var longGapPenalty: Int
    var missingSequencePenalty: Int
    var timestampIssuePenalty: Int
    var rejectedPacketRatePenaltyScale: Double
    var idleNoiseFreePeakToPeakGrams: Double
    var idleNoisePeakToPeakPenaltyScale: Double
    var idleStandardDeviationFreeGrams: Double
    var idleStandardDeviationPenaltyScale: Double
    var driftPenaltyScale: Double

    static let standard = ScoringProfile(
        name: standardBenchmarkName,
        transportWeight: 0.50,
        stabilityWeight: 0.35,
        metadataWeight: 0.15,
        minimumLongGapMilliseconds: 300,
        longGapMultiplier: 3,
        longGapPenalty: 5,
        missingSequencePenalty: 3,
        timestampIssuePenalty: 4,
        rejectedPacketRatePenaltyScale: 100,
        idleNoiseFreePeakToPeakGrams: 0.20,
        idleNoisePeakToPeakPenaltyScale: 10,
        idleStandardDeviationFreeGrams: 0.05,
        idleStandardDeviationPenaltyScale: 50,
        driftPenaltyScale: 4
    )

    static let strict = ScoringProfile(
        name: "Strict",
        transportWeight: 0.55,
        stabilityWeight: 0.35,
        metadataWeight: 0.10,
        minimumLongGapMilliseconds: 200,
        longGapMultiplier: 2.5,
        longGapPenalty: 7,
        missingSequencePenalty: 5,
        timestampIssuePenalty: 6,
        rejectedPacketRatePenaltyScale: 140,
        idleNoiseFreePeakToPeakGrams: 0.10,
        idleNoisePeakToPeakPenaltyScale: 18,
        idleStandardDeviationFreeGrams: 0.03,
        idleStandardDeviationPenaltyScale: 80,
        driftPenaltyScale: 7
    )

    static let transportFocused = ScoringProfile(
        name: "Transport Focused",
        transportWeight: 0.75,
        stabilityWeight: 0.10,
        metadataWeight: 0.15,
        minimumLongGapMilliseconds: 300,
        longGapMultiplier: 3,
        longGapPenalty: 7,
        missingSequencePenalty: 6,
        timestampIssuePenalty: 6,
        rejectedPacketRatePenaltyScale: 150,
        idleNoiseFreePeakToPeakGrams: 0.20,
        idleNoisePeakToPeakPenaltyScale: 5,
        idleStandardDeviationFreeGrams: 0.05,
        idleStandardDeviationPenaltyScale: 25,
        driftPenaltyScale: 2
    )

    var normalized: ScoringProfile {
        var copy = self
        let total = max(transportWeight + stabilityWeight + metadataWeight, 0.0001)
        copy.transportWeight = transportWeight / total
        copy.stabilityWeight = stabilityWeight / total
        copy.metadataWeight = metadataWeight / total
        return copy
    }
}

enum PacketRole: String, Codable {
    case weight
    case capabilities
    case battery
    case commandAck
    case unknown
}

enum ParseRejectionReason: String, Codable, Equatable, Error {
    case invalidLength
    case invalidProduct
    case invalidMessageType
    case invalidChecksum
    case invalidHeader
    case invalidUnit
    case invalidRange
    case invalidCRC
    case invalidFloat
    case unsupportedFrame
    case unsupportedCharacteristic
}

enum ScaleParserEvent: Equatable {
    case sample(ScaleSample)
    case battery(percent: Int)
    case rejected(ParseRejectionReason)
}

struct DiscoveredScale: Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: ScaleKind
    var rssi: Int
}

struct ScaleDeviceIdentity: Codable, Equatable {
    var name: String
    var identifier: UUID
    var kind: ScaleKind
    var advertisedServices: [String]
}

struct RawScalePacket: Codable, Identifiable, Equatable {
    var id = UUID()
    var arrivalTime: Date
    var monotonicSeconds: Double
    var scaleKind: ScaleKind
    var characteristicUUID: String
    var role: PacketRole
    var bytesHex: String
    var rejectionReason: ParseRejectionReason?
}

struct ScaleSample: Codable, Identifiable, Equatable {
    var id = UUID()
    var arrivalTime: Date
    var monotonicSeconds: Double
    var scaleKind: ScaleKind
    var weightGrams: Double
    var deviceTimestampMilliseconds: UInt32?
    var sequence: UInt8?
    var batteryPercent: Int?
    var flowGramsPerSecond: Double?
    var firmwareQualityScore: Int?
    var detectedSampleRateHz: Int?
    var statusFlags: ScaleStatusFlags?
    var diagnosticFlags: ScaleDiagnosticFlags?
}

struct ScaleStatusFlags: Codable, Equatable {
    var timerRunning: Bool
    var hx711Connected: Bool
    var tarePending: Bool
    var atomicTareStartPending: Bool
    var batteryLow: Bool
    var batteryCritical: Bool
    var batteryPresent: Bool
    var displayPresent: Bool

    init(byte: UInt8) {
        timerRunning = byte & 0x01 != 0
        hx711Connected = byte & 0x02 != 0
        tarePending = byte & 0x04 != 0
        atomicTareStartPending = byte & 0x08 != 0
        batteryLow = byte & 0x10 != 0
        batteryCritical = byte & 0x20 != 0
        batteryPresent = byte & 0x40 != 0
        displayPresent = byte & 0x80 != 0
    }
}

struct ScaleDiagnosticFlags: Codable, Equatable {
    var recentBump: Bool
    var longGapSeen: Bool
    var cadenceValid: Bool
    var detected80SPS: Bool
    var detected10SPS: Bool
    var qualityValid: Bool
    var flowPresent: Bool
    var extensionPresent: Bool

    init(byte: UInt8) {
        recentBump = byte & 0x01 != 0
        longGapSeen = byte & 0x02 != 0
        cadenceValid = byte & 0x04 != 0
        detected80SPS = byte & 0x08 != 0
        detected10SPS = byte & 0x10 != 0
        qualityValid = byte & 0x20 != 0
        flowPresent = byte & 0x40 != 0
        extensionPresent = byte & 0x80 != 0
    }
}

struct WMBPlusCapabilities: Codable, Equatable {
    var payloadVersion: UInt8
    var protocolMajor: UInt8
    var protocolMinor: UInt8
    var featureMask: UInt32
    var preferredAtomicCommand: UInt8
    var preferredAtomicData1: UInt8
    var extensionPacketVersion: UInt8
    var extensionPacketLength: UInt8

    var supportsStandardBattery: Bool { hasFeature(bit: 0) }
    var supportsAtomicTareStart: Bool { hasFeature(bit: 2) }
    var supportsExtendedPacket: Bool { hasFeature(bit: 8) && extensionPacketVersion == 1 && extensionPacketLength == 20 }
    var supportsSequence: Bool { hasFeature(bit: 12) }
    var supportsScaleQuality: Bool { hasFeature(bit: 13) }

    func hasFeature(bit: Int) -> Bool {
        featureMask & (UInt32(1) << UInt32(bit)) != 0
    }
}

struct ScaleRecording: Codable, Equatable {
    static let schemaVersion = 2

    var id = UUID()
    var schemaVersion = Self.schemaVersion
    var appName = "ScaleBench"
    var appVersion = "0.1.0"
    var mode: RecordingMode
    var device: ScaleDeviceIdentity?
    var startedAt: Date
    var endedAt: Date?
    var notes: String
    var rawPackets: [RawScalePacket]
    var samples: [ScaleSample]
    var capabilities: WMBPlusCapabilities?
    var scoringProfile: ScoringProfile
    var metrics: ScaleQualityMetrics

    static func empty(mode: RecordingMode = .idleStability, scoringProfile: ScoringProfile = .standard) -> ScaleRecording {
        ScaleRecording(
            mode: mode,
            device: nil,
            startedAt: Date(),
            endedAt: nil,
            notes: "",
            rawPackets: [],
            samples: [],
            capabilities: nil,
            scoringProfile: scoringProfile,
            metrics: .empty
        )
    }
}

struct SavedScaleRecording: Codable, Identifiable, Equatable {
    var id = UUID()
    var savedAt: Date
    var title: String
    var notes: String
    var recording: ScaleRecording
    var scoreSnapshot: ScaleQualityMetrics

    var protocolKind: ScaleKind {
        recording.device?.kind ?? recording.samples.last?.scaleKind ?? .unknown
    }

    static func make(
        recording inputRecording: ScaleRecording,
        title inputTitle: String? = nil,
        notes inputNotes: String
    ) -> SavedScaleRecording {
        var finalized = inputRecording
        finalized.endedAt = finalized.endedAt ?? Date()
        finalized.notes = inputNotes
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)

        let title = inputTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? inputTitle!
            : defaultTitle(for: finalized)

        return SavedScaleRecording(
            savedAt: Date(),
            title: title,
            notes: inputNotes,
            recording: finalized,
            scoreSnapshot: finalized.metrics
        )
    }

    private static func defaultTitle(for recording: ScaleRecording) -> String {
        let protocolName = recording.device?.kind.displayName
            ?? recording.samples.last?.scaleKind.displayName
            ?? "Unknown Scale"
        return "\(protocolName) · \(recording.mode.displayName)"
    }
}

struct ProtocolComparisonRow: Identifiable, Equatable {
    var id: UUID
    var title: String
    var protocolKind: ScaleKind
    var mode: RecordingMode
    var score: Int?
    var sampleRateHz: Double?
    var p95IntervalMilliseconds: Double?
    var maxGapMilliseconds: Double?
    var longGapCount: Int
    var rejectedPacketCount: Int
    var sampleCount: Int
    var notes: String
}

struct ProtocolComparison: Equatable {
    var rows: [ProtocolComparisonRow]

    var bestOverall: ProtocolComparisonRow? {
        rows.max { lhs, rhs in
            (lhs.score ?? -1) < (rhs.score ?? -1)
        }
    }

    var groupedByProtocol: [(ScaleKind, [ProtocolComparisonRow])] {
        Dictionary(grouping: rows, by: \.protocolKind)
            .map { ($0.key, $0.value.sorted(by: Self.compareRows)) }
            .sorted { $0.0.displayName < $1.0.displayName }
    }

    static func make(from recordings: [SavedScaleRecording]) -> ProtocolComparison {
        ProtocolComparison(rows: recordings.map { saved in
            ProtocolComparisonRow(
                id: saved.id,
                title: saved.title,
                protocolKind: saved.protocolKind,
                mode: saved.recording.mode,
                score: saved.scoreSnapshot.overallScore,
                sampleRateHz: saved.scoreSnapshot.effectiveSampleRateHz,
                p95IntervalMilliseconds: saved.scoreSnapshot.packetIntervalP95Milliseconds,
                maxGapMilliseconds: saved.scoreSnapshot.packetIntervalMaxMilliseconds,
                longGapCount: saved.scoreSnapshot.longGapCount,
                rejectedPacketCount: saved.scoreSnapshot.rejectedPacketCount,
                sampleCount: saved.recording.samples.count,
                notes: saved.notes
            )
        }.sorted(by: compareRows))
    }

    private static func compareRows(_ lhs: ProtocolComparisonRow, _ rhs: ProtocolComparisonRow) -> Bool {
        if (lhs.score ?? -1) != (rhs.score ?? -1) {
            return (lhs.score ?? -1) > (rhs.score ?? -1)
        }
        return lhs.title < rhs.title
    }
}

struct ScaleQualityMetrics: Codable, Equatable {
    var overallScore: Int?
    var transportScore: Int?
    var stabilityScore: Int?
    var metadataScore: Int?
    var effectiveSampleRateHz: Double?
    var packetIntervalP50Milliseconds: Double?
    var packetIntervalP95Milliseconds: Double?
    var packetIntervalMaxMilliseconds: Double?
    var longGapCount: Int
    var missingSequenceCount: Int
    var duplicateOrOutOfOrderTimestampCount: Int
    var rejectedPacketCount: Int
    var idleNoisePeakToPeakGrams: Double?
    var idleNoiseStandardDeviationGrams: Double?
    var driftGramsPerMinute: Double?
    var batteryMinPercent: Int?
    var batteryMaxPercent: Int?
    var firmwareQualityAverage: Double?
    var firmwareBumpCount: Int

    static let empty = ScaleQualityMetrics(
        overallScore: nil,
        transportScore: nil,
        stabilityScore: nil,
        metadataScore: nil,
        effectiveSampleRateHz: nil,
        packetIntervalP50Milliseconds: nil,
        packetIntervalP95Milliseconds: nil,
        packetIntervalMaxMilliseconds: nil,
        longGapCount: 0,
        missingSequenceCount: 0,
        duplicateOrOutOfOrderTimestampCount: 0,
        rejectedPacketCount: 0,
        idleNoisePeakToPeakGrams: nil,
        idleNoiseStandardDeviationGrams: nil,
        driftGramsPerMinute: nil,
        batteryMinPercent: nil,
        batteryMaxPercent: nil,
        firmwareQualityAverage: nil,
        firmwareBumpCount: 0
    )
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
