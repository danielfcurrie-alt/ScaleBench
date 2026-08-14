import Foundation

enum ScaleQualityAnalyzer {
    static let scoringModelVersion = ScaleRecording.scoringModelVersion

    private static let slotMilliseconds = 50.0
    private static let slotEpsilon = 1e-9
    private static let impulseDeviationGrams = 0.5
    private static let maxPhysicalFlowGramsPerSecond = 25.0
    private static let flowWindowSeconds = 1.0
    private static let minimumResolutionGrams = 0.01
    private static let minimumDuplicateToleranceGrams = 0.005
    private static let idleSettlingSeconds = 5.0
    private static let stepBaselineWindowSeconds = 2.0
    private static let stepFinalWindowSeconds = 2.0

    private enum FrameClass: String, CaseIterable {
        case usable
        case parseFailure
        case outOfOrder
        case stale
        case duplicate
        case implausible
    }

    private struct ScoringFrame {
        var packetID: UUID?
        var monotonicSeconds: Double
        var isWeight: Bool
        var parseFailed: Bool
        var weightGrams: Double?
        var sequence: UInt64?
        var deviceTimestampMilliseconds: UInt64?
        var diagnosticFlags: ScaleDiagnosticFlags?
        var usbDroppedDelta: UInt64
        var usbStatusLabels: [String]
    }

    private struct ClassifiedFrames {
        var frames: [ScoringFrame]
        var classes: [FrameClass]
        var resolutionGrams: Double
        var evidenceByPacketID: [UUID: [String]]
    }

    private struct CoverageResult {
        var coverage: Double
        var purity: Double
        var slotCount: Int
        var servedSlots: Int
        var longestUnservedRunMilliseconds: Double
    }

    private struct IdleResult {
        var score: Int?
        var noiseScore: Int?
        var driftScore: Int?
        var analysedSampleCount: Int
        var residualStandardDeviationGrams: Double?
        var residualPeakToPeakGrams: Double?
        var driftGramsPerMinute: Double?
        var resolutionGrams: Double?
    }

    static func analyze(_ recording: ScaleRecording, profile overrideProfile: ScoringProfile? = nil) -> ScaleQualityMetrics {
        let scoringProfile = (overrideProfile ?? recording.scoringProfile).normalized
        let allFrames = scoringFrames(recording)
        let explicitStart = recording.recordingStartMonotonicSeconds
        let explicitEnd = recording.recordingEndMonotonicSeconds
        let boundariesPresent = explicitStart != nil && explicitEnd != nil && explicitEnd! > explicitStart!
        let frameTimes = allFrames.map(\.monotonicSeconds)
        let recordingStart = explicitStart ?? frameTimes.min() ?? 0
        let recordingEnd = explicitEnd ?? frameTimes.max() ?? recordingStart
        let boundedFrames = allFrames.filter {
            $0.monotonicSeconds >= recordingStart && $0.monotonicSeconds < recordingEnd
        }
        let protocolCapabilities = recording.protocolCapabilities
            ?? inferredProtocolCapabilities(recording: recording, frames: boundedFrames)
        let classified = classifyFrames(
            boundedFrames,
            mode: recording.mode,
            capabilities: protocolCapabilities
        )
        let usbDroppedFrameCount = classified.frames.reduce(UInt64(0)) { $0 + $1.usbDroppedDelta }
        let usableSamples = zip(classified.frames, classified.classes).compactMap { frame, frameClass -> ScaleSample? in
            guard frameClass == .usable, let weight = frame.weightGrams else { return nil }
            return ScaleSample(
                arrivalTime: Date(timeIntervalSince1970: 0),
                monotonicSeconds: frame.monotonicSeconds,
                scaleKind: recording.device?.kind ?? .unknown,
                weightGrams: weight,
                deviceTimestampMilliseconds: frame.deviceTimestampMilliseconds.map(UInt32.init(truncatingIfNeeded:)),
                sequence: frame.sequence.map(UInt8.init(truncatingIfNeeded:)),
                batteryPercent: nil,
                flowGramsPerSecond: nil,
                firmwareQualityScore: nil,
                detectedSampleRateHz: nil,
                statusFlags: nil,
                diagnosticFlags: nil
            )
        }
        let validity = evaluateValidity(
            mode: recording.mode,
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            boundariesPresent: boundariesPresent,
            samples: usableSamples,
            events: recording.events
        )
        let coverage = coverageAndPurity(
            frames: classified.frames,
            classes: classified.classes,
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            additionalLostFrameCount: usbDroppedFrameCount
        )
        let frameCounts = frameClassification(classes: classified.classes)
        let relevantFrameCount = classified.frames.count
        let unreconstructable = relevantFrameCount > 0
            && Double(frameCounts.implausible) / Double(relevantFrameCount) > 0.30
        let isDeliveryMode = recording.mode == .shot || recording.mode == .transportStress
        let deliveryScore: Int? = {
            guard isDeliveryMode, validity.isValid, let coverage else { return nil }
            return clampedScore(100 * coverage.coverage * coverage.purity)
        }()
        let verification = protocolVerification(
            frames: boundedFrames,
            capabilities: protocolCapabilities,
            mode: recording.mode
        )

        let intervals = classified.frames.adjacentPairs().map {
            ($0.1.monotonicSeconds - $0.0.monotonicSeconds) * 1000
        }
        let sortedIntervals = intervals.sorted()
        let p25 = percentile(sortedIntervals, 0.25)
        let p50 = percentile(sortedIntervals, 0.50)
        let p75 = percentile(sortedIntervals, 0.75)
        let p95 = percentile(sortedIntervals, 0.95)
        let intervalMax = intervals.max()
        let recordingSpan = max(0, recordingEnd - recordingStart)
        let sampleSpan = usableSamplesSampleSpan(usableSamples)
        let idle = recording.mode == .idleStability
            ? idleStability(samples: usableSamples, recordingStart: recordingStart)
            : nil
        let idleScore = validity.isValid ? idle?.score : nil
        let step = recording.mode == .stepResponse
            ? stepResponse(samples: usableSamples, recordingStart: recordingStart, recordingEnd: recordingEnd)
            : nil
        let batteryValues = (
            recording.samples.compactMap(\.batteryPercent) + recording.batteryEvents.map(\.percent)
        ).filter { (0...100).contains($0) }
        let firmwareQuality = recording.samples.compactMap(\.firmwareQualityScore).filter { (0...100).contains($0) }
        let longGapThreshold = longGapThresholdMilliseconds(
            forTypicalIntervalMilliseconds: p50,
            profile: scoringProfile
        )
        let longGapCount = intervals.filter { $0 >= longGapThreshold }.count

        var metrics = ScaleQualityMetrics(
            overallScore: isDeliveryMode ? deliveryScore : idleScore,
            transportScore: isDeliveryMode ? deliveryScore : nil,
            stabilityScore: recording.mode == .idleStability ? idleScore : nil,
            metadataScore: verification.verificationCoveragePercent,
            effectiveSampleRateHz: sampleSpan > 0 ? Double(usableSamples.count) / sampleSpan : nil,
            packetIntervalP50Milliseconds: rounded6(p50),
            packetIntervalP95Milliseconds: rounded6(p95),
            packetIntervalMaxMilliseconds: rounded6(intervalMax),
            longGapCount: longGapCount,
            missingSequenceCount: max(
                missingSequenceCount(classified.frames, modulus: protocolCapabilities.sequenceModulus),
                Int(clamping: usbDroppedFrameCount)
            ),
            duplicateOrOutOfOrderTimestampCount: frameCounts.stale,
            rejectedPacketCount: frameCounts.parseFailure,
            idleNoisePeakToPeakGrams: idle?.residualPeakToPeakGrams,
            idleNoiseStandardDeviationGrams: idle?.residualStandardDeviationGrams,
            driftGramsPerMinute: idle?.driftGramsPerMinute,
            batteryMinPercent: batteryValues.min(),
            batteryMaxPercent: batteryValues.max(),
            firmwareQualityAverage: average(firmwareQuality),
            firmwareBumpCount: firmwareBumpEventCount(recording.samples)
        )
        metrics.scoringModelVersion = scoringModelVersion
        metrics.scoringProfileName = scoringProfile.name
        metrics.validity = validity
        metrics.delivery = DeliveryQualityMetrics(
            applicable: isDeliveryMode,
            deliveryScore: deliveryScore,
            coverage: isDeliveryMode ? rounded6(coverage?.coverage) : nil,
            purity: isDeliveryMode ? rounded6(coverage?.purity) : nil,
            purityIsUpperBound: isDeliveryMode ? verification.purityIsUpperBound : nil
        )
        metrics.frameClassification = frameCounts
        metrics.protocolVerification = verification
        metrics.signalUnreconstructable = unreconstructable
        metrics.relevantWeightFrameCount = relevantFrameCount
        metrics.excludedFrameCount = allFrames.count - relevantFrameCount
        metrics.usableSampleCount = usableSamples.count
        metrics.recordingSpanSeconds = rounded6(recordingSpan)
        metrics.recordingBoundaryInferred = !boundariesPresent
        metrics.frameRateHz = recordingSpan > 0 ? rounded6(Double(relevantFrameCount) / recordingSpan) : nil
        metrics.usableRateHz = sampleSpan > 0 ? rounded6(Double(usableSamples.count) / sampleSpan) : nil
        metrics.estimatedResolutionGrams = rounded6(classified.resolutionGrams)
        metrics.slotCount = coverage?.slotCount
        metrics.servedSlots = coverage?.servedSlots
        metrics.longestUnservedRunMilliseconds = rounded6(coverage?.longestUnservedRunMilliseconds)
        if let p25, let p50, let p75, p50 > 0 {
            metrics.robustCoefficientOfVariation = rounded6((p75 - p25) / p50)
        }
        metrics.disconnectCount = recording.events.filter { $0.type == .disconnect }.count
        metrics.idleNoiseScore = idle?.noiseScore
        metrics.idleDriftScore = idle?.driftScore
        metrics.idleAnalysedSampleCount = idle?.analysedSampleCount
        metrics.idleResolutionGrams = idle?.resolutionGrams
        metrics.stepResponse = step
        return metrics
    }

    static func packetEvidence(recording: ScaleRecording) -> [UUID: [String]] {
        let allFrames = scoringFrames(recording)
        let explicitStart = recording.recordingStartMonotonicSeconds
        let explicitEnd = recording.recordingEndMonotonicSeconds
        let frameTimes = allFrames.map(\.monotonicSeconds)
        let recordingStart = explicitStart ?? frameTimes.min() ?? 0
        let recordingEnd = explicitEnd ?? frameTimes.max() ?? recordingStart
        let boundedFrames = allFrames.filter {
            $0.monotonicSeconds >= recordingStart && $0.monotonicSeconds < recordingEnd
        }
        let protocolCapabilities = recording.protocolCapabilities
            ?? inferredProtocolCapabilities(recording: recording, frames: boundedFrames)
        return classifyFrames(
            boundedFrames,
            mode: recording.mode,
            capabilities: protocolCapabilities
        ).evidenceByPacketID
    }

    static func sampleIntervalsMilliseconds(_ samples: [ScaleSample]) -> [Double] {
        samples.adjacentPairs().map { max(0, $0.1.monotonicSeconds - $0.0.monotonicSeconds) * 1000 }
    }

    static func longGapThresholdMilliseconds(
        forTypicalIntervalMilliseconds typicalInterval: Double?,
        profile: ScoringProfile
    ) -> Double {
        guard let typicalInterval, typicalInterval > 0 else { return profile.minimumLongGapMilliseconds }
        return max(profile.minimumLongGapMilliseconds, typicalInterval * profile.longGapMultiplier)
    }

    private static func scoringFrames(_ recording: ScaleRecording) -> [ScoringFrame] {
        if !recording.rawPackets.isEmpty {
            let samplesByTime = samplesSortedByTime(recording.samples)
            let hasWMBPlus20WeightStream = hasWMBCompatibilityPair(recording)
            let frames = recording.rawPackets.map { packet in
                let sample = sample(matching: packet.monotonicSeconds, in: samplesByTime)
                let isCompatibilityFloat32 = hasWMBPlus20WeightStream
                    && isWMBFloat32Packet(packet)
                return ScoringFrame(
                    packetID: packet.id,
                    monotonicSeconds: packet.monotonicSeconds,
                    isWeight: packet.role == .weight && !isCompatibilityFloat32,
                    parseFailed: packet.role == .weight && !isCompatibilityFloat32 && packet.rejectionReason != nil,
                    weightGrams: packet.weightGrams ?? sample?.weightGrams,
                    sequence: packet.usbSerial.map { UInt64($0.sequenceNumber) }
                        ?? sample?.usbSerial.map { UInt64($0.sequenceNumber) }
                        ?? (packet.sequence ?? sample?.sequence).map(UInt64.init),
                    deviceTimestampMilliseconds: packet.usbSerial.map { UInt64($0.firmwareMillis) }
                        ?? sample?.usbSerial.map { UInt64($0.firmwareMillis) }
                        ?? (packet.deviceTimestampMilliseconds ?? sample?.deviceTimestampMilliseconds).map(UInt64.init),
                    diagnosticFlags: sample?.diagnosticFlags ?? diagnosticFlags(from: packet),
                    usbDroppedDelta: UInt64(packet.usbSerial?.usbDroppedDelta ?? sample?.usbSerial?.usbDroppedDelta ?? 0),
                    usbStatusLabels: packet.usbSerial?.usbStatusLabels ?? sample?.usbSerial?.usbStatusLabels ?? []
                )
            }
            return recording.source == .usbSerial ? deviceTimedUSBFrames(frames) : frames
        }
        let samples = canonicalWeightSamples(recording)
        let frames = samples.map {
            ScoringFrame(
                packetID: nil,
                monotonicSeconds: $0.monotonicSeconds,
                isWeight: true,
                parseFailed: false,
                weightGrams: $0.weightGrams,
                sequence: $0.usbSerial.map { UInt64($0.sequenceNumber) } ?? $0.sequence.map(UInt64.init),
                deviceTimestampMilliseconds: $0.usbSerial.map { UInt64($0.firmwareMillis) }
                    ?? $0.deviceTimestampMilliseconds.map(UInt64.init),
                diagnosticFlags: $0.diagnosticFlags,
                usbDroppedDelta: UInt64($0.usbSerial?.usbDroppedDelta ?? 0),
                usbStatusLabels: $0.usbSerial?.usbStatusLabels ?? []
            )
        }
        return recording.source == .usbSerial ? deviceTimedUSBFrames(frames) : frames
    }

    private static func deviceTimedUSBFrames(_ frames: [ScoringFrame]) -> [ScoringFrame] {
        guard let firstIndex = frames.firstIndex(where: { $0.deviceTimestampMilliseconds != nil }),
              let firstTimestamp = frames[firstIndex].deviceTimestampMilliseconds else {
            return frames
        }
        let modulus = UInt64(UInt32.max) + 1
        let anchor = frames[firstIndex].monotonicSeconds
        var previousTimestamp = firstTimestamp
        var elapsedMilliseconds: UInt64 = 0
        return frames.enumerated().map { index, input in
            var frame = input
            guard index >= firstIndex, let timestamp = input.deviceTimestampMilliseconds else { return frame }
            if index > firstIndex,
               let delta = forwardDelta(previous: previousTimestamp, current: timestamp, modulus: modulus) {
                elapsedMilliseconds &+= delta
                previousTimestamp = timestamp
            }
            frame.monotonicSeconds = anchor + Double(elapsedMilliseconds) / 1_000
            return frame
        }
    }

    static func canonicalWeightSamples(_ recording: ScaleRecording) -> [ScaleSample] {
        if hasWMBCompatibilityPair(recording) {
            let samplesByTime = samplesSortedByTime(recording.samples)
            let repaired = recording.rawPackets
                .filter { $0.role == .weight && isWMB20BytePacket($0) }
                .compactMap { packet -> ScaleSample? in
                    let sample = sample(matching: packet.monotonicSeconds, in: samplesByTime)
                    guard let weight = packet.weightGrams ?? sample?.weightGrams else { return nil }
                    return ScaleSample(
                        arrivalTime: packet.arrivalTime,
                        monotonicSeconds: packet.monotonicSeconds,
                        scaleKind: sample?.scaleKind ?? packet.scaleKind,
                        weightGrams: weight,
                        deviceTimestampMilliseconds: packet.deviceTimestampMilliseconds ?? sample?.deviceTimestampMilliseconds,
                        sequence: packet.sequence ?? sample?.sequence,
                        batteryPercent: sample?.batteryPercent,
                        flowGramsPerSecond: sample?.flowGramsPerSecond,
                        firmwareQualityScore: sample?.firmwareQualityScore,
                        detectedSampleRateHz: sample?.detectedSampleRateHz,
                        statusFlags: sample?.statusFlags,
                        diagnosticFlags: sample?.diagnosticFlags ?? diagnosticFlags(from: packet),
                        usbSerial: sample?.usbSerial ?? packet.usbSerial
                    )
                }
            if !repaired.isEmpty {
                return repaired
            }
        }
        let hasWMBPlusStream = recording.samples.contains { $0.scaleKind == .weighMyBruPlus }
            || recording.rawPackets.contains {
                $0.role == .weight
                    && isWMB20BytePacket($0)
                    && $0.scaleKind == .weighMyBruPlus
            }
        guard hasWMBPlusStream else { return recording.samples }
        return recording.samples.filter { $0.scaleKind != .weighMyBru }
    }

    private static func samplesSortedByTime(_ samples: [ScaleSample]) -> [ScaleSample] {
        samples
            .filter { $0.monotonicSeconds.isFinite }
            .sorted { $0.monotonicSeconds < $1.monotonicSeconds }
    }

    private static func sample(matching monotonicSeconds: Double, in sortedSamples: [ScaleSample]) -> ScaleSample? {
        guard monotonicSeconds.isFinite, !sortedSamples.isEmpty else { return nil }
        let tolerance = 0.001
        var low = 0
        var high = sortedSamples.count
        while low < high {
            let mid = (low + high) / 2
            if sortedSamples[mid].monotonicSeconds < monotonicSeconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var best: ScaleSample?
        var bestDelta = Double.greatestFiniteMagnitude
        for index in [low - 1, low] where sortedSamples.indices.contains(index) {
            let delta = abs(sortedSamples[index].monotonicSeconds - monotonicSeconds)
            if delta < bestDelta {
                best = sortedSamples[index]
                bestDelta = delta
            }
        }
        return bestDelta <= tolerance ? best : nil
    }

    private static func hasWMBCompatibilityPair(_ recording: ScaleRecording) -> Bool {
        var has20ByteWeight = false
        var hasFloat32Weight = false
        for packet in recording.rawPackets where packet.role == .weight {
            if isWMB20BytePacket(packet) {
                has20ByteWeight = true
            } else if isWMBFloat32Packet(packet) {
                hasFloat32Weight = true
            }
            if has20ByteWeight && hasFloat32Weight {
                return true
            }
        }
        return false
    }

    private static func isWMB20BytePacket(_ packet: RawScalePacket) -> Bool {
        packet.characteristicUUID.uppercased() == WeighMyBruParser.weight20UUID
    }

    private static func isWMBFloat32Packet(_ packet: RawScalePacket) -> Bool {
        packet.characteristicUUID.uppercased() == WeighMyBruParser.float32UUID
    }

    private static func inferredProtocolCapabilities(
        recording: ScaleRecording,
        frames: [ScoringFrame]
    ) -> ProtocolScoringCapabilities {
        let kind = recording.device?.kind ?? recording.samples.last?.scaleKind ?? .unknown
        let hasSequence = frames.contains { $0.sequence != nil }
        let hasClock = frames.contains { $0.deviceTimestampMilliseconds != nil }
        let semantics: DeviceClockSemantics = {
            switch kind {
            case .decent, .espressi: return .shotTimer
            default: return hasClock ? .freeRunning : .none
            }
        }()
        let clockModulus: UInt64? = {
            if recording.source == .usbSerial { return UInt64(UInt32.max) + 1 }
            switch kind {
            case .bookoo, .bookooMini, .bookooUltra, .weighMyBruPlus: return 1 << 24
            case .difluid, .difluidTi: return 1 << 32
            default: return nil
            }
        }()
        let hasChecksum: Bool = {
            switch kind {
            case .bookoo, .bookooMini, .bookooUltra, .weighMyBruPlus, .acaia, .difluid, .difluidTi, .timemoreDot:
                return true
            case .weighMyBru:
                return recording.rawPackets.contains { $0.characteristicUUID.uppercased().contains("6E400002") }
            default:
                return false
            }
        }()
        return ProtocolScoringCapabilities(
            hasChecksum: hasChecksum,
            hasSequence: hasSequence,
            sequenceModulus: hasSequence
                ? (recording.source == .usbSerial ? UInt64(UInt32.max) + 1 : 256)
                : nil,
            hasDeviceClock: hasClock,
            deviceClockSemantics: semantics,
            deviceClockModulus: clockModulus
        )
    }

    private static func classifyFrames(
        _ allFrames: [ScoringFrame],
        mode: RecordingMode,
        capabilities: ProtocolScoringCapabilities
    ) -> ClassifiedFrames {
        let frames = allFrames.filter(\.isWeight)
        let parsedWeights = frames.compactMap { frame -> Double? in
            guard !frame.parseFailed, let weight = frame.weightGrams, weight.isFinite else { return nil }
            return weight
        }
        let resolution = estimateResolution(parsedWeights)
        var classes = Array<FrameClass?>(repeating: nil, count: frames.count)
        var evidenceByPacketID: [UUID: [String]] = [:]
        var lastUsableIndex: Int?
        var usableIndices: [Int] = []
        var sequenceHighWater: UInt64?
        var clockHighWater: UInt64?
        let sequenceModulus = capabilities.sequenceModulus ?? 256
        let verifiesFreshness = capabilities.hasDeviceClock
            && capabilities.deviceClockSemantics == .freeRunning
        let checksImpulse = mode == .shot || mode == .idleStability
        let checksPhysicalRate = mode == .idleStability
        let checksDuplicates = mode == .shot
        func usableBaseIndex(atLeast seconds: Double) -> Int? {
            var low = 0
            var high = usableIndices.count
            while low < high {
                let mid = (low + high) / 2
                if frames[usableIndices[mid]].monotonicSeconds <= seconds {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            guard low > 0 else { return nil }
            return usableIndices[low - 1]
        }

        for index in frames.indices {
            let frame = frames[index]
            guard !frame.parseFailed, let weight = frame.weightGrams, weight.isFinite else {
                classes[index] = .parseFailure
                addEvidence("Unreadable packet: parser rejected this weight frame.", frame: frame, into: &evidenceByPacketID)
                continue
            }
            if frame.usbDroppedDelta > 0 {
                addEvidence(
                    "USB backpressure: device reported \(frame.usbDroppedDelta) skipped frame\(frame.usbDroppedDelta == 1 ? "" : "s") before this sample.",
                    frame: frame,
                    into: &evidenceByPacketID
                )
            }
            if frame.usbStatusLabels.contains("Recent bump") {
                addEvidence(
                    "Firmware diagnostic: recent bump. The sample remains usable unless its weight is independently implausible.",
                    frame: frame,
                    into: &evidenceByPacketID
                )
            }
            if frame.usbStatusLabels.contains("Recent glitch") {
                addEvidence(
                    "Firmware diagnostic: recent glitch. The sample remains usable unless another check rejects it.",
                    frame: frame,
                    into: &evidenceByPacketID
                )
            }
            if let sequence = frame.sequence, let sequenceHighWater,
               forwardDelta(previous: sequenceHighWater, current: sequence, modulus: sequenceModulus) == nil {
                classes[index] = .outOfOrder
                addEvidence("Out of order: sequence moved backward or repeated.", frame: frame, into: &evidenceByPacketID)
                continue
            }
            if verifiesFreshness,
               let clock = frame.deviceTimestampMilliseconds,
               let clockHighWater,
               forwardDelta(
                   previous: clockHighWater,
                   current: clock,
                   modulus: capabilities.deviceClockModulus
               ) == nil {
                classes[index] = .stale
                addEvidence("Stale reading: device clock did not advance.", frame: frame, into: &evidenceByPacketID)
                continue
            }

            if let sequence = frame.sequence { sequenceHighWater = sequence }
            if verifiesFreshness, let clock = frame.deviceTimestampMilliseconds { clockHighWater = clock }

            var implausible = false
            if checksImpulse, index > 0, index < frames.count - 1,
               let previousWeight = parseableWeight(frames[index - 1]),
               let nextWeight = parseableWeight(frames[index + 1]) {
                let deviation = abs(weight - median3(previousWeight, weight, nextWeight))
                if deviation > impulseDeviationGrams {
                    implausible = true
                    addEvidence(
                        String(format: "Implausible reading: isolated %.2f g spike; limit is %.2f g.", deviation, impulseDeviationGrams),
                        frame: frame,
                        into: &evidenceByPacketID
                    )
                    addFirmwareBumpEvidenceIfPresent(frame: frame, into: &evidenceByPacketID)
                }
            }
            if checksPhysicalRate, let lastUsableIndex {
                let previous = frames[lastUsableIndex]
                let deltaSeconds = frame.monotonicSeconds - previous.monotonicSeconds
                if deltaSeconds > 0, let previousWeight = previous.weightGrams {
                    let flowRate = abs(weight - previousWeight) / deltaSeconds
                    if flowRate > maxPhysicalFlowGramsPerSecond {
                        implausible = true
                        addEvidence(
                            String(format: "Implausible reading: %.1f g/s jump; limit is %.1f g/s.", flowRate, maxPhysicalFlowGramsPerSecond),
                            frame: frame,
                            into: &evidenceByPacketID
                        )
                        addFirmwareBumpEvidenceIfPresent(frame: frame, into: &evidenceByPacketID)
                    }
                }
            }
            if implausible {
                classes[index] = .implausible
                continue
            }

            if checksDuplicates, let lastUsableIndex,
               let previousWeight = frames[lastUsableIndex].weightGrams,
               abs(weight - previousWeight) <= duplicateTolerance(forResolution: resolution) {
                let deltaSeconds = frame.monotonicSeconds - frames[lastUsableIndex].monotonicSeconds
                if let baseIndex = usableBaseIndex(atLeast: frame.monotonicSeconds - flowWindowSeconds),
                   let baseWeight = frames[baseIndex].weightGrams,
                   deltaSeconds > 0 {
                    let span = frame.monotonicSeconds - frames[baseIndex].monotonicSeconds
                    if span > 0 {
                        let flow = abs(weight - baseWeight) / span
                        if flow * deltaSeconds >= resolution {
                            classes[index] = .duplicate
                            addEvidence("Repeated reading: same weight repeated while nearby samples showed motion.", frame: frame, into: &evidenceByPacketID)
                            continue
                        }
                    }
                }
            }

            classes[index] = .usable
            lastUsableIndex = index
            usableIndices.append(index)
        }

        return ClassifiedFrames(
            frames: frames,
            classes: classes.map { $0 ?? .parseFailure },
            resolutionGrams: resolution,
            evidenceByPacketID: evidenceByPacketID
        )
    }

    private static func addEvidence(
        _ message: String,
        frame: ScoringFrame,
        into evidenceByPacketID: inout [UUID: [String]]
    ) {
        guard let packetID = frame.packetID else { return }
        evidenceByPacketID[packetID, default: []].append(message)
    }

    private static func addFirmwareBumpEvidenceIfPresent(
        frame: ScoringFrame,
        into evidenceByPacketID: inout [UUID: [String]]
    ) {
        guard frame.diagnosticFlags?.recentBump == true else { return }
        addEvidence(
            "Firmware flag: recent bump. The scale also marked this frame as physically disturbed.",
            frame: frame,
            into: &evidenceByPacketID
        )
    }

    private static func diagnosticFlags(from packet: RawScalePacket) -> ScaleDiagnosticFlags? {
        guard packet.scaleKind == .weighMyBruPlus,
              packet.characteristicUUID.uppercased() == WeighMyBruParser.weight20UUID,
              let bytes = PacketFieldDecoder.bytes(fromHex: packet.bytesHex),
              bytes.count > 18 else {
            return nil
        }
        return ScaleDiagnosticFlags(byte: bytes[18])
    }

    private static func parseableWeight(_ frame: ScoringFrame) -> Double? {
        guard !frame.parseFailed, let weight = frame.weightGrams, weight.isFinite else { return nil }
        return weight
    }

    private static func duplicateTolerance(forResolution resolution: Double) -> Double {
        max(minimumDuplicateToleranceGrams, resolution * 0.25)
    }

    private static func estimateResolution(_ weights: [Double]) -> Double {
        let nonzero = weights.adjacentPairs()
            .map { abs($0.1 - $0.0) }
            .filter { $0 > 0 && $0.isFinite }
            .sorted()
        return max(minimumResolutionGrams, percentile(nonzero, 0.10) ?? minimumResolutionGrams)
    }

    private static func forwardDelta(previous: UInt64, current: UInt64, modulus: UInt64?) -> UInt64? {
        if let modulus, modulus > 0 {
            let delta = (current &+ modulus &- (previous % modulus)) % modulus
            return delta > 0 && Double(delta) <= Double(modulus) / 2 ? delta : nil
        }
        return current > previous ? current - previous : nil
    }

    private static func coverageAndPurity(
        frames: [ScoringFrame],
        classes: [FrameClass],
        recordingStart: Double,
        recordingEnd: Double,
        additionalLostFrameCount: UInt64 = 0
    ) -> CoverageResult? {
        guard !frames.isEmpty else { return nil }
        let spanMilliseconds = (recordingEnd - recordingStart) * 1000
        guard spanMilliseconds > 0 else { return nil }
        let slotCount = Int(floor(spanMilliseconds / slotMilliseconds + slotEpsilon))
        guard slotCount > 0 else { return nil }
        let usableCount = classes.filter { $0 == .usable }.count
        var served = Array(repeating: false, count: slotCount)
        for (frame, frameClass) in zip(frames, classes) where frameClass == .usable {
            let offset = frame.monotonicSeconds - recordingStart
            guard offset >= 0, offset * 1000 < Double(slotCount) * slotMilliseconds else { continue }
            let rawIndex = Int(floor(offset * 1000 / slotMilliseconds + slotEpsilon))
            served[min(max(rawIndex, 0), slotCount - 1)] = true
        }
        var longestRun = 0
        var run = 0
        for isServed in served {
            run = isServed ? 0 : run + 1
            longestRun = max(longestRun, run)
        }
        let servedCount = served.filter { $0 }.count
        return CoverageResult(
            coverage: Double(servedCount) / Double(slotCount),
            purity: Double(usableCount) / Double(frames.count + Int(clamping: additionalLostFrameCount)),
            slotCount: slotCount,
            servedSlots: servedCount,
            longestUnservedRunMilliseconds: Double(longestRun) * slotMilliseconds
        )
    }

    private static func frameClassification(classes: [FrameClass]) -> FrameClassificationMetrics {
        FrameClassificationMetrics(
            usable: classes.filter { $0 == .usable }.count,
            parseFailure: classes.filter { $0 == .parseFailure }.count,
            outOfOrder: classes.filter { $0 == .outOfOrder }.count,
            stale: classes.filter { $0 == .stale }.count,
            duplicate: classes.filter { $0 == .duplicate }.count,
            implausible: classes.filter { $0 == .implausible }.count
        )
    }

    private static func protocolVerification(
        frames: [ScoringFrame],
        capabilities: ProtocolScoringCapabilities,
        mode: RecordingMode
    ) -> ProtocolVerificationMetrics {
        let hasSequence = capabilities.hasSequence || frames.contains { $0.sequence != nil }
        let hasClock = capabilities.hasDeviceClock || frames.contains { $0.deviceTimestampMilliseconds != nil }
        let checksImplausible = mode == .shot || mode == .idleStability
        let checksDuplicates = mode == .shot
        let verifiability = [
            "parseFailure": capabilities.hasChecksum,
            "outOfOrder": hasSequence,
            "stale": hasClock && capabilities.deviceClockSemantics == .freeRunning,
            "duplicate": checksDuplicates,
            "implausible": checksImplausible
        ]
        let verifiable = verifiability.compactMap { $0.value ? $0.key : nil }.sorted()
        let unverifiable = verifiability.compactMap { $0.value ? nil : $0.key }.sorted()
        return ProtocolVerificationMetrics(
            verifiableClasses: verifiable,
            unverifiableClasses: unverifiable,
            verificationCoveragePercent: roundHalfAwayFromZero(100 * Double(verifiable.count) / 5),
            purityIsUpperBound: verifiable.count < 5
        )
    }

    private static func evaluateValidity(
        mode: RecordingMode,
        recordingStart: Double,
        recordingEnd: Double,
        boundariesPresent: Bool,
        samples: [ScaleSample],
        events: [ScaleRecordingEvent]
    ) -> ScoringValidity {
        let gate: (minimumSeconds: Double, minimumUsable: Int, disconnectInvalidates: Bool)
        switch mode {
        case .shot: gate = (20, 2, true)
        case .transportStress: gate = (120, 2, false)
        case .idleStability: gate = (60, 100, true)
        case .stepResponse: gate = (10, 30, true)
        case .tareLatency: gate = (5, 10, true)
        case .batteryStability: gate = (60, 0, true)
        }
        var reasons: [String] = []
        if !boundariesPresent { reasons.append("recordingBoundariesMissing") }
        if max(0, recordingEnd - recordingStart) < gate.minimumSeconds {
            reasons.append("durationBelowMinimum")
        }
        if samples.count < gate.minimumUsable {
            reasons.append("usableFrameCountBelowMinimum")
        }
        if mode == .idleStability {
            let analysed = samples.filter { $0.monotonicSeconds - recordingStart >= idleSettlingSeconds }
            if analysed.count < gate.minimumUsable {
                reasons.append("idleAnalysedFrameCountBelowMinimum")
            }
        }
        if mode == .stepResponse {
            let baselineCount = samples.filter {
                $0.monotonicSeconds >= recordingStart
                    && $0.monotonicSeconds <= recordingStart + stepBaselineWindowSeconds
            }.count
            let finalCount = samples.filter {
                $0.monotonicSeconds >= recordingEnd - stepFinalWindowSeconds
                    && $0.monotonicSeconds < recordingEnd
            }.count
            if baselineCount < 5 { reasons.append("stepBaselineFrameCountBelowMinimum") }
            if finalCount < 5 { reasons.append("stepFinalFrameCountBelowMinimum") }
        }
        if gate.disconnectInvalidates && events.contains(where: { $0.type == .disconnect }) {
            reasons.append("disconnectDuringRecording")
        }
        if events.contains(where: { $0.type == .appBackgrounded }) {
            reasons.append("appLeftForeground")
        }
        return ScoringValidity(isValid: reasons.isEmpty, reasons: reasons)
    }

    private static func idleStability(samples: [ScaleSample], recordingStart: Double) -> IdleResult? {
        let window = samples.filter { $0.monotonicSeconds - recordingStart >= idleSettlingSeconds }
        guard window.count >= 2 else { return nil }
        let base = window[0].monotonicSeconds
        let xs = window.map { $0.monotonicSeconds - base }
        let ys = window.map(\.weightGrams)
        guard let (slope, intercept) = olsSlopeIntercept(xs: xs, ys: ys) else { return nil }
        let drift = slope * 60
        let residuals = zip(xs, ys).map { x, y in y - (intercept + slope * x) }
        let residualStandardDeviation = sampleStandardDeviation(residuals)
        let sortedResiduals = residuals.sorted()
        let residualPeakToPeak = percentile(sortedResiduals, 0.995).flatMap { upper in
            percentile(sortedResiduals, 0.005).map { upper - $0 }
        }
        let nonzeroDeltas = ys.adjacentPairs().map { abs($0.1 - $0.0) }.filter { $0 > 0 }
        let resolution = nonzeroDeltas.min()
        let noise = residualStandardDeviation.map {
            100 * clamp01((0.20 - $0) / (0.20 - 0.02))
        }
        let driftComponent = 100 * clamp01((1.00 - abs(drift)) / (1.00 - 0.05))
        let score = noise.map {
            clampedScore(exp(0.5 * log(floored($0)) + 0.5 * log(floored(driftComponent))))
        }
        return IdleResult(
            score: score,
            noiseScore: noise.map(roundHalfAwayFromZero),
            driftScore: roundHalfAwayFromZero(driftComponent),
            analysedSampleCount: window.count,
            residualStandardDeviationGrams: rounded6(residualStandardDeviation),
            residualPeakToPeakGrams: rounded6(residualPeakToPeak),
            driftGramsPerMinute: rounded6(drift),
            resolutionGrams: rounded6(resolution)
        )
    }

    private static func stepResponse(
        samples: [ScaleSample],
        recordingStart: Double,
        recordingEnd: Double
    ) -> StepResponseMetrics {
        guard samples.count >= 3 else { return StepResponseMetrics(stepDetected: false) }
        let baselineValues = samples.filter {
            $0.monotonicSeconds >= recordingStart
                && $0.monotonicSeconds <= recordingStart + stepBaselineWindowSeconds
        }.map(\.weightGrams).sorted()
        let finalValues = samples.filter {
            $0.monotonicSeconds >= recordingEnd - stepFinalWindowSeconds
                && $0.monotonicSeconds < recordingEnd
        }.map(\.weightGrams).sorted()
        guard let baseline = percentile(baselineValues, 0.5),
              let final = percentile(finalValues, 0.5),
              final - baseline >= 5 else {
            return StepResponseMetrics(stepDetected: false)
        }
        let amplitude = final - baseline
        func firstTime(atOrAbove level: Double) -> Double? {
            samples.first { $0.weightGrams >= level }?.monotonicSeconds
        }
        guard let onset = firstTime(atOrAbove: baseline + 0.05 * amplitude) else {
            return StepResponseMetrics(stepDetected: false)
        }
        let t10 = firstTime(atOrAbove: baseline + 0.10 * amplitude)
        let t90 = firstTime(atOrAbove: baseline + 0.90 * amplitude)
        var settledAt: Double?
        for index in samples.indices where samples[index].monotonicSeconds >= onset {
            guard abs(samples[index].weightGrams - final) <= 0.1 else { continue }
            let holdEnd = samples[index].monotonicSeconds + 1
            var previousTime = samples[index].monotonicSeconds
            var held = true
            var observedThroughHold = false
            for candidate in samples[index...] {
                if candidate.monotonicSeconds - previousTime > 0.25
                    || abs(candidate.weightGrams - final) > 0.1 {
                    held = false
                    break
                }
                if candidate.monotonicSeconds >= holdEnd {
                    observedThroughHold = true
                    break
                }
                previousTime = candidate.monotonicSeconds
            }
            if held && observedThroughHold {
                settledAt = samples[index].monotonicSeconds
                break
            }
        }
        let peak = samples.filter { $0.monotonicSeconds >= onset }.map(\.weightGrams).max() ?? final
        let overshoot = peak > final ? (peak - final) / amplitude * 100 : 0
        return StepResponseMetrics(
            stepDetected: true,
            onsetSecondsFromRecordingStart: rounded6(onset - recordingStart),
            baselineGrams: rounded6(baseline),
            finalGrams: rounded6(final),
            amplitudeGrams: rounded6(amplitude),
            riseTime10To90Seconds: t10.flatMap { low in t90.map { rounded6($0 - low)! } },
            settlingTimeSeconds: settledAt.map { rounded6($0 - onset)! },
            overshootPercent: rounded6(overshoot)
        )
    }

    private static func missingSequenceCount(_ frames: [ScoringFrame], modulus: UInt64?) -> Int {
        var count = 0
        var acceptedHighWater: UInt64?
        for frame in frames {
            guard let current = frame.sequence else { continue }
            if let previous = acceptedHighWater {
                guard let delta = forwardDelta(previous: previous, current: current, modulus: modulus) else { continue }
                if delta > 1 { count += Int(delta - 1) }
            }
            acceptedHighWater = current
        }
        return count
    }

    private static func firmwareBumpEventCount(_ samples: [ScaleSample]) -> Int {
        var count = 0
        var active = false
        for sample in samples {
            let hasBump = sample.diagnosticFlags?.recentBump == true
            if hasBump && !active { count += 1 }
            active = hasBump
        }
        return count
    }

    private static func usableSamplesSampleSpan(_ samples: [ScaleSample]) -> Double {
        guard let first = samples.first?.monotonicSeconds,
              let last = samples.last?.monotonicSeconds else { return 0 }
        return max(0, last - first)
    }

    private static func percentile(_ sortedValues: [Double], _ probability: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        guard sortedValues.count > 1 else { return sortedValues[0] }
        let position = Double(sortedValues.count - 1) * probability
        let lower = Int(floor(position))
        guard lower + 1 < sortedValues.count else { return sortedValues.last }
        return sortedValues[lower] + (position - Double(lower)) * (sortedValues[lower + 1] - sortedValues[lower])
    }

    private static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func olsSlopeIntercept(xs: [Double], ys: [Double]) -> (Double, Double)? {
        guard xs.count >= 2, xs.count == ys.count else { return nil }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let sumXX = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        guard sumXX > 0 else { return nil }
        let sumXY = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let slope = sumXY / sumXX
        return (slope, meanY - slope * meanX)
    }

    private static func median3(_ a: Double, _ b: Double, _ c: Double) -> Double {
        [a, b, c].sorted()[1]
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func floored(_ score: Double) -> Double {
        5 + 0.95 * score
    }

    private static func roundHalfAwayFromZero(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrAwayFromZero))
    }

    private static func clampedScore(_ value: Double) -> Int {
        min(100, max(0, roundHalfAwayFromZero(value)))
    }

    private static func rounded6(_ value: Double?) -> Double? {
        value.map { ($0 * 1_000_000).rounded(.toNearestOrAwayFromZero) / 1_000_000 }
    }

    private static func average(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count >= 2 else { return [] }
        return zip(self, dropFirst()).map { ($0, $1) }
    }
}
