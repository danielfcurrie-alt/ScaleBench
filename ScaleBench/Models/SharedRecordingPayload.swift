import Foundation
import zlib

enum SharedRecordingCodec {
    enum EncodingStyle {
        case exported
        case storage
    }

    static func exportData(
        from recording: ScaleRecording,
        recalculateMetrics: Bool = true,
        style: EncodingStyle = .exported
    ) throws -> Data {
        let payload = SharedRecordingPayload(
            recording: recording,
            recalculateMetrics: recalculateMetrics,
            includeFieldAnnotations: style == .exported
        )
        let encoder = JSONEncoder()
        switch style {
        case .exported:
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        case .storage:
            encoder.outputFormatting = []
        }
        return try encoder.encode(payload)
    }

    static func storageData(from recording: ScaleRecording, recalculateMetrics: Bool = false) throws -> Data {
        let data = try exportData(
            from: recording,
            recalculateMetrics: recalculateMetrics,
            style: .storage
        )
        return try RecordingStorageCompression.compress(data)
    }

    static func decodeRecording(from data: Data) throws -> ScaleRecording {
        guard !data.isEmpty else {
            throw sharedRecordingCompressionError("The selected recording file is empty.")
        }
        let decoder = JSONDecoder()
        let decodedData: Data
        if data.startsWithJSONPayload {
            decodedData = data
        } else if data.startsWithGzipHeader {
            decodedData = try GzipRecordingCompression.decompress(data)
        } else {
            decodedData = try RecordingStorageCompression.decompress(data)
        }
        return try decoder.decode(SharedRecordingPayload.self, from: decodedData).recording()
    }

    static func gzipExportData(from recording: ScaleRecording, recalculateMetrics: Bool = true) throws -> Data {
        try GzipRecordingCompression.compress(
            exportData(from: recording, recalculateMetrics: recalculateMetrics, style: .exported)
        )
    }
}

private enum RecordingStorageCompression {
    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }
}

private enum GzipRecordingCompression {
    private static let chunkSize = 16 * 1024

    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let result = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard result == Z_OK else {
            throw sharedRecordingCompressionError("Could not start gzip compression.")
        }
        defer { deflateEnd(&stream) }

        var compressed = Data()
        try data.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw sharedRecordingCompressionError("Could not read recording data.")
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = [Bytef](repeating: 0, count: chunkSize)
            var status: Int32 = Z_OK
            repeat {
                status = output.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return deflate(&stream, stream.avail_in == 0 ? Z_FINISH : Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw sharedRecordingCompressionError("Could not gzip recording data.")
                }
                compressed.append(output, count: output.count - Int(stream.avail_out))
            } while status != Z_STREAM_END
        }

        return compressed
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let result = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard result == Z_OK else {
            throw sharedRecordingCompressionError("Could not start gzip decompression.")
        }
        defer { inflateEnd(&stream) }

        var decompressed = Data()
        try data.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw sharedRecordingCompressionError("Could not read compressed recording data.")
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = [Bytef](repeating: 0, count: chunkSize)
            while true {
                let status = output.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                if status == Z_STREAM_END {
                    decompressed.append(output, count: output.count - Int(stream.avail_out))
                    break
                }
                guard status == Z_OK else {
                    throw sharedRecordingCompressionError("Could not read gzip recording data.")
                }
                decompressed.append(output, count: output.count - Int(stream.avail_out))
            }
        }

        return decompressed
    }
}

private struct SharedRecordingCodecError: LocalizedError {
    let errorDescription: String?
}

private func sharedRecordingCompressionError(_ description: String) -> Error {
    SharedRecordingCodecError(errorDescription: description)
}

private extension Data {
    var startsWithJSONPayload: Bool {
        guard let first = firstNonWhitespaceByte else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    var startsWithGzipHeader: Bool {
        guard count >= 2 else { return false }
        return self[startIndex] == 0x1F && self[index(after: startIndex)] == 0x8B
    }

    var firstNonWhitespaceByte: UInt8? {
        first { byte in
            byte != UInt8(ascii: " ")
                && byte != UInt8(ascii: "\n")
                && byte != UInt8(ascii: "\r")
                && byte != UInt8(ascii: "\t")
        }
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
    var source: String?
    var `protocol`: String?
    var serialBaud: Int?
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

    init(recording: ScaleRecording, recalculateMetrics: Bool, includeFieldAnnotations: Bool) {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        if recalculateMetrics {
            finalized.metrics = ScaleQualityAnalyzer.analyze(finalized, profile: finalized.scoringProfile)
        }

        schemaVersion = finalized.schemaVersion
        id = finalized.id.uuidString
        appName = finalized.appName
        appVersion = finalized.appVersion
        appBuild = finalized.appBuild
        platform = finalized.platform
        scoringModelVersion = finalized.scoringModelVersion
        source = finalized.source == .usbSerial ? finalized.source.rawValue : nil
        `protocol` = finalized.source == .usbSerial ? finalized.protocolName : nil
        serialBaud = finalized.source == .usbSerial ? finalized.serialBaud : nil
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
        rawPackets = finalized.rawPackets.map {
            SharedRawPacketPayload(packet: $0, includeFieldAnnotations: includeFieldAnnotations)
        }
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
        let recordingSource: RecordingSource
        if let source {
            guard let parsedSource = RecordingSource(rawValue: source) else {
                throw sharedRecordingError("Unknown recording source \(source).")
            }
            recordingSource = parsedSource
        } else {
            recordingSource = .bluetooth
        }
        if recordingSource == .usbSerial {
            guard `protocol` == WMBPlusUSBSerialRow.protocolName else {
                throw sharedRecordingError("USB recording protocol must be \(WMBPlusUSBSerialRow.protocolName).")
            }
            guard serialBaud == WMBPlusUSBSerialRow.baud else {
                throw sharedRecordingError("WMB+ USB Serial recordings must use 115200 baud.")
            }
        } else if `protocol` != nil || serialBaud != nil {
            throw sharedRecordingError("Serial metadata requires source usbSerial.")
        }
        return ScaleRecording(
            id: recordingID,
            schemaVersion: schemaVersion,
            appName: appName,
            appVersion: appVersion,
            appBuild: appBuild,
            platform: platform,
            scoringModelVersion: scoringModelVersion,
            source: recordingSource,
            protocolName: `protocol`,
            serialBaud: serialBaud,
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
    var firmwareMillis: UInt32?
    var sequenceNumber: UInt32?
    var usbStatusRaw: UInt16?
    var usbStatusLabels: [String]?
    var firmwareQuality: Int?
    var hx711Hz: Double?
    var usbDroppedCumulative: UInt32?
    var usbDroppedDelta: UInt32?
    var hostReceivedAt: Int64?

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
        firmwareMillis = sample.usbSerial?.firmwareMillis
        sequenceNumber = sample.usbSerial?.sequenceNumber
        usbStatusRaw = sample.usbSerial?.usbStatusRaw
        usbStatusLabels = sample.usbSerial?.usbStatusLabels
        firmwareQuality = sample.usbSerial?.firmwareQuality
        hx711Hz = sample.usbSerial?.hx711Hz
        usbDroppedCumulative = sample.usbSerial?.usbDroppedCumulative
        usbDroppedDelta = sample.usbSerial?.usbDroppedDelta
        hostReceivedAt = sample.usbSerial.map { milliseconds($0.hostReceivedAt) }
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
            diagnosticFlags: diagnosticFlags,
            usbSerial: try usbMetadata()
        )
    }

    private func usbMetadata() throws -> USBSerialSampleMetadata? {
        let valuesPresent = firmwareMillis != nil || sequenceNumber != nil || usbStatusRaw != nil
            || usbStatusLabels != nil || firmwareQuality != nil || hx711Hz != nil
            || usbDroppedCumulative != nil || usbDroppedDelta != nil || hostReceivedAt != nil
        guard valuesPresent else { return nil }
        guard let firmwareMillis, let sequenceNumber, let usbStatusRaw, let usbStatusLabels,
              let firmwareQuality, let hx711Hz, let usbDroppedCumulative, let usbDroppedDelta,
              let hostReceivedAt else {
            throw sharedRecordingError("USB sample metadata is incomplete.")
        }
        guard (0...100).contains(firmwareQuality), hx711Hz.isFinite, hx711Hz >= 0 else {
            throw sharedRecordingError("USB sample metadata is invalid.")
        }
        return USBSerialSampleMetadata(
            firmwareMillis: firmwareMillis,
            sequenceNumber: sequenceNumber,
            usbStatusRaw: usbStatusRaw,
            usbStatusLabels: usbStatusLabels,
            firmwareQuality: firmwareQuality,
            hx711Hz: hx711Hz,
            usbDroppedCumulative: usbDroppedCumulative,
            usbDroppedDelta: usbDroppedDelta,
            hostReceivedAt: date(hostReceivedAt)
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
    var firmwareMillis: UInt32?
    var sequenceNumber: UInt32?
    var usbStatusRaw: UInt16?
    var usbStatusLabels: [String]?
    var firmwareQuality: Int?
    var hx711Hz: Double?
    var usbDroppedCumulative: UInt32?
    var usbDroppedDelta: UInt32?
    var hostReceivedAt: Int64?

    init(packet: RawScalePacket, includeFieldAnnotations: Bool = true) {
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
        fields = includeFieldAnnotations ? PacketFieldDecoder.annotations(for: packet) : nil
        firmwareMillis = packet.usbSerial?.firmwareMillis
        sequenceNumber = packet.usbSerial?.sequenceNumber
        usbStatusRaw = packet.usbSerial?.usbStatusRaw
        usbStatusLabels = packet.usbSerial?.usbStatusLabels
        firmwareQuality = packet.usbSerial?.firmwareQuality
        hx711Hz = packet.usbSerial?.hx711Hz
        usbDroppedCumulative = packet.usbSerial?.usbDroppedCumulative
        usbDroppedDelta = packet.usbSerial?.usbDroppedDelta
        hostReceivedAt = packet.usbSerial.map { milliseconds($0.hostReceivedAt) }
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
            fields: fields,
            usbSerial: try usbMetadata()
        )
    }

    private func usbMetadata() throws -> USBSerialSampleMetadata? {
        let valuesPresent = firmwareMillis != nil || sequenceNumber != nil || usbStatusRaw != nil
            || usbStatusLabels != nil || firmwareQuality != nil || hx711Hz != nil
            || usbDroppedCumulative != nil || usbDroppedDelta != nil || hostReceivedAt != nil
        guard valuesPresent else { return nil }
        guard let firmwareMillis, let sequenceNumber, let usbStatusRaw, let usbStatusLabels,
              let firmwareQuality, let hx711Hz, let usbDroppedCumulative, let usbDroppedDelta,
              let hostReceivedAt else {
            throw sharedRecordingError("USB packet metadata is incomplete.")
        }
        guard (0...100).contains(firmwareQuality), hx711Hz.isFinite, hx711Hz >= 0 else {
            throw sharedRecordingError("USB packet metadata is invalid.")
        }
        return USBSerialSampleMetadata(
            firmwareMillis: firmwareMillis,
            sequenceNumber: sequenceNumber,
            usbStatusRaw: usbStatusRaw,
            usbStatusLabels: usbStatusLabels,
            firmwareQuality: firmwareQuality,
            hx711Hz: hx711Hz,
            usbDroppedCumulative: usbDroppedCumulative,
            usbDroppedDelta: usbDroppedDelta,
            hostReceivedAt: date(hostReceivedAt)
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
