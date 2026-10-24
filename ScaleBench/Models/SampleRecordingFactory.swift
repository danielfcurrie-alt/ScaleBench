import Foundation

enum SampleRecordingFactory {
    struct Example {
        var title: String
        var notes: String
        var recording: ScaleRecording
    }

    static var examples: [Example] {
        [
            cleanWMBPlusPour(),
            legacyWMBPour(),
            noisySoloBaristaPour()
        ]
    }

    private static func cleanWMBPlusPour() -> Example {
        makeExample(
            title: "Example · Clean WMB+ Pour",
            notes: "Synthetic example. Clean WMB+ style stream with sequence numbers, device timestamps, battery, flow, and firmware quality.",
            kind: .weighMyBruPlus,
            deviceName: "Example WMB+ Scale",
            advertisedServices: [WeighMyBruParser.serviceUUID],
            duration: 30,
            sampleRate: 12,
            batteryStart: 86,
            includeMetadata: true,
            qualityScore: 96,
            gapAt: nil,
            rejectedPacketTimes: []
        )
    }

    private static func legacyWMBPour() -> Example {
        makeExample(
            title: "Example · Legacy WMB Pour",
            notes: "Synthetic example. Simple WeighMyBru-style stream with good cadence but limited metadata.",
            kind: .weighMyBru,
            deviceName: "Example WeighMyBru",
            advertisedServices: [WeighMyBruParser.serviceUUID],
            duration: 30,
            sampleRate: 8.3,
            batteryStart: nil,
            includeMetadata: false,
            qualityScore: nil,
            gapAt: nil,
            rejectedPacketTimes: []
        )
    }

    private static func noisySoloBaristaPour() -> Example {
        makeExample(
            title: "Example · Noisy Solo Barista Pour",
            notes: "Synthetic example. Solo Barista/Eureka-style stream with an intentional gap and rejected packets so the visualizer has red/orange score evidence.",
            kind: .eureka,
            deviceName: "Example Solo Barista",
            advertisedServices: [EurekaPrecisaParser.serviceUUID],
            duration: 30,
            sampleRate: 11,
            batteryStart: nil,
            includeMetadata: false,
            qualityScore: nil,
            gapAt: 14,
            rejectedPacketTimes: [8.4, 14.2, 22.1]
        )
    }

    private static func makeExample(
        title: String,
        notes: String,
        kind: ScaleKind,
        deviceName: String,
        advertisedServices: [String],
        duration: TimeInterval,
        sampleRate: Double,
        batteryStart: Int?,
        includeMetadata: Bool,
        qualityScore: Int?,
        gapAt: Double?,
        rejectedPacketTimes: [Double]
    ) -> Example {
        let startedAt = Date(timeIntervalSince1970: 1_785_600_000)
        let interval = 1 / sampleRate
        let sampleCount = Int(duration * sampleRate)
        var samples: [ScaleSample] = []
        var rawPackets: [RawScalePacket] = []
        var batteryEvents: [ScaleBatteryEvent] = []
        var sequence: UInt8 = 0

        for index in 0..<sampleCount {
            var seconds = Double(index) * interval
            if let gapAt, seconds > gapAt {
                seconds += 1.15
            }

            let progress = min(1, seconds / duration)
            let weight = shotWeight(progress: progress, seconds: seconds)
            let flow = shotFlow(progress: progress)
            let battery = batteryStart.map { max(0, $0 - Int(progress * 2)) }
            let status = includeMetadata ? ScaleStatusFlags(byte: 0xC3) : nil
            let diagnostics = includeMetadata ? ScaleDiagnosticFlags(byte: 0xF4) : nil

            let sample = ScaleSample(
                arrivalTime: startedAt.addingTimeInterval(seconds),
                monotonicSeconds: seconds,
                scaleKind: kind,
                weightGrams: weight,
                deviceTimestampMilliseconds: includeMetadata ? UInt32((seconds * 1_000).rounded()) & 0x00FF_FFFF : nil,
                sequence: includeMetadata ? sequence : nil,
                batteryPercent: battery,
                flowGramsPerSecond: includeMetadata ? flow : nil,
                firmwareQualityScore: qualityScore,
                detectedSampleRateHz: includeMetadata ? Int(sampleRate.rounded()) : nil,
                statusFlags: status,
                diagnosticFlags: diagnostics
            )
            samples.append(sample)

            rawPackets.append(
                RawScalePacket(
                    arrivalTime: sample.arrivalTime,
                    monotonicSeconds: sample.monotonicSeconds,
                    scaleKind: kind,
                    characteristicUUID: characteristicUUID(for: kind),
                    role: .weight,
                    bytesHex: packetHex(
                        kind: kind,
                        index: index,
                        weight: weight,
                        deviceTimestamp: sample.deviceTimestampMilliseconds,
                        sequence: sample.sequence,
                        battery: sample.batteryPercent,
                        flow: sample.flowGramsPerSecond,
                        quality: sample.firmwareQualityScore,
                        includeMetadata: includeMetadata
                    ),
                    rejectionReason: nil,
                    weightGrams: sample.weightGrams,
                    sequence: sample.sequence,
                    deviceTimestampMilliseconds: sample.deviceTimestampMilliseconds
                )
            )

            if includeMetadata, index.isMultiple(of: 80), let battery {
                let batteryTime = sample.monotonicSeconds + 0.003
                let batteryArrival = sample.arrivalTime.addingTimeInterval(0.003)
                batteryEvents.append(ScaleBatteryEvent(
                    arrivalTime: batteryArrival,
                    monotonicSeconds: batteryTime,
                    scaleKind: kind,
                    percent: battery
                ))
                rawPackets.append(
                    RawScalePacket(
                        arrivalTime: batteryArrival,
                        monotonicSeconds: batteryTime,
                        scaleKind: kind,
                        characteristicUUID: "2A19",
                        role: .battery,
                        bytesHex: String(format: "%02X", battery),
                        rejectionReason: nil
                    )
                )
            }

            sequence &+= 1
        }

        for (offset, rejectedTime) in rejectedPacketTimes.enumerated() {
            let rejectionReason: ParseRejectionReason = offset.isMultiple(of: 2) ? .invalidHeader : .invalidLength
            rawPackets.append(
                RawScalePacket(
                    arrivalTime: startedAt.addingTimeInterval(rejectedTime),
                    monotonicSeconds: rejectedTime,
                    scaleKind: kind,
                    characteristicUUID: characteristicUUID(for: kind),
                    role: .weight,
                    bytesHex: rejectedPacketHex(kind: kind, index: 9_000 + offset, reason: rejectionReason),
                    rejectionReason: rejectionReason
                )
            )
        }

        rawPackets.sort { $0.monotonicSeconds < $1.monotonicSeconds }

        var recording = ScaleRecording.empty(mode: .shot, scoringProfile: .standard)
        recording.id = deterministicRecordingID(title)
        recording.startedAt = startedAt
        recording.endedAt = startedAt.addingTimeInterval(rawPackets.last?.monotonicSeconds ?? duration)
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = duration + (gapAt == nil ? 0 : 1.15)
        recording.notes = notes
        recording.device = ScaleDeviceIdentity(
            name: deviceName,
            identifier: deterministicDeviceID(deviceName),
            kind: kind,
            advertisedServices: advertisedServices
        )
        recording.rawPackets = rawPackets
        recording.samples = samples
        recording.batteryEvents = batteryEvents
        recording.capabilities = includeMetadata ? WMBPlusCapabilities(
            payloadVersion: 1,
            protocolMajor: 1,
            protocolMinor: 0,
            featureMask: 0x0000_3105,
            preferredAtomicCommand: 0x07,
            preferredAtomicData1: 0x00,
            extensionPacketVersion: 1,
            extensionPacketLength: 20
        ) : nil
        recording.protocolCapabilities = ProtocolScoringCapabilities(
            hasChecksum: kind == .weighMyBru || kind == .weighMyBruPlus,
            hasSequence: includeMetadata,
            sequenceModulus: includeMetadata ? 256 : nil,
            hasDeviceClock: includeMetadata,
            deviceClockSemantics: includeMetadata ? .freeRunning : .none,
            deviceClockModulus: includeMetadata ? 1 << 24 : nil
        )
        recording.metrics = ScaleQualityAnalyzer.analyze(recording)

        return Example(title: title, notes: notes, recording: recording)
    }

    private static func shotWeight(progress: Double, seconds: Double) -> Double {
        let preinfusion = max(0, min(1, (progress - 0.10) / 0.18))
        let ramp = 1 / (1 + exp(-9 * (progress - 0.52)))
        let base = 38 * max(preinfusion * 0.35, ramp)
        let ripple = sin(seconds * 2.4) * 0.025 + sin(seconds * 0.67) * 0.018
        return max(0, base + ripple)
    }

    private static func shotFlow(progress: Double) -> Double {
        switch progress {
        case ..<0.12:
            return 0
        case ..<0.35:
            return 1.1 + progress * 3.2
        case ..<0.78:
            return 2.2 - (progress - 0.35) * 0.8
        default:
            return max(0.4, 1.5 - (progress - 0.78) * 3.2)
        }
    }

    private static func characteristicUUID(for kind: ScaleKind) -> String {
        switch kind {
        case .weighMyBru, .weighMyBruPlus:
            WeighMyBruParser.weight20UUID
        case .eureka:
            EurekaPrecisaParser.notifyUUID
        default:
            "SYNTHETIC"
        }
    }

    private static func packetHex(
        kind: ScaleKind,
        index: Int,
        weight: Double,
        deviceTimestamp: UInt32?,
        sequence: UInt8?,
        battery: Int?,
        flow: Double?,
        quality: Int?,
        includeMetadata: Bool
    ) -> String {
        Data(packetBytes(
            kind: kind,
            index: index,
            weight: weight,
            deviceTimestamp: deviceTimestamp,
            sequence: sequence,
            battery: battery,
            flow: flow,
            quality: quality,
            includeMetadata: includeMetadata
        )).hexString
    }

    private static func packetBytes(
        kind: ScaleKind,
        index: Int,
        weight: Double,
        deviceTimestamp: UInt32?,
        sequence: UInt8?,
        battery: Int?,
        flow: Double?,
        quality: Int?,
        includeMetadata: Bool
    ) -> [UInt8] {
        switch kind {
        case .weighMyBru, .weighMyBruPlus:
            var bytes = Array(repeating: UInt8(0), count: 20)
            bytes[0] = WeighMyBruParser.productNumber
            bytes[1] = WeighMyBruParser.weightMessageType
            let timestamp = (deviceTimestamp ?? UInt32(index * 100)) & 0x00FF_FFFF
            bytes[2] = UInt8((timestamp >> 16) & 0xFF)
            bytes[3] = UInt8((timestamp >> 8) & 0xFF)
            bytes[4] = UInt8(timestamp & 0xFF)
            bytes[5] = includeMetadata ? 1 : 0
            writeSignedCenti(weight, signIndex: 6, highIndex: 7, midIndex: 8, lowIndex: 9, into: &bytes)
            if includeMetadata {
                writeSignedCenti(flow ?? 0, signIndex: 10, highIndex: nil, midIndex: 11, lowIndex: 12, into: &bytes)
                bytes[13] = UInt8(clamping: battery ?? 0)
                bytes[14] = sequence ?? UInt8(truncatingIfNeeded: index)
                bytes[15] = 0xC3
                bytes[16] = UInt8(clamping: quality ?? 0)
                bytes[17] = 12
                bytes[18] = 0xF4
            }
            bytes[19] = xorChecksum(bytes.dropLast())
            return bytes
        case .eureka:
            var bytes = Array(repeating: UInt8(0), count: 11)
            bytes[0] = 0xAA
            bytes[1] = 0x09
            bytes[2] = 0x41
            bytes[6] = weight < 0 ? 1 : 0
            let magnitude = UInt16(clamping: Int((abs(weight) * 10).rounded()))
            bytes[7] = UInt8(magnitude & 0xFF)
            bytes[8] = UInt8((magnitude >> 8) & 0xFF)
            return bytes
        default:
            return [UInt8(index & 0xFF)]
        }
    }

    private static func rejectedPacketHex(kind: ScaleKind, index: Int, reason: ParseRejectionReason) -> String {
        var bytes = packetBytes(
            kind: kind,
            index: index,
            weight: 0,
            deviceTimestamp: nil,
            sequence: nil,
            battery: nil,
            flow: nil,
            quality: nil,
            includeMetadata: false
        )
        switch reason {
        case .invalidLength:
            if !bytes.isEmpty { bytes.removeLast() }
        default:
            if !bytes.isEmpty { bytes[0] ^= 0xFF }
        }
        return Data(bytes).hexString
    }

    private static func writeSignedCenti(
        _ value: Double,
        signIndex: Int,
        highIndex: Int?,
        midIndex: Int,
        lowIndex: Int,
        into bytes: inout [UInt8]
    ) {
        let magnitude = UInt32(clamping: Int((abs(value) * 100).rounded()))
        bytes[signIndex] = value < 0 ? 0x2D : 0x2B
        if let highIndex {
            bytes[highIndex] = UInt8((magnitude >> 16) & 0xFF)
        }
        bytes[midIndex] = UInt8((magnitude >> 8) & 0xFF)
        bytes[lowIndex] = UInt8(magnitude & 0xFF)
    }

    private static func deterministicRecordingID(_ title: String) -> UUID {
        switch title {
        case "Example · Clean WMB+ Pour":
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        case "Example · Legacy WMB Pour":
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        default:
            UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        }
    }

    private static func deterministicDeviceID(_ name: String) -> String {
        switch name {
        case "Example WMB+ Scale":
            "20000000-0000-0000-0000-000000000001"
        case "Example WeighMyBru":
            "20000000-0000-0000-0000-000000000002"
        default:
            "20000000-0000-0000-0000-000000000003"
        }
    }
}
