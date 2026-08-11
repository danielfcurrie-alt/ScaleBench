import Foundation

// WeighMyBru/WMB+ compatibility adapter.
//
// UUIDs, command bytes, packet lengths, checksum bytes, and field offsets are
// interoperability facts needed to talk to WMB-compatible firmware. The parser
// itself is a ScaleBench-native Swift implementation that records raw packets
// and maps accepted frames into the app's canonical ScaleSample model.
enum WeighMyBruParser {
    static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let weight20UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let commandUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    static let float32UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"
    static let capabilitiesUUID = "6E400005-B5A3-F393-E0A9-E50E24DCCA9E"
    static let batteryServiceUUID = "180F"
    static let batteryLevelUUID = "2A19"

    static let productNumber: UInt8 = 0x03
    static let weightMessageType: UInt8 = 0x0B

    static let atomicTareAndStartCommand: [UInt8] = [0x03, 0x0A, 0x07, 0x00, 0x00, 0x0E]
    static let bookooStyleAtomicTareAndStartCommand: [UInt8] = [0x03, 0x0A, 0x07, 0x00, 0x00, 0x00]

    static func parseCapabilities(_ data: Data) -> WMBPlusCapabilities? {
        let bytes = [UInt8](data)
        guard bytes.count == 16 else { return nil }
        guard bytes[0] == productNumber, bytes[1] == 0x0C else { return nil }
        guard xorChecksum(bytes.dropLast()) == bytes[15] else { return nil }

        let featureMask = UInt32(bytes[6])
            | UInt32(bytes[7]) << 8
            | UInt32(bytes[8]) << 16
            | UInt32(bytes[9]) << 24

        return WMBPlusCapabilities(
            payloadVersion: bytes[2],
            protocolMajor: bytes[4],
            protocolMinor: bytes[5],
            featureMask: featureMask,
            preferredAtomicCommand: bytes[10],
            preferredAtomicData1: bytes[11],
            extensionPacketVersion: bytes[12],
            extensionPacketLength: bytes[13]
        )
    }

    static func parse20BytePacket(
        _ data: Data,
        capabilities: WMBPlusCapabilities?,
        arrivalTime: Date,
        monotonicSeconds: Double
    ) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count == 20 else { return .failure(.invalidLength) }
        guard bytes[0] == productNumber else { return .failure(.invalidProduct) }
        guard bytes[1] == weightMessageType else { return .failure(.invalidMessageType) }
        guard xorChecksum(bytes.dropLast()) == bytes[19] else { return .failure(.invalidChecksum) }

        let weight = signedCentiValue(signByte: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
        let hasExtension = capabilities?.supportsExtendedPacket == true && bytes[5] == capabilities?.extensionPacketVersion

        if hasExtension {
            let battery = Int(bytes[13])
            let quality = Int(bytes[16])
            return .success(ScaleSample(
                arrivalTime: arrivalTime,
                monotonicSeconds: monotonicSeconds,
                scaleKind: .weighMyBruPlus,
                weightGrams: weight,
                deviceTimestampMilliseconds: uint24(bytes[2], bytes[3], bytes[4]),
                sequence: bytes[14],
                batteryPercent: battery <= 100 ? battery : nil,
                flowGramsPerSecond: signedCentiValue(signByte: bytes[10], high: 0, mid: bytes[11], low: bytes[12]),
                firmwareQualityScore: quality <= 100 ? quality : nil,
                detectedSampleRateHz: bytes[17] == 0 ? nil : Int(bytes[17]),
                statusFlags: ScaleStatusFlags(byte: bytes[15]),
                diagnosticFlags: ScaleDiagnosticFlags(byte: bytes[18])
            ))
        }

        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .weighMyBru,
            weightGrams: weight,
            deviceTimestampMilliseconds: nil,
            sequence: nil,
            batteryPercent: nil,
            flowGramsPerSecond: nil,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: nil
        ))
    }

    static func parseFloat32Packet(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count == 4 else { return .failure(.invalidLength) }

        let bitPattern = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bitPattern)
        guard value.isFinite else { return .failure(.invalidFloat) }

        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .weighMyBru,
            weightGrams: Double(value),
            deviceTimestampMilliseconds: nil,
            sequence: nil,
            batteryPercent: nil,
            flowGramsPerSecond: nil,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: nil
        ))
    }
}

func uint24(_ high: UInt8, _ mid: UInt8, _ low: UInt8) -> UInt32 {
    UInt32(high) << 16 | UInt32(mid) << 8 | UInt32(low)
}

func signedCentiValue(signByte: UInt8, high: UInt8, mid: UInt8, low: UInt8) -> Double {
    let raw = UInt32(high) << 16 | UInt32(mid) << 8 | UInt32(low)
    let sign = signByte == 0x2D ? -1.0 : 1.0
    return sign * Double(raw) / 100.0
}

func xorChecksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
    bytes.reduce(UInt8(0), ^)
}
