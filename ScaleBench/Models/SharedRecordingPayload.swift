import Foundation

enum SharedRecordingCodec {
    static func exportData(from recording: ScaleRecording) throws -> Data {
        let payload = SharedRecordingPayload(recording: recording)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func decodeRecording(from data: Data) throws -> ScaleRecording {
        let decoder = JSONDecoder()
        return try decoder.decode(SharedRecordingPayload.self, from: data).recording()
    }
}

private struct SharedRecordingPayload: Codable {
    var id: String
    var schemaVersion: Int
    var appName: String
    var appVersion: String
    var appBuild: String
    var platform: String
    var scoringModelVersion: String
    var title: String?
    var mode: String
    var startedAtMillis: Int64
    var endedAtMillis: Int64?
    var recordingStartMonotonicSeconds: Double?
    var recordingEndMonotonicSeconds: Double?
    var notes: String
    var scoringProfile: SharedScoringProfilePayload
    var device: SharedDevicePayload?
    var protocolCapabilities: ProtocolScoringCapabilities?
    var link: ScaleLinkMetadata
    var metrics: ScaleQualityMetrics
    var samples: [SharedSamplePayload]
    var batteryEvents: [SharedBatteryEventPayload]
    var events: [SharedRecordingEventPayload]
    var rawPackets: [SharedRawPacketPayload]

    init(recording: ScaleRecording) {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized, profile: finalized.scoringProfile)

        schemaVersion = finalized.schemaVersion
        id = finalized.id.uuidString
        appName = finalized.appName
        appVersion = finalized.appVersion
        appBuild = finalized.appBuild
        platform = finalized.platform
        scoringModelVersion = finalized.scoringModelVersion
        title = finalized.title
        mode = finalized.mode.rawValue
        startedAtMillis = milliseconds(finalized.startedAt)
        endedAtMillis = finalized.endedAt.map(milliseconds)
        recordingStartMonotonicSeconds = finalized.recordingStartMonotonicSeconds
        recordingEndMonotonicSeconds = finalized.recordingEndMonotonicSeconds
        notes = finalized.notes
        scoringProfile = SharedScoringProfilePayload(name: finalized.scoringProfile.name)
        device = finalized.device.map(SharedDevicePayload.init)
        protocolCapabilities = finalized.protocolCapabilities
        link = finalized.link
        metrics = finalized.metrics
        samples = finalized.samples.map(SharedSamplePayload.init)
        batteryEvents = finalized.batteryEvents.map(SharedBatteryEventPayload.init)
        events = finalized.events.map(SharedRecordingEventPayload.init)
        rawPackets = finalized.rawPackets.map(SharedRawPacketPayload.init)
    }

    func recording() throws -> ScaleRecording {
        guard schemaVersion == ScaleRecording.schemaVersion else {
            throw sharedRecordingError(
                "Unsupported recording schema version \(schemaVersion); expected \(ScaleRecording.schemaVersion)."
            )
        }
        guard scoringModelVersion == ScaleRecording.scoringModelVersion else {
            throw sharedRecordingError(
                "Unsupported scoring model \(scoringModelVersion); expected \(ScaleRecording.scoringModelVersion)."
            )
        }
        guard let modeValue = RecordingMode(rawValue: mode) else {
            throw sharedRecordingError("Unknown recording mode \(mode).")
        }
        guard scoringProfile.name == ScoringProfile.standardBenchmarkName else {
            throw sharedRecordingError("Unsupported scoring profile \(scoringProfile.name).")
        }
        if let start = recordingStartMonotonicSeconds,
           let end = recordingEndMonotonicSeconds,
           end < start {
            throw sharedRecordingError("Recording end must not precede recording start.")
        }
        guard let recordingID = UUID(uuidString: id) else {
            throw sharedRecordingError("Shared recording id must be a valid UUID.")
        }
        return ScaleRecording(
            id: recordingID,
            schemaVersion: schemaVersion,
            appName: appName,
            appVersion: appVersion,
            appBuild: appBuild,
            platform: platform,
            scoringModelVersion: scoringModelVersion,
            title: title,
            mode: modeValue,
            device: try device?.device(),
            startedAt: date(startedAtMillis),
            endedAt: endedAtMillis.map(date),
            recordingStartMonotonicSeconds: recordingStartMonotonicSeconds,
            recordingEndMonotonicSeconds: recordingEndMonotonicSeconds,
            notes: notes,
            rawPackets: try rawPackets.map { try $0.packet() },
            samples: try samples.map { try $0.sample() },
            batteryEvents: try batteryEvents.map { try $0.event() },
            events: events.map(\.event),
            protocolCapabilities: protocolCapabilities,
            link: link,
            scoringProfile: .standard,
            metrics: metrics
        )
    }
}

private struct SharedScoringProfilePayload: Codable {
    var name: String
}

private struct SharedDevicePayload: Codable {
    var name: String
    var identifier: String
    var kind: String
    var advertisedServices: [String]

    init(device: ScaleDeviceIdentity) {
        name = device.name
        identifier = device.identifier
        kind = device.kind.rawValue
        advertisedServices = device.advertisedServices
    }

    func device() throws -> ScaleDeviceIdentity {
        ScaleDeviceIdentity(
            name: name,
            identifier: identifier,
            kind: try parseSharedScaleKind(kind),
            advertisedServices: advertisedServices
        )
    }
}

private struct SharedSamplePayload: Codable {
    var arrivalTimeMillis: Int64
    var monotonicSeconds: Double
    var scaleKind: String
    var weightGrams: Double
    var deviceTimestampMilliseconds: UInt32?
    var sequence: UInt8?
    var batteryPercent: Int?
    var flowGramsPerSecond: Double?
    var firmwareQualityScore: Int?
    var detectedSampleRateHz: Int?
    var statusFlags: ScaleStatusFlags?
    var diagnosticFlags: ScaleDiagnosticFlags?

    init(sample: ScaleSample) {
        arrivalTimeMillis = milliseconds(sample.arrivalTime)
        monotonicSeconds = sample.monotonicSeconds
        scaleKind = sample.scaleKind.rawValue
        weightGrams = sample.weightGrams
        deviceTimestampMilliseconds = sample.deviceTimestampMilliseconds
        sequence = sample.sequence
        batteryPercent = sample.batteryPercent
        flowGramsPerSecond = sample.flowGramsPerSecond
        firmwareQualityScore = sample.firmwareQualityScore
        detectedSampleRateHz = sample.detectedSampleRateHz
        statusFlags = sample.statusFlags
        diagnosticFlags = sample.diagnosticFlags
    }

    func sample() throws -> ScaleSample {
        if let batteryPercent, !(0...100).contains(batteryPercent) {
            throw sharedRecordingError("Sample battery percent must be between 0 and 100.")
        }
        return ScaleSample(
            arrivalTime: date(arrivalTimeMillis),
            monotonicSeconds: monotonicSeconds,
            scaleKind: try parseSharedScaleKind(scaleKind),
            weightGrams: weightGrams,
            deviceTimestampMilliseconds: deviceTimestampMilliseconds,
            sequence: sequence,
            batteryPercent: batteryPercent,
            flowGramsPerSecond: flowGramsPerSecond,
            firmwareQualityScore: firmwareQualityScore,
            detectedSampleRateHz: detectedSampleRateHz,
            statusFlags: statusFlags,
            diagnosticFlags: diagnosticFlags
        )
    }
}

private struct SharedBatteryEventPayload: Codable {
    var arrivalTimeMillis: Int64
    var monotonicSeconds: Double
    var scaleKind: String
    var percent: Int

    init(event: ScaleBatteryEvent) {
        arrivalTimeMillis = milliseconds(event.arrivalTime)
        monotonicSeconds = event.monotonicSeconds
        scaleKind = event.scaleKind.rawValue
        percent = event.percent
    }

    func event() throws -> ScaleBatteryEvent {
        guard (0...100).contains(percent) else {
            throw sharedRecordingError("Battery event percent must be between 0 and 100.")
        }
        return ScaleBatteryEvent(
            arrivalTime: date(arrivalTimeMillis),
            monotonicSeconds: monotonicSeconds,
            scaleKind: try parseSharedScaleKind(scaleKind),
            percent: percent
        )
    }
}

private struct SharedRecordingEventPayload: Codable {
    var type: ScaleRecordingEventType
    var monotonicSeconds: Double

    init(event: ScaleRecordingEvent) {
        type = event.type
        monotonicSeconds = event.monotonicSeconds
    }

    var event: ScaleRecordingEvent {
        ScaleRecordingEvent(type: type, monotonicSeconds: monotonicSeconds)
    }
}

private struct SharedRawPacketPayload: Codable {
    var arrivalTimeMillis: Int64
    var monotonicSeconds: Double
    var scaleKind: String
    var characteristicUUID: String
    var role: PacketRole
    var bytesHex: String
    var rejectionReason: ParseRejectionReason?
    var weightGrams: Double?
    var sequence: UInt8?
    var deviceTimestampMilliseconds: UInt32?
    var fields: [PacketFieldAnnotation]?

    init(packet: RawScalePacket) {
        arrivalTimeMillis = milliseconds(packet.arrivalTime)
        monotonicSeconds = packet.monotonicSeconds
        scaleKind = packet.scaleKind.rawValue
        characteristicUUID = packet.characteristicUUID
        role = packet.role
        bytesHex = PacketFieldDecoder.normalizedHex(packet.bytesHex)
        rejectionReason = packet.rejectionReason
        weightGrams = packet.weightGrams
        sequence = packet.sequence
        deviceTimestampMilliseconds = packet.deviceTimestampMilliseconds
        fields = PacketFieldDecoder.annotations(for: packet)
    }

    func packet() throws -> RawScalePacket {
        guard bytesHex.range(
            of: #"^([0-9A-F]{2}( [0-9A-F]{2})*)?$"#,
            options: .regularExpression
        ) != nil else {
            throw sharedRecordingError("Packet bytesHex must use uppercase, space-separated bytes.")
        }
        return RawScalePacket(
            arrivalTime: date(arrivalTimeMillis),
            monotonicSeconds: monotonicSeconds,
            scaleKind: try parseSharedScaleKind(scaleKind),
            characteristicUUID: characteristicUUID,
            role: role,
            bytesHex: bytesHex,
            rejectionReason: rejectionReason,
            weightGrams: weightGrams,
            sequence: sequence,
            deviceTimestampMilliseconds: deviceTimestampMilliseconds,
            fields: fields
        )
    }
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
}

private func parseSharedScaleKind(_ value: String) throws -> ScaleKind {
    if let kind = ScaleKind(rawValue: value) {
        return kind
    }
    throw sharedRecordingError("Unknown scale kind \(value).")
}

private func sharedRecordingError(_ description: String) -> DecodingError {
    DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: [], debugDescription: description)
    )
}
