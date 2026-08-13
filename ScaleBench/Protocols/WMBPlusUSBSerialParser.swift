import Foundation

struct WMBPlusUSBStatus: OptionSet, Equatable {
    let rawValue: UInt16

    static let hx711Connected = WMBPlusUSBStatus(rawValue: 0x0001)
    static let bleConnected = WMBPlusUSBStatus(rawValue: 0x0002)
    static let recentBump = WMBPlusUSBStatus(rawValue: 0x0004)
    static let recentGlitch = WMBPlusUSBStatus(rawValue: 0x0008)
    static let zeroClamped = WMBPlusUSBStatus(rawValue: 0x0010)
    static let autoZeroActive = WMBPlusUSBStatus(rawValue: 0x0020)
    static let batteryValid = WMBPlusUSBStatus(rawValue: 0x0040)
    static let charging = WMBPlusUSBStatus(rawValue: 0x0080)
    static let wifiRadioOn = WMBPlusUSBStatus(rawValue: 0x0100)

    var labels: [String] {
        [
            (Self.hx711Connected, "HX711 connected"),
            (Self.bleConnected, "BLE connected"),
            (Self.recentBump, "Recent bump"),
            (Self.recentGlitch, "Recent glitch"),
            (Self.zeroClamped, "Zero clamped"),
            (Self.autoZeroActive, "Auto-zero active"),
            (Self.batteryValid, "Battery valid"),
            (Self.charging, "Charging"),
            (Self.wifiRadioOn, "WiFi radio on"),
        ].compactMap { flag, label in contains(flag) ? label : nil }
    }
}

enum WMBPlusUSBSerialParseError: Equatable {
    case fieldCount
    case invalidInteger(field: String)
    case invalidFloat(field: String)
    case invalidStatus
    case invalidRange(field: String)
}

enum WMBPlusUSBSerialParseResult: Equatable {
    case ignored
    case rejected(WMBPlusUSBSerialParseError)
    case sample(WMBPlusUSBSerialRow)
}

struct WMBPlusUSBSerialRow: Equatable {
    static let protocolName = "WMB+ USB Serial"
    static let deviceName = "WMB+ USB"
    static let baud = 115_200

    var firmwareMillis: UInt32
    var sequenceNumber: UInt32
    var weightGrams: Double
    var flowGramsPerSecond: Double
    var status: WMBPlusUSBStatus
    var firmwareQuality: Int
    var batteryPercent: Int?
    var hx711Hz: Double
    var droppedCumulative: UInt32
    var droppedDelta: UInt32
    var hostReceivedAt: Date
    var hostMonotonicSeconds: Double
    var fields: [PacketFieldAnnotation]

    var isValidWeightSample: Bool {
        status.contains(.hx711Connected)
    }

    var metadata: USBSerialSampleMetadata {
        USBSerialSampleMetadata(
            firmwareMillis: firmwareMillis,
            sequenceNumber: sequenceNumber,
            usbStatusRaw: status.rawValue,
            usbStatusLabels: status.labels,
            firmwareQuality: firmwareQuality,
            hx711Hz: hx711Hz,
            usbDroppedCumulative: droppedCumulative,
            usbDroppedDelta: droppedDelta,
            hostReceivedAt: hostReceivedAt
        )
    }

    var sample: ScaleSample {
        var statusByte: UInt8 = 0
        if status.contains(.hx711Connected) { statusByte |= 0x02 }
        if status.contains(.batteryValid) { statusByte |= 0x40 }

        var diagnosticByte: UInt8 = 0x20 | 0x40 | 0x80
        if status.contains(.recentBump) { diagnosticByte |= 0x01 }
        if hx711Hz > 0 { diagnosticByte |= 0x04 }
        if hx711Hz >= 60 { diagnosticByte |= 0x08 }
        if (8...12).contains(hx711Hz) { diagnosticByte |= 0x10 }

        return ScaleSample(
            arrivalTime: hostReceivedAt,
            monotonicSeconds: hostMonotonicSeconds,
            scaleKind: .weighMyBruPlus,
            weightGrams: weightGrams,
            deviceTimestampMilliseconds: firmwareMillis,
            sequence: nil,
            batteryPercent: batteryPercent,
            flowGramsPerSecond: flowGramsPerSecond,
            firmwareQualityScore: firmwareQuality,
            detectedSampleRateHz: Int(hx711Hz.rounded()),
            statusFlags: ScaleStatusFlags(byte: statusByte),
            diagnosticFlags: ScaleDiagnosticFlags(byte: diagnosticByte),
            usbSerial: metadata
        )
    }
}

struct WMBPlusUSBSerialParser {
    static let header = "WMBP_WEIGHT_V1_HEADER,ms,seq,weight_g,flow_gps,status,quality,battery_pct,hx711_hz,dropped"
    private(set) var previousDropped: UInt32?

    mutating func reset() {
        previousDropped = nil
    }

    mutating func parse(
        line: String,
        hostReceivedAt: Date,
        hostMonotonicSeconds: Double
    ) -> WMBPlusUSBSerialParseResult {
        guard line.hasPrefix("WMBP_WEIGHT_V1,") else { return .ignored }

        let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 10 else { return .rejected(.fieldCount) }

        guard let firmwareMillis = UInt32(values[1]) else {
            return .rejected(.invalidInteger(field: "ms"))
        }
        guard let sequenceNumber = UInt32(values[2]) else {
            return .rejected(.invalidInteger(field: "seq"))
        }
        guard let weightGrams = finiteDouble(values[3]) else {
            return .rejected(.invalidFloat(field: "weight_g"))
        }
        guard let flowGramsPerSecond = finiteDouble(values[4]) else {
            return .rejected(.invalidFloat(field: "flow_gps"))
        }
        guard values[5].hasPrefix("0x") || values[5].hasPrefix("0X"),
              let statusRaw = UInt16(values[5].dropFirst(2), radix: 16) else {
            return .rejected(.invalidStatus)
        }
        let status = WMBPlusUSBStatus(rawValue: statusRaw)
        guard let firmwareQuality = Int(values[6]) else {
            return .rejected(.invalidInteger(field: "quality"))
        }
        guard (0...100).contains(firmwareQuality) else {
            return .rejected(.invalidRange(field: "quality"))
        }
        guard let rawBattery = Int(values[7]) else {
            return .rejected(.invalidInteger(field: "battery_pct"))
        }
        if status.contains(.batteryValid), !(0...100).contains(rawBattery) {
            return .rejected(.invalidRange(field: "battery_pct"))
        }
        guard let hx711Hz = finiteDouble(values[8]) else {
            return .rejected(.invalidFloat(field: "hx711_hz"))
        }
        guard hx711Hz >= 0 else {
            return .rejected(.invalidRange(field: "hx711_hz"))
        }
        guard let droppedCumulative = UInt32(values[9]) else {
            return .rejected(.invalidInteger(field: "dropped"))
        }

        let droppedDelta: UInt32
        if let previousDropped, droppedCumulative > previousDropped {
            droppedDelta = droppedCumulative - previousDropped
        } else {
            droppedDelta = 0
        }
        previousDropped = droppedCumulative

        return .sample(WMBPlusUSBSerialRow(
            firmwareMillis: firmwareMillis,
            sequenceNumber: sequenceNumber,
            weightGrams: weightGrams,
            flowGramsPerSecond: flowGramsPerSecond,
            status: status,
            firmwareQuality: firmwareQuality,
            batteryPercent: status.contains(.batteryValid) ? rawBattery : nil,
            hx711Hz: hx711Hz,
            droppedCumulative: droppedCumulative,
            droppedDelta: droppedDelta,
            hostReceivedAt: hostReceivedAt,
            hostMonotonicSeconds: hostMonotonicSeconds,
            fields: annotations(for: values)
        ))
    }

    private func finiteDouble(_ value: String) -> Double? {
        guard let parsed = Double(value), parsed.isFinite else { return nil }
        return parsed
    }

    private func annotations(for values: [String]) -> [PacketFieldAnnotation] {
        let labels: [(String, PacketFieldSemantic)] = [
            ("Type", .header),
            ("Firmware millis", .timestamp),
            ("Sequence", .sequence),
            ("Weight", .weight),
            ("Flow", .flow),
            ("Status", .status),
            ("Firmware quality", .quality),
            ("Battery", .battery),
            ("HX711 cadence", .sampleRate),
            ("USB dropped", .payload),
        ]
        var byteOffset = 0
        return zip(values, labels).map { value, descriptor in
            defer { byteOffset += value.utf8.count + 1 }
            return PacketFieldAnnotation(
                startByte: byteOffset,
                endByteExclusive: byteOffset + value.utf8.count,
                label: descriptor.0,
                decodedValue: value,
                semantic: descriptor.1
            )
        }
    }
}

struct USBSerialLineBuffer {
    private var bytes = Data()
    private let maximumBufferedBytes = 64 * 1024

    mutating func append(_ chunk: Data) -> [String] {
        bytes.append(chunk)
        if bytes.count > maximumBufferedBytes,
           !bytes.contains(0x0A) {
            bytes.removeAll(keepingCapacity: true)
            return []
        }

        var lines: [String] = []
        while let newline = bytes.firstIndex(of: 0x0A) {
            var lineData = bytes[..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            bytes.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
    }
}
