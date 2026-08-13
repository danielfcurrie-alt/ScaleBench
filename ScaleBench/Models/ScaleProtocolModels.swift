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
    case stepResponse
    case tareLatency
    case transportStress
    case batteryStability

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idleStability: "Idle Stability"
        case .shot: "Shot / Pour"
        case .stepResponse: "Step Response"
        case .tareLatency: "Tare Latency"
        case .transportStress: "Transport Stress"
        case .batteryStability: "Battery Logging"
        }
    }

    var shortDescription: String {
        switch self {
        case .idleStability:
            "Leave the scale untouched. Measures noise, drift, cadence, packet gaps, and bump/disturbance behavior."
        case .shot:
            "Record a real espresso shot or pour. This is the normal mode for public ScaleBench score comparisons."
        case .stepResponse:
            "Measure response speed. Start empty, wait 2 seconds, add at least 5 g in one motion, then let the scale settle."
        case .tareLatency:
            "Record while testing tare behavior. Start recording, trigger tare on the app or scale, then stop after it settles."
        case .transportStress:
            "Stress Bluetooth transport by moving the phone, changing distance, or adding interference. Useful for gap/jitter testing."
        case .batteryStability:
            "Log battery values over time while the scale runs. This is battery telemetry capture, not a calibrated runtime estimate yet."
        }
    }

    var suggestedDuration: String {
        switch self {
        case .idleStability:
            "Minimum: 60 seconds untouched on a stable surface; the first 5 seconds are discarded."
        case .shot:
            "Minimum: 20 seconds. Tare and settle before Start; stop before removing the vessel."
        case .stepResponse:
            "Minimum: 10 seconds with at least 2 seconds before and after the mass step."
        case .tareLatency:
            "Minimum: 5 seconds around one tare action."
        case .transportStress:
            "Minimum: 120 seconds while intentionally stressing the BLE link."
        case .batteryStability:
            "Minimum: 60 seconds while capturing exposed battery telemetry."
        }
    }
}

enum DeviceClockSemantics: String, Codable {
    case none
    case freeRunning
    case shotTimer
}

enum RecordingSource: String, Codable {
    case bluetooth
    case usbSerial
}

struct ProtocolScoringCapabilities: Codable, Equatable {
    var hasChecksum: Bool
    var hasSequence: Bool
    var sequenceModulus: UInt64?
    var hasDeviceClock: Bool
    var deviceClockSemantics: DeviceClockSemantics
    var deviceClockModulus: UInt64?
}

struct ScaleLinkMetadata: Codable, Equatable {
    var requestedConnectionPriority: String?
    var requestedMtu: Int?
    var negotiatedMtu: Int?

    static let appleManaged = ScaleLinkMetadata(
        requestedConnectionPriority: nil,
        requestedMtu: nil,
        negotiatedMtu: nil
    )
}

enum ScaleRecordingEventType: String, Codable {
    case disconnect
    case reconnect
    case appBackgrounded
    case appForegrounded
}

struct ScaleRecordingEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: ScaleRecordingEventType
    var monotonicSeconds: Double
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
        transportWeight: 1.00,
        stabilityWeight: 0.00,
        metadataWeight: 0.00,
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
        let safeTransportWeight = Self.nonnegativeFinite(transportWeight, fallback: 0)
        let safeStabilityWeight = Self.nonnegativeFinite(stabilityWeight, fallback: 0)
        let safeMetadataWeight = Self.nonnegativeFinite(metadataWeight, fallback: 0)
        let total = safeTransportWeight + safeStabilityWeight + safeMetadataWeight
        guard total > 0, total.isFinite else {
            copy.transportWeight = ScoringProfile.standard.transportWeight
            copy.stabilityWeight = ScoringProfile.standard.stabilityWeight
            copy.metadataWeight = ScoringProfile.standard.metadataWeight
            return copy.sanitizingThresholdsAndPenalties()
        }
        copy.transportWeight = safeTransportWeight / total
        copy.stabilityWeight = safeStabilityWeight / total
        copy.metadataWeight = safeMetadataWeight / total
        return copy.sanitizingThresholdsAndPenalties()
    }

    var isStandardBenchmark: Bool {
        normalized == ScoringProfile.standard.normalized
    }

    private func sanitizingThresholdsAndPenalties() -> ScoringProfile {
        var copy = self
        copy.minimumLongGapMilliseconds = Self.nonnegativeFinite(
            minimumLongGapMilliseconds,
            fallback: ScoringProfile.standard.minimumLongGapMilliseconds
        )
        copy.longGapMultiplier = Self.nonnegativeFinite(
            longGapMultiplier,
            fallback: ScoringProfile.standard.longGapMultiplier
        )
        copy.longGapPenalty = max(0, longGapPenalty)
        copy.missingSequencePenalty = max(0, missingSequencePenalty)
        copy.timestampIssuePenalty = max(0, timestampIssuePenalty)
        copy.rejectedPacketRatePenaltyScale = Self.nonnegativeFinite(
            rejectedPacketRatePenaltyScale,
            fallback: ScoringProfile.standard.rejectedPacketRatePenaltyScale
        )
        copy.idleNoiseFreePeakToPeakGrams = Self.nonnegativeFinite(
            idleNoiseFreePeakToPeakGrams,
            fallback: ScoringProfile.standard.idleNoiseFreePeakToPeakGrams
        )
        copy.idleNoisePeakToPeakPenaltyScale = Self.nonnegativeFinite(
            idleNoisePeakToPeakPenaltyScale,
            fallback: ScoringProfile.standard.idleNoisePeakToPeakPenaltyScale
        )
        copy.idleStandardDeviationFreeGrams = Self.nonnegativeFinite(
            idleStandardDeviationFreeGrams,
            fallback: ScoringProfile.standard.idleStandardDeviationFreeGrams
        )
        copy.idleStandardDeviationPenaltyScale = Self.nonnegativeFinite(
            idleStandardDeviationPenaltyScale,
            fallback: ScoringProfile.standard.idleStandardDeviationPenaltyScale
        )
        copy.driftPenaltyScale = Self.nonnegativeFinite(
            driftPenaltyScale,
            fallback: ScoringProfile.standard.driftPenaltyScale
        )
        return copy
    }

    private static func nonnegativeFinite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? max(0, value) : fallback
    }
}

enum PacketRole: String, Codable {
    case weight
    case capabilities
    case battery
    case commandAck
    case unknown
}

enum PacketFieldSemantic: String, Codable, CaseIterable {
    case header
    case timestamp
    case weight
    case flow
    case battery
    case sequence
    case status
    case quality
    case sampleRate
    case checksum
    case unit
    case payload
}

struct PacketFieldAnnotation: Codable, Equatable, Identifiable {
    var startByte: Int
    var endByteExclusive: Int
    var label: String
    var decodedValue: String
    var semantic: PacketFieldSemantic

    var id: String {
        "\(startByte)-\(endByteExclusive)-\(semantic.rawValue)-\(label)"
    }
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
    var identifier: String
    var kind: ScaleKind
    var advertisedServices: [String]
}

struct USBSerialSampleMetadata: Codable, Equatable {
    var firmwareMillis: UInt32
    var sequenceNumber: UInt32
    var usbStatusRaw: UInt16
    var usbStatusLabels: [String]
    var firmwareQuality: Int
    var hx711Hz: Double
    var usbDroppedCumulative: UInt32
    var usbDroppedDelta: UInt32
    var hostReceivedAt: Date
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
    var weightGrams: Double? = nil
    var sequence: UInt8? = nil
    var deviceTimestampMilliseconds: UInt32? = nil
    var fields: [PacketFieldAnnotation]? = nil
    var usbSerial: USBSerialSampleMetadata? = nil
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
    var usbSerial: USBSerialSampleMetadata? = nil
}

struct ScaleBatteryEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var arrivalTime: Date
    var monotonicSeconds: Double
    var scaleKind: ScaleKind
    var percent: Int
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
    static let schemaVersion = 6
    static let scoringModelVersion = "standard-1.0.0"

    var id: UUID
    var schemaVersion: Int
    var appName: String
    var appVersion: String
    var appBuild: String
    var platform: String
    var scoringModelVersion: String
    var source: RecordingSource
    var protocolName: String?
    var serialBaud: Int?
    var title: String?
    var mode: RecordingMode
    var device: ScaleDeviceIdentity?
    var startedAt: Date
    var endedAt: Date?
    var recordingStartMonotonicSeconds: Double?
    var recordingEndMonotonicSeconds: Double?
    var notes: String
    var rawPackets: [RawScalePacket]
    var samples: [ScaleSample]
    var batteryEvents: [ScaleBatteryEvent]
    var events: [ScaleRecordingEvent]
    var capabilities: WMBPlusCapabilities?
    var protocolCapabilities: ProtocolScoringCapabilities?
    var link: ScaleLinkMetadata
    var scoringProfile: ScoringProfile
    var metrics: ScaleQualityMetrics

    init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.schemaVersion,
        appName: String = "ScaleBench",
        appVersion: String = ScaleRecording.currentAppVersion,
        appBuild: String = ScaleRecording.currentAppBuild,
        platform: String = ScaleRecording.currentPlatform,
        scoringModelVersion: String = Self.scoringModelVersion,
        source: RecordingSource = .bluetooth,
        protocolName: String? = nil,
        serialBaud: Int? = nil,
        title: String? = nil,
        mode: RecordingMode,
        device: ScaleDeviceIdentity? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        recordingStartMonotonicSeconds: Double? = nil,
        recordingEndMonotonicSeconds: Double? = nil,
        notes: String,
        rawPackets: [RawScalePacket],
        samples: [ScaleSample],
        batteryEvents: [ScaleBatteryEvent] = [],
        events: [ScaleRecordingEvent] = [],
        capabilities: WMBPlusCapabilities? = nil,
        protocolCapabilities: ProtocolScoringCapabilities? = nil,
        link: ScaleLinkMetadata = .appleManaged,
        scoringProfile: ScoringProfile,
        metrics: ScaleQualityMetrics
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.platform = platform
        self.scoringModelVersion = scoringModelVersion
        self.source = source
        self.protocolName = protocolName
        self.serialBaud = serialBaud
        self.title = title
        self.mode = mode
        self.device = device
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordingStartMonotonicSeconds = recordingStartMonotonicSeconds
        self.recordingEndMonotonicSeconds = recordingEndMonotonicSeconds
        self.notes = notes
        self.rawPackets = rawPackets
        self.samples = samples
        self.batteryEvents = batteryEvents
        self.events = events
        self.capabilities = capabilities
        self.protocolCapabilities = protocolCapabilities
        self.link = link
        self.scoringProfile = scoringProfile
        self.metrics = metrics
    }

    static func empty(mode: RecordingMode = .shot, scoringProfile: ScoringProfile = .standard) -> ScaleRecording {
        ScaleRecording(
            mode: mode,
            device: nil,
            startedAt: Date(),
            endedAt: nil,
            notes: "",
            rawPackets: [],
            samples: [],
            batteryEvents: [],
            events: [],
            capabilities: nil,
            protocolCapabilities: nil,
            scoringProfile: scoringProfile,
            metrics: .empty
        )
    }

    private static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static var currentPlatform: String {
        #if targetEnvironment(macCatalyst)
        "macos-catalyst"
        #elseif os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case appName
        case appVersion
        case appBuild
        case platform
        case scoringModelVersion
        case source
        case protocolName
        case serialBaud
        case title
        case mode
        case device
        case startedAt
        case endedAt
        case recordingStartMonotonicSeconds
        case recordingEndMonotonicSeconds
        case notes
        case rawPackets
        case samples
        case batteryEvents
        case events
        case capabilities
        case protocolCapabilities
        case link
        case scoringProfile
        case metrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? "ScaleBench"
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        appBuild = try container.decodeIfPresent(String.self, forKey: .appBuild) ?? "unknown"
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "unknown"
        scoringModelVersion = try container.decodeIfPresent(String.self, forKey: .scoringModelVersion) ?? Self.scoringModelVersion
        source = try container.decodeIfPresent(RecordingSource.self, forKey: .source) ?? .bluetooth
        protocolName = try container.decodeIfPresent(String.self, forKey: .protocolName)
        serialBaud = try container.decodeIfPresent(Int.self, forKey: .serialBaud)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        mode = try container.decodeIfPresent(RecordingMode.self, forKey: .mode) ?? .shot
        device = try container.decodeIfPresent(ScaleDeviceIdentity.self, forKey: .device)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        recordingStartMonotonicSeconds = try container.decodeIfPresent(Double.self, forKey: .recordingStartMonotonicSeconds)
        recordingEndMonotonicSeconds = try container.decodeIfPresent(Double.self, forKey: .recordingEndMonotonicSeconds)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        rawPackets = try container.decodeIfPresent([RawScalePacket].self, forKey: .rawPackets) ?? []
        samples = try container.decodeIfPresent([ScaleSample].self, forKey: .samples) ?? []
        batteryEvents = try container.decodeIfPresent([ScaleBatteryEvent].self, forKey: .batteryEvents) ?? []
        events = try container.decodeIfPresent([ScaleRecordingEvent].self, forKey: .events) ?? []
        capabilities = try container.decodeIfPresent(WMBPlusCapabilities.self, forKey: .capabilities)
        protocolCapabilities = try container.decodeIfPresent(ProtocolScoringCapabilities.self, forKey: .protocolCapabilities)
        link = try container.decodeIfPresent(ScaleLinkMetadata.self, forKey: .link) ?? .appleManaged
        scoringProfile = try container.decodeIfPresent(ScoringProfile.self, forKey: .scoringProfile) ?? .standard
        metrics = try container.decodeIfPresent(ScaleQualityMetrics.self, forKey: .metrics) ?? .empty
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
        notes inputNotes: String,
        recalculateMetrics: Bool = true
    ) -> SavedScaleRecording {
        var finalized = inputRecording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? Date()
        finalized.notes = inputNotes
        if recalculateMetrics {
            finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)
        }

        let title = firstNonEmpty(inputTitle, finalized.title) ?? defaultTitle(for: finalized)
        finalized.title = title

        return SavedScaleRecording(
            id: finalized.id,
            savedAt: Date(),
            title: title,
            notes: inputNotes,
            recording: finalized,
            scoreSnapshot: finalized.metrics
        )
    }

    private static func defaultTitle(for recording: ScaleRecording) -> String {
        let protocolName = recording.protocolName
            ?? recording.device?.kind.displayName
            ?? recording.samples.last?.scaleKind.displayName
            ?? "Unknown Scale"
        return "\(protocolName) · \(recording.mode.displayName)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }
}

struct ProtocolComparisonRow: Identifiable, Equatable {
    var id: UUID
    var title: String
    var protocolKind: ScaleKind
    var mode: RecordingMode
    var platform: String
    var score: Int?
    var verificationCoveragePercent: Int?
    var purityIsUpperBound: Bool
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
        rows.filter { !$0.purityIsUpperBound }.max { lhs, rhs in
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
                platform: saved.recording.platform,
                score: saved.scoreSnapshot.overallScore,
                verificationCoveragePercent: saved.scoreSnapshot.protocolVerification?.verificationCoveragePercent,
                purityIsUpperBound: saved.scoreSnapshot.delivery?.purityIsUpperBound == true,
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

struct TransportComparisonPoint: Equatable {
    var seconds: Double
    var weightGrams: Double
}

struct TransportComparisonRow: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var isOfficial: Bool
    var packetCount: Int
    var rateHz: Double?
    var medianIntervalMilliseconds: Double?
    var p95IntervalMilliseconds: Double?
    var maxGapMilliseconds: Double?
    var matchedReferenceCount: Int?
    var medianLagMilliseconds: Double?
    var medianAbsoluteDeltaGrams: Double?
}

struct TransportComparison: Equatable {
    var rows: [TransportComparisonRow]

    var isVisible: Bool { rows.count > 1 }

    static func make(recording: ScaleRecording) -> TransportComparison {
        let streams = transportStreams(recording: recording)
        guard streams.count > 1 else {
            return TransportComparison(rows: [])
        }

        let referenceKey = streams
            .filter { $0.key.isOfficial }
            .max { $0.value.count < $1.value.count }?
            .key ?? streams.max { $0.value.count < $1.value.count }!.key
        let referencePoints = streams[referenceKey] ?? []
        let start = recording.recordingStartMonotonicSeconds
            ?? streams.values.flatMap { $0.map(\.seconds) }.min()
            ?? 0
        let end = recording.recordingEndMonotonicSeconds
            ?? streams.values.flatMap { $0.map(\.seconds) }.max()
            ?? start
        let duration = max(0, end - start)

        let rows = streams
            .map { key, points in
                makeRow(
                    key: key,
                    points: points.sorted { $0.seconds < $1.seconds },
                    referencePoints: referencePoints.sorted { $0.seconds < $1.seconds },
                    durationSeconds: duration,
                    isReference: key == referenceKey
                )
            }
            .sorted { lhs, rhs in
                if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial && !rhs.isOfficial }
                if lhs.packetCount != rhs.packetCount { return lhs.packetCount > rhs.packetCount }
                return lhs.title < rhs.title
            }

        return TransportComparison(rows: rows)
    }

    private static func makeRow(
        key: TransportStreamKey,
        points: [TransportComparisonPoint],
        referencePoints: [TransportComparisonPoint],
        durationSeconds: Double,
        isReference: Bool
    ) -> TransportComparisonRow {
        let intervals = zip(points, points.dropFirst()).map { max(0, $1.seconds - $0.seconds) * 1_000 }
        let alignment = isReference ? nil : compare(points: points, referencePoints: referencePoints)
        return TransportComparisonRow(
            id: key.id,
            title: key.title,
            detail: key.detail,
            isOfficial: key.isOfficial,
            packetCount: points.count,
            rateHz: durationSeconds > 0 ? Double(points.count) / durationSeconds : nil,
            medianIntervalMilliseconds: percentile(intervals, 0.50),
            p95IntervalMilliseconds: percentile(intervals, 0.95),
            maxGapMilliseconds: intervals.max(),
            matchedReferenceCount: alignment?.matchedCount,
            medianLagMilliseconds: alignment?.medianLagMilliseconds,
            medianAbsoluteDeltaGrams: alignment?.medianAbsoluteDeltaGrams
        )
    }

    private static func transportStreams(recording: ScaleRecording) -> [TransportStreamKey: [TransportComparisonPoint]] {
        recording.rawPackets.reduce(into: [:]) { result, packet in
            guard let decoded = decodeTransportPoint(packet: packet, recording: recording) else { return }
            result[decoded.key, default: []].append(decoded.point)
        }
    }

    private static func decodeTransportPoint(
        packet: RawScalePacket,
        recording: ScaleRecording
    ) -> (key: TransportStreamKey, point: TransportComparisonPoint)? {
        guard packet.rejectionReason == nil else { return nil }
        let uuid = packet.characteristicUUID.uppercased()
        let bytes = bytes(fromHex: packet.bytesHex)

        if uuid == WeighMyBruParser.weight20UUID, bytes.count == 20 {
            let extended = recording.device?.kind == .weighMyBruPlus || packet.scaleKind == .weighMyBruPlus || bytes[5] == 0x01
            let key = TransportStreamKey(
                id: "wmb-20-byte",
                title: extended ? "WMB+ 20-byte" : "WMB 20-byte",
                detail: "Official benchmark stream",
                isOfficial: true
            )
            return (key, TransportComparisonPoint(
                seconds: packet.monotonicSeconds,
                weightGrams: signedCentiValue(signByte: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
            ))
        }

        if uuid == WeighMyBruParser.float32UUID, bytes.count == 4 {
            let bitPattern = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            let value = Float(bitPattern: bitPattern)
            guard value.isFinite else { return nil }
            let key = TransportStreamKey(
                id: "bean-conqueror-float32",
                title: "Bean Conqueror Float32",
                detail: "Compatibility stream; not used for official scoring when 20-byte data is present",
                isOfficial: false
            )
            return (key, TransportComparisonPoint(seconds: packet.monotonicSeconds, weightGrams: Double(value)))
        }

        if isBookooWeightPacket(packet: packet, uuid: uuid, bytes: bytes) {
            let kind = normalizedBookooKind(packet.scaleKind == .unknown ? (recording.device?.kind ?? .bookoo) : packet.scaleKind)
            let key = TransportStreamKey(
                id: "bookoo-\(kind.rawValue)-\(shortUUID(uuid))",
                title: "\(kind.displayName) 20-byte",
                detail: "Native BooKoo benchmark stream",
                isOfficial: true
            )
            return (key, TransportComparisonPoint(
                seconds: packet.monotonicSeconds,
                weightGrams: signedCentiValue(signByte: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
            ))
        }

        return nil
    }

    private static func compare(
        points: [TransportComparisonPoint],
        referencePoints: [TransportComparisonPoint]
    ) -> (matchedCount: Int, medianLagMilliseconds: Double?, medianAbsoluteDeltaGrams: Double?) {
        guard !points.isEmpty, !referencePoints.isEmpty else {
            return (0, nil, nil)
        }
        var referenceIndex = 0
        var lags: [Double] = []
        var deltas: [Double] = []
        for point in points {
            while referenceIndex + 1 < referencePoints.count,
                  abs(referencePoints[referenceIndex + 1].seconds - point.seconds) < abs(referencePoints[referenceIndex].seconds - point.seconds) {
                referenceIndex += 1
            }
            let reference = referencePoints[referenceIndex]
            let lag = point.seconds - reference.seconds
            guard abs(lag) <= 0.080 else { continue }
            lags.append(lag * 1_000)
            deltas.append(abs(point.weightGrams - reference.weightGrams))
        }
        return (lags.count, percentile(lags, 0.50), percentile(deltas, 0.50))
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        let cleaned = hex.filter(\.isHexDigit)
        guard cleaned.count.isMultiple(of: 2) else { return [] }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            if let byte = UInt8(cleaned[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }

    private static func isBookooWeightPacket(packet: RawScalePacket, uuid: String, bytes: [UInt8]) -> Bool {
        guard bytes.count == 20, bytes[0] == 0x03, bytes[1] == 0x0B else { return false }
        if uuid == BookooParser.notifyUUID { return true }
        switch packet.scaleKind {
        case .bookoo, .bookooMini, .bookooUltra:
            return true
        default:
            return false
        }
    }

    private static func normalizedBookooKind(_ kind: ScaleKind) -> ScaleKind {
        switch kind {
        case .bookooMini, .bookooUltra:
            return kind
        default:
            return .bookoo
        }
    }

    private static func shortUUID(_ uuid: String) -> String {
        let suffix = "-0000-1000-8000-00805F9B34FB"
        if uuid.hasPrefix("0000"), uuid.hasSuffix(suffix), uuid.count >= 8 {
            return String(uuid.dropFirst(4).prefix(4))
        }
        return uuid
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = max(0, min(1, percentile))
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

private struct TransportStreamKey: Hashable {
    var id: String
    var title: String
    var detail: String
    var isOfficial: Bool
}

struct ScoringValidity: Codable, Equatable {
    var isValid: Bool
    var reasons: [String]
}

struct DeliveryQualityMetrics: Codable, Equatable {
    var applicable: Bool
    var deliveryScore: Int?
    var coverage: Double?
    var purity: Double?
    var purityIsUpperBound: Bool?
}

struct FrameClassificationMetrics: Codable, Equatable {
    var usable: Int
    var parseFailure: Int
    var outOfOrder: Int
    var stale: Int
    var duplicate: Int
    var implausible: Int
}

struct ProtocolVerificationMetrics: Codable, Equatable {
    var verifiableClasses: [String]
    var unverifiableClasses: [String]
    var verificationCoveragePercent: Int
    var purityIsUpperBound: Bool
}

struct StepResponseMetrics: Codable, Equatable {
    var stepDetected: Bool
    var onsetSecondsFromRecordingStart: Double?
    var baselineGrams: Double?
    var finalGrams: Double?
    var amplitudeGrams: Double?
    var riseTime10To90Seconds: Double?
    var settlingTimeSeconds: Double?
    var overshootPercent: Double?
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
    var scoringModelVersion: String? = nil
    var scoringProfileName: String? = nil
    var validity: ScoringValidity? = nil
    var delivery: DeliveryQualityMetrics? = nil
    var frameClassification: FrameClassificationMetrics? = nil
    var protocolVerification: ProtocolVerificationMetrics? = nil
    var signalUnreconstructable: Bool? = nil
    var relevantWeightFrameCount: Int? = nil
    var excludedFrameCount: Int? = nil
    var usableSampleCount: Int? = nil
    var recordingSpanSeconds: Double? = nil
    var recordingBoundaryInferred: Bool? = nil
    var frameRateHz: Double? = nil
    var usableRateHz: Double? = nil
    var estimatedResolutionGrams: Double? = nil
    var slotCount: Int? = nil
    var servedSlots: Int? = nil
    var longestUnservedRunMilliseconds: Double? = nil
    var robustCoefficientOfVariation: Double? = nil
    var disconnectCount: Int? = nil
    var idleNoiseScore: Int? = nil
    var idleDriftScore: Int? = nil
    var idleAnalysedSampleCount: Int? = nil
    var idleResolutionGrams: Double? = nil
    var stepResponse: StepResponseMetrics? = nil

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
