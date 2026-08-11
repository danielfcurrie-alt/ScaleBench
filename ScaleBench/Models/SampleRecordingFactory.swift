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
            let diagnostics = includeMetadata ? ScaleDiagnosticFlags(byte: 0xAC) : nil

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
                    bytesHex: packetHex(kind: kind, index: index, weight: weight, includeMetadata: includeMetadata),
                    rejectionReason: nil
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
            rawPackets.append(
                RawScalePacket(
                    arrivalTime: startedAt.addingTimeInterval(rejectedTime),
                    monotonicSeconds: rejectedTime,
                    scaleKind: kind,
                    characteristicUUID: characteristicUUID(for: kind),
                    role: .weight,
                    bytesHex: packetHex(kind: kind, index: 9_000 + offset, weight: 0, includeMetadata: false),
                    rejectionReason: offset.isMultiple(of: 2) ? .invalidChecksum : .invalidLength
                )
            )
        }

        rawPackets.sort { $0.monotonicSeconds < $1.monotonicSeconds }

        var recording = ScaleRecording.empty(mode: .shot, scoringProfile: .standard)
        recording.id = deterministicRecordingID(title)
        recording.startedAt = startedAt
        recording.endedAt = startedAt.addingTimeInterval(rawPackets.last?.monotonicSeconds ?? duration)
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

    private static func packetHex(kind: ScaleKind, index: Int, weight: Double, includeMetadata: Bool) -> String {
        let scaledWeight = Int16((weight * 100).rounded())
        var bytes: [UInt8] = [
            UInt8(index & 0xFF),
            UInt8((index >> 8) & 0xFF),
            UInt8(bitPattern: Int8(truncatingIfNeeded: scaledWeight & 0xFF)),
            UInt8(bitPattern: Int8(truncatingIfNeeded: (scaledWeight >> 8) & 0xFF))
        ]
        if includeMetadata {
            bytes.append(contentsOf: [0x2B, UInt8(index & 0xFF), 0x61, 0x0C])
        }
        switch kind {
        case .weighMyBruPlus:
            bytes.insert(contentsOf: [0x03, 0x0B], at: 0)
        case .weighMyBru:
            bytes.insert(contentsOf: [0x57, 0x4D, 0x42], at: 0)
        case .eureka:
            bytes.insert(contentsOf: [0xAA, 0x09, 0x41], at: 0)
        default:
            break
        }
        return Data(bytes).hexString
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

    private static func deterministicDeviceID(_ name: String) -> UUID {
        switch name {
        case "Example WMB+ Scale":
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        case "Example WeighMyBru":
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        default:
            UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        }
    }
}
