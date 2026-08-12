import Foundation

enum PacketFieldDecoder {
    static func annotations(for packet: RawScalePacket) -> [PacketFieldAnnotation] {
        if let fields = packet.fields, !fields.isEmpty {
            return fields
        }
        guard let bytes = bytes(fromHex: packet.bytesHex) else { return [] }
        return annotations(
            scaleKind: packet.scaleKind,
            characteristicUUID: packet.characteristicUUID,
            bytes: bytes
        )
    }

    static func annotations(
        scaleKind: ScaleKind,
        characteristicUUID: String,
        bytes: [UInt8]
    ) -> [PacketFieldAnnotation] {
        guard !bytes.isEmpty else { return [] }
        let uuid = shortUUID(characteristicUUID)

        if uuid == shortUUID(WeighMyBruParser.batteryLevelUUID), bytes.count >= 1 {
            return [field(0, 1, "Battery", "\(bytes[0])%", .battery)]
        }
        if uuid == shortUUID(WeighMyBruParser.capabilitiesUUID), bytes.count == 16 {
            return wmbCapabilities(bytes)
        }
        if uuid == shortUUID(WeighMyBruParser.float32UUID), bytes.count == 4 {
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Float(bitPattern: bits)
            return [field(0, 4, "Weight", value.isFinite ? grams(Double(value)) : "invalid float", .weight)]
        }
        if uuid == shortUUID(WeighMyBruParser.weight20UUID), bytes.count == 20 {
            return wmbWeight(bytes, extended: scaleKind == .weighMyBruPlus)
        }

        switch scaleKind {
        case .bookoo, .bookooMini, .bookooUltra:
            return bytes.count == 20 ? bookoo(bytes) : []
        case .weighMyBru, .weighMyBruPlus:
            return bytes.count == 20 ? wmbWeight(bytes, extended: scaleKind == .weighMyBruPlus) : []
        case .eureka:
            return eureka(bytes)
        case .decent, .espressi:
            return decent(bytes)
        case .difluid, .difluidTi:
            return diFluid(bytes)
        case .felicita:
            return felicita(bytes)
        case .futula:
            return futula(bytes)
        case .skale2:
            return skale2(bytes)
        case .acaia:
            return acaia(bytes)
        case .timemoreDot:
            return timemore(bytes)
        case .unknown:
            return []
        }
    }

    static func bytes(fromHex value: String) -> [UInt8]? {
        let compact = value.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        return result
    }

    static func normalizedHex(_ value: String) -> String {
        guard let bytes = bytes(fromHex: value) else { return value }
        return Data(bytes).hexString
    }

    private static func wmbWeight(_ bytes: [UInt8], extended: Bool) -> [PacketFieldAnnotation] {
        let weight = signedCenti(sign: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
        var fields = [
            field(0, 2, "Header", hex(bytes[0..<2]), .header),
            field(2, 5, extended ? "Timestamp" : "Protocol data", extended ? "\(uint24(bytes[2], bytes[3], bytes[4])) ms" : hex(bytes[2..<5]), extended ? .timestamp : .payload),
            field(5, 6, extended ? "Packet version" : "Protocol data", extended ? "\(bytes[5])" : hex(bytes[5..<6]), .payload),
            field(6, 10, "Weight", grams(weight), .weight)
        ]
        if extended {
            let flow = signedCenti(sign: bytes[10], high: 0, mid: bytes[11], low: bytes[12])
            fields += [
                field(10, 13, "Flow", rate(flow), .flow),
                field(13, 14, "Battery", "\(bytes[13])%", .battery),
                field(14, 15, "Sequence", "\(bytes[14])", .sequence),
                field(15, 16, "Status", hex(bytes[15..<16]), .status),
                field(16, 17, "Quality", "\(bytes[16])%", .quality),
                field(17, 18, "Sample rate", "\(bytes[17]) Hz", .sampleRate),
                field(18, 19, "Diagnostics", hex(bytes[18..<19]), .status)
            ]
        } else {
            fields.append(field(10, 19, "Protocol data", hex(bytes[10..<19]), .payload))
        }
        fields.append(field(19, 20, "Checksum", hex(bytes[19..<20]), .checksum))
        return fields
    }

    private static func wmbCapabilities(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        let featureMask = UInt32(bytes[6]) | UInt32(bytes[7]) << 8 | UInt32(bytes[8]) << 16 | UInt32(bytes[9]) << 24
        return [
            field(0, 2, "Header", hex(bytes[0..<2]), .header),
            field(2, 3, "Payload version", "\(bytes[2])", .payload),
            field(3, 4, "Reserved", hex(bytes[3..<4]), .payload),
            field(4, 6, "Protocol version", "\(bytes[4]).\(bytes[5])", .payload),
            field(6, 10, "Feature mask", String(format: "0x%08X", featureMask), .status),
            field(10, 12, "Atomic command", hex(bytes[10..<12]), .payload),
            field(12, 13, "Extension version", "\(bytes[12])", .payload),
            field(13, 14, "Extension length", "\(bytes[13]) bytes", .payload),
            field(14, 15, "Reserved", hex(bytes[14..<15]), .payload),
            field(15, 16, "Checksum", hex(bytes[15..<16]), .checksum)
        ]
    }

    private static func bookoo(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        let weight = signedCenti(sign: bytes[6], high: bytes[7], mid: bytes[8], low: bytes[9])
        let flow = signedCenti(sign: bytes[10], high: 0, mid: bytes[11], low: bytes[12])
        return [
            field(0, 2, "Header", hex(bytes[0..<2]), .header),
            field(2, 5, "Timestamp", "\(uint24(bytes[2], bytes[3], bytes[4])) ms", .timestamp),
            field(5, 6, "Protocol data", hex(bytes[5..<6]), .payload),
            field(6, 10, "Weight", grams(weight), .weight),
            field(10, 13, "Flow", rate(flow), .flow),
            field(13, 14, "Battery", "\(bytes[13])%", .battery),
            field(14, 19, "Protocol data", hex(bytes[14..<19]), .payload),
            field(19, 20, "Checksum", hex(bytes[19..<20]), .checksum)
        ]
    }

    private static func eureka(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count == 11 else { return [] }
        let raw = UInt16(bytes[7]) | UInt16(bytes[8]) << 8
        let weight = (bytes[6] == 0 ? 1.0 : -1.0) * Double(raw) / 10
        return [
            field(0, 3, "Header", hex(bytes[0..<3]), .header),
            field(3, 6, "Protocol data", hex(bytes[3..<6]), .payload),
            field(6, 7, "Sign", bytes[6] == 0 ? "positive" : "negative", .weight),
            field(7, 9, "Weight", grams(weight), .weight),
            field(9, 11, "Protocol data", hex(bytes[9..<11]), .payload)
        ]
    }

    private static func decent(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count >= 4 else { return [] }
        let raw = Int16(bitPattern: UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        var fields = [
            field(0, 2, "Message", hex(bytes[0..<2]), .header),
            field(2, 4, "Weight", grams(Double(raw) / 10), .weight)
        ]
        if bytes.count >= 8, bytes[6] < 60, bytes[7] < 10 {
            let seconds = Double(bytes[5]) * 60 + Double(bytes[6]) + Double(bytes[7]) / 10
            if bytes.count > 4 { fields.append(field(4, 5, "Protocol data", hex(bytes[4..<5]), .payload)) }
            fields.append(field(5, 8, "Timer", String(format: "%.1f s", seconds), .timestamp))
            if bytes.count > 8 { fields.append(field(8, bytes.count, "Protocol data", hex(bytes[8..<bytes.count]), .payload)) }
        } else if bytes.count > 4 {
            fields.append(field(4, bytes.count, "Protocol data", hex(bytes[4..<bytes.count]), .payload))
        }
        return fields
    }

    private static func diFluid(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count >= 6 else { return [] }
        var fields = [
            field(0, 2, "Header", hex(bytes[0..<2]), .header),
            field(2, 4, "Message", hex(bytes[2..<4]), .payload),
            field(4, 5, "Payload length", "\(bytes[4]) bytes", .payload)
        ]
        if bytes[2] == 0x03, bytes[3] == 0x00, bytes.count >= 19 {
            let raw = Int32(bitPattern: UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 8 | UInt32(bytes[8]))
            let rawFlow = Int16(bitPattern: UInt16(bytes[9]) << 8 | UInt16(bytes[10]))
            let timestamp = UInt32(bytes[13]) << 24 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 8 | UInt32(bytes[16])
            fields += [
                field(5, 9, "Weight", grams(Double(raw) / 10), .weight),
                field(9, 11, "Flow", rate(Double(rawFlow) / 10), .flow),
                field(11, 13, "Protocol data", hex(bytes[11..<13]), .payload),
                field(13, 17, "Timestamp", "\(timestamp) ms", .timestamp),
                field(17, 18, "Unit", bytes[17] == 0 ? "grams" : hex(bytes[17..<18]), .unit)
            ]
            if bytes.count > 19 { fields.append(field(18, bytes.count - 1, "Protocol data", hex(bytes[18..<(bytes.count - 1)]), .payload)) }
        } else if bytes[2] == 0x03, bytes[3] == 0x05, bytes.count >= 14 {
            if bytes.count > 6 { fields.append(field(5, 6, "Protocol data", hex(bytes[5..<6]), .payload)) }
            fields.append(field(6, 7, "Battery", "\(bytes[6])%", .battery))
            if bytes.count > 8 { fields.append(field(7, bytes.count - 1, "Protocol data", hex(bytes[7..<(bytes.count - 1)]), .payload)) }
        } else if bytes.count > 6 {
            fields.append(field(5, bytes.count - 1, "Protocol data", hex(bytes[5..<(bytes.count - 1)]), .payload))
        }
        fields.append(field(bytes.count - 1, bytes.count, "Checksum", hex(bytes[(bytes.count - 1)..<bytes.count]), .checksum))
        return fields
    }

    private static func felicita(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count == 18 else { return [] }
        let digits = bytes[3...8]
        let hasValidDigits = digits.allSatisfy { (0x30...0x39).contains($0) }
        let raw = digits.reduce(0) { $0 * 10 + max(0, Int($1) - 0x30) }
        let weight = (bytes[2] == 0x2D ? -1.0 : 1.0) * Double(raw) / 100
        return [
            field(0, 2, "Protocol data", hex(bytes[0..<2]), .payload),
            field(2, 3, "Sign", bytes[2] == 0x2D ? "negative" : "positive", .weight),
            field(3, 9, "Weight", hasValidDigits ? grams(weight) : "invalid digits", .weight),
            field(9, 18, "Protocol data", hex(bytes[9..<18]), .payload)
        ]
    }

    private static func futula(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count >= 9 else { return [] }
        let raw = UInt16(bytes[3]) | UInt16(bytes[4]) << 8
        let weight = (bytes[5] == 0 ? 1.0 : -1.0) * Double(raw) / 10
        return [
            field(0, 3, "Protocol data", hex(bytes[0..<3]), .payload),
            field(3, 5, "Weight", grams(weight), .weight),
            field(5, 6, "Sign", bytes[5] == 0 ? "positive" : "negative", .weight),
            field(6, bytes.count, "Protocol data", hex(bytes[6..<bytes.count]), .payload)
        ]
    }

    private static func skale2(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count >= 3 else { return [] }
        let raw = Int16(bitPattern: UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        var fields = [
            field(0, 1, "Message", hex(bytes[0..<1]), .header),
            field(1, 3, "Weight", grams(Double(raw) / 10), .weight)
        ]
        if bytes.count > 3 { fields.append(field(3, bytes.count, "Protocol data", hex(bytes[3..<bytes.count]), .payload)) }
        return fields
    }

    private static func acaia(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count >= 6, bytes[0] == 0xEF, bytes[1] == 0xDD else { return [] }
        let payloadLength = Int(bytes[3])
        guard bytes.count == payloadLength + 6 else { return [] }
        var fields = [
            field(0, 2, "Header", hex(bytes[0..<2]), .header),
            field(2, 3, "Message", hex(bytes[2..<3]), .payload),
            field(3, 4, "Payload length", "\(payloadLength) bytes", .payload)
        ]
        if bytes[2] == 0x0C, payloadLength >= 4 {
            let raw = Int16(bitPattern: UInt16(bytes[4]) | UInt16(bytes[5]) << 8)
            let divisor = pow(10.0, Double(bytes[6]))
            let sign = bytes[7] & 0x02 == 0 ? 1.0 : -1.0
            fields += [
                field(4, 6, "Weight", grams(sign * abs(Double(raw)) / divisor), .weight),
                field(6, 7, "Decimal places", "\(bytes[6])", .unit),
                field(7, 8, "Status", hex(bytes[7..<8]), .status)
            ]
            if payloadLength > 4 { fields.append(field(8, 4 + payloadLength, "Protocol data", hex(bytes[8..<(4 + payloadLength)]), .payload)) }
        } else if payloadLength > 0 {
            fields.append(field(4, 4 + payloadLength, "Payload", hex(bytes[4..<(4 + payloadLength)]), .payload))
        }
        fields.append(field(bytes.count - 2, bytes.count, "Checksum", hex(bytes[(bytes.count - 2)..<bytes.count]), .checksum))
        return fields
    }

    private static func timemore(_ bytes: [UInt8]) -> [PacketFieldAnnotation] {
        guard bytes.count >= 8, bytes[0] == 0xA5, bytes[1] == 0x5A else { return [] }
        let payloadLength = Int(bytes[4]) << 8 | Int(bytes[5])
        guard bytes.count == payloadLength + 8 else { return [] }
        var fields = [
            field(0, 2, "Header", hex(bytes[0..<2]), .header),
            field(2, 3, "Opcode", hex(bytes[2..<3]), .payload),
            field(3, 4, "Command", hex(bytes[3..<4]), .payload),
            field(4, 6, "Payload length", "\(payloadLength) bytes", .payload)
        ]
        if bytes[3] == 0x01, payloadLength >= 4 {
            let raw = Int32(bitPattern: UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 8 | UInt32(bytes[9]))
            fields.append(field(6, 10, "Weight", grams(Double(raw) / 10), .weight))
            if payloadLength > 4 { fields.append(field(10, 6 + payloadLength, "Protocol data", hex(bytes[10..<(6 + payloadLength)]), .payload)) }
        } else if bytes[3] == 0x05, payloadLength >= 2 {
            fields.append(field(6, 7, "Protocol data", hex(bytes[6..<7]), .payload))
            fields.append(field(7, 8, "Battery", "\(bytes[7])%", .battery))
            if payloadLength > 2 { fields.append(field(8, 6 + payloadLength, "Protocol data", hex(bytes[8..<(6 + payloadLength)]), .payload)) }
        } else if payloadLength > 0 {
            fields.append(field(6, 6 + payloadLength, "Payload", hex(bytes[6..<(6 + payloadLength)]), .payload))
        }
        fields.append(field(bytes.count - 2, bytes.count, "CRC", hex(bytes[(bytes.count - 2)..<bytes.count]), .checksum))
        return fields
    }

    private static func field(
        _ start: Int,
        _ end: Int,
        _ label: String,
        _ decodedValue: String,
        _ semantic: PacketFieldSemantic
    ) -> PacketFieldAnnotation {
        PacketFieldAnnotation(
            startByte: start,
            endByteExclusive: end,
            label: label,
            decodedValue: decodedValue,
            semantic: semantic
        )
    }

    private static func shortUUID(_ value: String) -> String {
        let upper = value.uppercased()
        let suffix = "-0000-1000-8000-00805F9B34FB"
        if upper.hasPrefix("0000"), upper.hasSuffix(suffix), upper.count >= 8 {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func uint24(_ high: UInt8, _ middle: UInt8, _ low: UInt8) -> UInt32 {
        UInt32(high) << 16 | UInt32(middle) << 8 | UInt32(low)
    }

    private static func signedCenti(sign: UInt8, high: UInt8, mid: UInt8, low: UInt8) -> Double {
        let raw = UInt32(high) << 16 | UInt32(mid) << 8 | UInt32(low)
        return (sign == 0x2D ? -1.0 : 1.0) * Double(raw) / 100
    }

    private static func grams(_ value: Double) -> String {
        String(format: "%.2f g", value)
    }

    private static func rate(_ value: Double) -> String {
        String(format: "%.2f g/s", value)
    }
}
