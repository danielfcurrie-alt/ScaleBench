import Foundation

enum BookooParser {
    static let serviceUUID = "0FFE"
    static let notifyUUID = "FF11"
    static let writeUUID = "FF12"
    static let tareAndStartCommand: [UInt8] = [0x03, 0x0A, 0x07, 0x00, 0x00, 0x00]
    static let disableFlowSmoothingCommand: [UInt8] = command(0x08, data1: 0x00, data2: 0x00)
    static let cupRemovalStopCommand: [UInt8] = command(0x0B, data1: 0x01, data2: 0x00)

    static func identifyKind(name: String?) -> ScaleKind {
        let lower = (name ?? "").lowercased()
        if lower.contains("ultra") { return .bookooUltra }
        if lower.contains("mini") { return .bookooMini }
        return .bookoo
    }

    static func command(_ command: UInt8, data1: UInt8, data2: UInt8) -> [UInt8] {
        let checksum = UInt8(0x03) ^ UInt8(0x0A) ^ command ^ data1 ^ data2
        return [0x03, 0x0A, command, data1, data2, checksum]
    }

    static func parseWeightPacket(
        _ data: Data,
        kind: ScaleKind = .bookoo,
        arrivalTime: Date,
        monotonicSeconds: Double
    ) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count == 20 else { return .failure(.invalidLength) }
        guard bytes[0] == 0x03 else { return .failure(.invalidProduct) }
        guard bytes[1] == 0x0B else { return .failure(.invalidMessageType) }
        guard xorChecksum(bytes.dropLast()) == bytes[19] else { return .failure(.invalidChecksum) }

        let timestamp = uint24(bytes[2], bytes[3], bytes[4])
        let weight = signedCentiValue(signByte: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
        let flow = signedCentiValue(signByte: bytes[10], high: 0, mid: bytes[11], low: bytes[12])
        let battery = Int(bytes[13])

        let diagnostic = diagnosticFlags(from: bytes, kind: kind)

        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: normalizedBookooKind(kind),
            weightGrams: weight,
            deviceTimestampMilliseconds: timestamp,
            sequence: nil,
            batteryPercent: battery <= 100 ? battery : nil,
            flowGramsPerSecond: flow.isFinite && abs(flow) < 50 ? flow : nil,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: diagnostic
        ))
    }

    private static func normalizedBookooKind(_ kind: ScaleKind) -> ScaleKind {
        switch kind {
        case .bookooMini, .bookooUltra: kind
        default: .bookoo
        }
    }

    private static func diagnosticFlags(from bytes: [UInt8], kind: ScaleKind) -> ScaleDiagnosticFlags {
        var flags: UInt8 = 0
        flags |= 0x40 // flow present
        if kind == .bookooMini || kind == .bookooUltra { flags |= 0x80 }
        if bytes[17] <= 1 { flags |= 0x04 } // smoothing-state byte has a sane value; useful native-packet sanity flag
        return ScaleDiagnosticFlags(byte: flags)
    }
}
