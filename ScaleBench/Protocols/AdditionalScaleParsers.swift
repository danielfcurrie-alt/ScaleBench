import Foundation

// Parser adapters for supported Bluetooth scale protocols.
// These are intentionally sample-focused: ScaleBench records raw packets for forensic analysis
// and turns every supported weight/status notification into one canonical ScaleSample stream.

enum AcaiaParser {
    static let maxPayloadLength = 64
    static let serviceUUID = "1820"
    static let fullServiceUUID = "00001820-0000-1000-8000-00805F9B34FB"
    static let legacyServiceUUID = "49535343-FE7D-4AE5-8FA9-9FAFD205E455"
    static let modernCharUUID = "2A80"
    static let fullModernCharUUID = "00002A80-0000-1000-8000-00805F9B34FB"
    static let legacyNotifyUUID = "49535343-1E4D-4BD9-BA61-23C647249616"
    static let legacyWriteUUID = "49535343-8841-43F4-A8D4-ECBE34729BB3"

    static func nameMatches(_ name: String) -> Bool {
        guard name.count >= 5 else { return false }
        let prefix = name.prefix(5).uppercased()
        return ["ACAIA", "LUNAR", "PYXIS", "PROCH", "PEARL", "CINCO"].contains(String(prefix))
    }

    static func identifyCommand(isPyxis: Bool) -> [UInt8] {
        let payload = isPyxis ? Array("012345678901234".utf8) : Array(repeating: UInt8(0x2D), count: 15)
        return frame(type: 0x0B, payload: payload)
    }

    static let notificationRequestCommand = frame(type: 0x0C, payload: [0x09, 0x00, 0x01, 0x01, 0x02, 0x02, 0x05, 0x03, 0x04])

    static func frame(type: UInt8, payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [0xEF, 0xDD, type]
        packet.append(contentsOf: payload)
        var even: UInt8 = 0
        var odd: UInt8 = 0
        for (index, byte) in payload.enumerated() {
            if index.isMultiple(of: 2) { even &+= byte } else { odd &+= byte }
        }
        packet.append(even)
        packet.append(odd)
        return packet
    }

    final class Codec {
        private var buffer: [UInt8] = []

        func receive(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> [ScaleParserEvent] {
            buffer.append(contentsOf: data)
            var events: [ScaleParserEvent] = []

            while true {
                guard buffer.count >= 2 else { return events }
                guard let start = (0..<(buffer.count - 1)).first(where: { buffer[$0] == 0xEF && buffer[$0 + 1] == 0xDD }) else {
                    buffer = buffer.last == 0xEF ? [0xEF] : []
                    events.append(.rejected(.invalidHeader))
                    return events
                }
                if start > 0 {
                    buffer.removeFirst(start)
                    events.append(.rejected(.invalidHeader))
                }
                guard buffer.count >= 4 else { return events }
                let payloadLength = Int(buffer[3])
                guard payloadLength <= AcaiaParser.maxPayloadLength else {
                    buffer.removeFirst()
                    events.append(.rejected(.invalidLength))
                    continue
                }
                let frameLength = 4 + payloadLength + 2
                guard buffer.count >= frameLength else { return events }
                let frame = Array(buffer.prefix(frameLength))
                buffer.removeFirst(frameLength)
                events.append(parseFrame(frame, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds))
            }
        }

        private func parseFrame(_ frame: [UInt8], arrivalTime: Date, monotonicSeconds: Double) -> ScaleParserEvent {
            guard frame.count >= 9, frame[0] == 0xEF, frame[1] == 0xDD else { return .rejected(.invalidHeader) }
            guard frame[2] == 0x0C else { return .rejected(.unsupportedFrame) }
            guard hasValidChecksum(frame) else { return .rejected(.invalidChecksum) }
            let raw = Int16(bitPattern: UInt16(frame[4]) | (UInt16(frame[5]) << 8))
            let divisor = Int(frame[6])
            let isNegative = (frame[7] & 0x02) != 0
            let magnitude = abs(Double(raw)) / pow(10.0, Double(divisor))
            let grams = isNegative ? -magnitude : magnitude
            guard grams.isFinite else { return .rejected(.invalidRange) }
            return .sample(ScaleSample(
                arrivalTime: arrivalTime,
                monotonicSeconds: monotonicSeconds,
                scaleKind: .acaia,
                weightGrams: grams,
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

        private func hasValidChecksum(_ frame: [UInt8]) -> Bool {
            guard frame.count >= 6 else { return false }
            let payloadLength = Int(frame[3])
            let payloadStart = 4
            let checksumStart = payloadStart + payloadLength
            guard frame.count >= checksumStart + 2 else { return false }

            var even: UInt8 = 0
            var odd: UInt8 = 0
            for (index, byte) in frame[payloadStart..<checksumStart].enumerated() {
                if index.isMultiple(of: 2) {
                    even &+= byte
                } else {
                    odd &+= byte
                }
            }
            return frame[checksumStart] == even && frame[checksumStart + 1] == odd
        }
    }
}

enum DecentEspressiParser {
    static let serviceUUID = "FFF0"
    static let notifyUUID = "FFF4"
    static let writeUUID = "36F5"

    static func parseWeightPacket(_ data: Data, kind: ScaleKind, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return .failure(.invalidLength) }
        guard bytes[1] == 0xCE || bytes[1] == 0xCA else { return .failure(.unsupportedFrame) }
        let raw = Int16(bitPattern: (UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        let grams = Double(raw) / 10.0
        let timestamp: UInt32?
        if bytes.count >= 10, bytes[6] < 60, bytes[7] < 10 {
            let seconds = Double(bytes[5]) * 60.0 + Double(bytes[6]) + Double(bytes[7]) / 10.0
            let milliseconds = UInt32((seconds * 1_000.0).rounded())
            timestamp = milliseconds > 0 ? milliseconds : nil
        } else {
            timestamp = nil
        }
        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: kind == .espressi ? .espressi : .decent,
            weightGrams: grams,
            deviceTimestampMilliseconds: timestamp,
            sequence: nil,
            batteryPercent: nil,
            flowGramsPerSecond: nil,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: nil
        ))
    }

    static func frame(_ bytes: [UInt8]) -> [UInt8] { bytes + [bytes.reduce(0, ^)] }
    static let decentHeartbeatCommand = frame([0x03, 0x0A, 0x03, 0xFF, 0xFF, 0x00])
    static let decentLEDsOnCommand = frame([0x03, 0x0A, 0x01, 0x01, 0x00, 0x01])
}

enum DiFluidParser {
    static let serviceUUID = "00EE"
    static let tiServiceUUID = "00DD"
    static let charUUID = "AA01"
    static let config1Command: [UInt8] = [0xDF, 0xDF, 0x01, 0x04, 0x01, 0x00, 0xC4]
    static let config2Command: [UInt8] = [0xDF, 0xDF, 0x01, 0x00, 0x01, 0x01, 0xC1]
    static let requestStatusCommand: [UInt8] = [0xDF, 0xDF, 0x03, 0x05, 0x00, 0xC6]

    static func parse(_ data: Data, kind: ScaleKind, arrivalTime: Date, monotonicSeconds: Double) -> ScaleParserEvent {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return .rejected(.invalidLength) }
        guard bytes[0] == 0xDF, bytes[1] == 0xDF else { return .rejected(.invalidHeader) }
        guard hasValidChecksum(bytes) else { return .rejected(.invalidChecksum) }

        switch (bytes[2], bytes[3]) {
        case (0x03, 0x00):
            guard bytes.count >= 19, bytes[4] >= 13 else { return .rejected(.invalidLength) }
            guard bytes[17] == 0x00 else { return .rejected(.invalidUnit) }
            let raw = Int32(bitPattern: (UInt32(bytes[5]) << 24) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 8) | UInt32(bytes[8]))
            let rawFlow = Int16(bitPattern: (UInt16(bytes[9]) << 8) | UInt16(bytes[10]))
            let timestamp = (UInt32(bytes[13]) << 24) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 8) | UInt32(bytes[16])
            return .sample(ScaleSample(
                arrivalTime: arrivalTime,
                monotonicSeconds: monotonicSeconds,
                scaleKind: kind == .difluidTi ? .difluidTi : .difluid,
                weightGrams: Double(raw) / 10.0,
                deviceTimestampMilliseconds: timestamp,
                sequence: nil,
                batteryPercent: nil,
                flowGramsPerSecond: abs(Double(rawFlow) / 10.0) < 50 ? Double(rawFlow) / 10.0 : nil,
                firmwareQualityScore: nil,
                detectedSampleRateHz: nil,
                statusFlags: nil,
                diagnosticFlags: ScaleDiagnosticFlags(byte: 0x40)
            ))

        case (0x03, 0x05):
            guard bytes.count >= 14, bytes[4] >= 8 else { return .rejected(.invalidLength) }
            let battery = Int(bytes[6])
            guard (0...100).contains(battery) else { return .rejected(.invalidRange) }
            return .battery(percent: battery)

        default:
            return .rejected(.unsupportedFrame)
        }
    }

    private static func hasValidChecksum(_ bytes: [UInt8]) -> Bool {
        guard let checksum = bytes.last else { return false }
        return bytes.dropLast().reduce(UInt8(0)) { $0 &+ $1 } == checksum
    }
}

enum EurekaPrecisaParser {
    static let serviceUUID = "FFF0"
    static let notifyUUID = "FFF1"
    static let writeUUID = "FFF2"

    static func nameMatches(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "cfs-9002" || lower == "lsj-001" || lower.contains("eureka") || lower.contains("solo")
    }

    static func parse(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count == 11 else { return .failure(.invalidLength) }
        guard bytes[0] == 0xAA, bytes[2] == 0x41 else { return .failure(.invalidHeader) }
        let sign: Double = bytes[6] != 0 ? -1 : 1
        let raw = UInt16(bytes[7]) | (UInt16(bytes[8]) << 8)
        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .eureka,
            weightGrams: sign * Double(raw) / 10.0,
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

enum FelicitaParser {
    static let serviceUUID = "FFE0"
    static let charUUID = "FFE1"

    static func nameMatches(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("felicita") || lower.contains("arc") || lower.contains("incline")
    }

    static func parse(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count == 18 else { return .failure(.invalidLength) }
        let digits = bytes[3...8]
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return .failure(.invalidRange) }
        let raw = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        let grams = Double(raw) / 100.0
        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .felicita,
            weightGrams: bytes[2] == 0x2D ? -grams : grams,
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

enum FutulaParser {
    static let serviceUUID = "FFF0"
    static let notifyUUID = "FFF4"
    static let writeUUID = "FFF1"
    static let setGramsCommand: [UInt8] = [0xFD, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF9]

    static func nameMatches(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("lfsmart scale") || lower.contains("lefu")
    }

    static func parse(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count >= 9 else { return .failure(.invalidLength) }
        let raw = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
        let grams = Double(raw) / 10.0
        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .futula,
            weightGrams: bytes[5] != 0 ? -grams : grams,
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

enum Skale2Parser {
    static let serviceUUID = "FF08"
    static let notifyUUID = "EF81"
    static let writeUUID = "EF80"
    static let initialCommands: [[UInt8]] = [[0xED], [0xEC], [0x03]]

    static func nameMatches(_ name: String) -> Bool { name.lowercased().hasPrefix("skale") }

    static func parse(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> Result<ScaleSample, ParseRejectionReason> {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return .failure(.invalidLength) }
        let raw = Int16(bitPattern: UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        return .success(ScaleSample(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: .skale2,
            weightGrams: Double(raw) / 10.0,
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

enum TimemoreDotParser {
    static let serviceUUID = "FFF0"
    static let notifyUUID = "FFF1"
    static let writeUUID = "FFF2"
    static let maxPayloadLength = 64
    private static let header: [UInt8] = [0xA5, 0x5A]
    static let setGramsCommand = frame(opcode: 0x03, command: 0x06, payload: [0x00])
    static let setStandardModeCommand = frame(opcode: 0x03, command: 0x08, payload: [0x01, 0x00])

    static func nameMatches(_ name: String) -> Bool {
        let lower = name.lowercased()
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.contains("tes017") { return true }
        if lower == "dot" { return true }
        return tokens.contains("dot") && (tokens.contains("timemore") || tokens.contains("black"))
    }

    final class Codec {
        private var buffer: [UInt8] = []

        func receive(_ data: Data, arrivalTime: Date, monotonicSeconds: Double) -> [ScaleParserEvent] {
            buffer.append(contentsOf: data)
            var events: [ScaleParserEvent] = []

            while true {
                guard buffer.count >= 2 else { return events }
                guard buffer.starts(with: header) else {
                    discardUntilPotentialHeader()
                    events.append(.rejected(.invalidHeader))
                    continue
                }
                guard buffer.count >= 8 else { return events }
                let payloadLength = (Int(buffer[4]) << 8) | Int(buffer[5])
                guard payloadLength <= maxPayloadLength else {
                    buffer.removeFirst()
                    events.append(.rejected(.invalidLength))
                    continue
                }
                let frameLength = 8 + payloadLength
                guard buffer.count >= frameLength else { return events }
                let frame = Array(buffer.prefix(frameLength))
                buffer.removeFirst(frameLength)
                let expectedCRC = TimemoreDotParser.crc16(frame.dropLast(2))
                let actualCRC = (UInt16(frame[frameLength - 2]) << 8) | UInt16(frame[frameLength - 1])
                guard expectedCRC == actualCRC else {
                    events.append(.rejected(.invalidCRC))
                    continue
                }
                events.append(contentsOf: decode(frame, payloadLength: payloadLength, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds))
            }
        }

        private func decode(_ frame: [UInt8], payloadLength: Int, arrivalTime: Date, monotonicSeconds: Double) -> [ScaleParserEvent] {
            let opcode = frame[2]
            let command = frame[3]
            let payload = Array(frame[6..<(6 + payloadLength)])
            guard opcode == 0x01 || opcode == 0x02 else { return [.rejected(.unsupportedFrame)] }
            switch command {
            case 0x01:
                guard payload.count >= 8 else { return [.rejected(.invalidLength)] }
                let raw = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16) | (UInt32(payload[2]) << 8) | UInt32(payload[3])
                let grams = Double(Int32(bitPattern: raw)) / 10.0
                guard grams.isFinite, abs(grams) <= 10_000 else { return [.rejected(.invalidRange)] }
                return [.sample(ScaleSample(
                    arrivalTime: arrivalTime,
                    monotonicSeconds: monotonicSeconds,
                    scaleKind: .timemoreDot,
                    weightGrams: grams,
                    deviceTimestampMilliseconds: nil,
                    sequence: nil,
                    batteryPercent: nil,
                    flowGramsPerSecond: nil,
                    firmwareQualityScore: nil,
                    detectedSampleRateHz: nil,
                    statusFlags: nil,
                    diagnosticFlags: nil
                ))]
            case 0x05:
                guard payload.count >= 2 else { return [.rejected(.invalidLength)] }
                let percent = Int(payload[1])
                guard (0...100).contains(percent) else { return [.rejected(.invalidRange)] }
                return [.battery(percent: percent)]
            default:
                return [.rejected(.unsupportedFrame)]
            }
        }

        private func discardUntilPotentialHeader() {
            if let index = buffer.dropFirst().firstIndex(of: header[0]) {
                buffer.removeFirst(index)
            } else {
                buffer = buffer.last == header[0] ? [header[0]] : []
            }
        }
    }

    static func frame(opcode: UInt8, command: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame = header
        frame.append(opcode)
        frame.append(command)
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(contentsOf: payload)
        let crc = crc16(frame)
        frame.append(UInt8((crc >> 8) & 0xFF))
        frame.append(UInt8(crc & 0xFF))
        return frame
    }

    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc = UInt16(0xFFFF)
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 0x0001) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}
