import Foundation

enum BookooParser {
    static let serviceUUID = "0FFE"
    static let notifyUUID = "FF11"
    static let writeUUID = "FF12"
    static let tareAndStartCommand: [UInt8] = [0x03, 0x0A, 0x07, 0x00, 0x00, 0x00]

    static func parseWeightPacket(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count == 20 else { return .failure(.invalidLength) }

        let timestamp = uint24(bytes[2], bytes[3], bytes[4])
        let weight = signedCentiValue(signByte: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
        let flow = signedCentiValue(signByte: bytes[10], high: 0, mid: bytes[11], low: bytes[12])
        let battery = Int(bytes[13])

        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .bookoo,
            weightGrams: weight,
            deviceTimestampMilliseconds: timestamp,
            sequence: nil,
            batteryPercent: battery <= 100 ? battery : nil,
            flowGramsPerSecond: flow,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: nil
        ))
    }
}

