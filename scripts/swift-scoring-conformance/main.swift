import Foundation

private struct VectorIndex: Decodable {
    struct Entry: Decodable { let vectorId: String }
    let scoringModelVersion: String
    let vectors: [Entry]
}

private struct VectorInput: Decodable {
    struct Frame: Decodable {
        let monotonicSeconds: Double
        let kind: String?
        let weightGrams: Double?
        let parseFailed: Bool?
        let sequence: UInt64?
        let deviceTimestampMs: UInt64?
        let flowGramsPerSecond: Double?
    }

    struct Event: Decodable {
        let type: String
        let monotonicSeconds: Double
    }

    struct Capabilities: Decodable {
        let hasChecksum: Bool?
        let hasSequence: Bool?
        let sequenceModulus: UInt64?
        let hasDeviceClock: Bool?
        let deviceClockSemantics: String?
        let deviceClockModulus: UInt64?
    }

    let mode: String
    let deviceKind: String?
    let recordingStartMonotonicSeconds: Double?
    let recordingEndMonotonicSeconds: Double?
    let frames: [Frame]
    let events: [Event]?
    let protocolCapabilities: Capabilities?
}

private struct ExpectedResult: Decodable {
    struct Validity: Decodable {
        let isValid: Bool
        let reasons: [String]
    }

    struct Delivery: Decodable {
        let applicable: Bool
        let deliveryScore: Int?
        let coverage: Double?
        let purity: Double?
        let purityIsUpperBound: Bool?
    }

    struct FrameClassification: Decodable {
        let usable: Int
        let parseFailure: Int
        let outOfOrder: Int
        let stale: Int
        let duplicate: Int
        let implausible: Int
    }

    struct Verification: Decodable {
        let verifiableClasses: [String]
        let unverifiableClasses: [String]
        let verificationCoveragePercent: Int
        let purityIsUpperBound: Bool
    }

    struct Diagnostics: Decodable {
        let relevantWeightFrames: Int
        let excludedFrames: Int
        let usableSampleCount: Int
        let spanSeconds: Double
        let recordingBoundaryInferred: Bool
        let frameRateHz: Double?
        let usableRateHz: Double?
        let estimatedResolutionGrams: Double?
        let slotCount: Int?
        let servedSlots: Int?
        let longestUnservedRunMs: Double?
        let intervalP50Ms: Double?
        let robustCoefficientOfVariation: Double?
        let intervalMaxMs: Double?
        let disconnectCount: Int
    }

    struct Idle: Decodable {
        let idleStabilityScore: Int?
        let noiseScore: Int?
        let driftScore: Int?
        let analysedSampleCount: Int
        let residualStandardDeviationGrams: Double?
        let residualPeakToPeakGrams: Double?
        let driftGramsPerMinute: Double?
        let resolutionGrams: Double?
    }

    struct Step: Decodable {
        let stepDetected: Bool
        let onsetSecondsFromRecordingStart: Double?
        let baselineGrams: Double?
        let finalGrams: Double?
        let amplitudeGrams: Double?
        let riseTime10To90Seconds: Double?
        let settlingTimeSeconds: Double?
        let overshootPercent: Double?
    }

    struct SignalDiagnostics: Decodable {
        struct FlowValidation: Decodable {
            let sampleCount: Int
            let medianAbsoluteErrorGramsPerSecond: Double
            let lagMilliseconds: Double?
            let correlation: Double?
        }

        struct ClockSkew: Decodable {
            let sampleCount: Int
            let skewPartsPerMillion: Double
        }

        struct PacketCoalescing: Decodable {
            let observedFrameRateHz: Double
            let servedSlotRateHz: Double
            let framesPerServedSlot: Double
        }

        let flowValidation: FlowValidation?
        let clockSkew: ClockSkew?
        let packetCoalescing: PacketCoalescing?
    }

    let scoringModelVersion: String
    let scoringProfileName: String
    let validity: Validity
    let delivery: Delivery
    let frameClassification: FrameClassification
    let protocolVerification: Verification
    let signalUnreconstructable: Bool
    let diagnostics: Diagnostics
    let signalDiagnostics: SignalDiagnostics
    let idle: Idle?
    let stepResponse: Step?
}

private var failures: [String] = []

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ path: String) {
    if actual != expected { failures.append("\(path): expected \(expected), got \(actual)") }
}

private func expectDouble(_ actual: Double?, _ expected: Double?, _ path: String) {
    switch (actual, expected) {
    case (nil, nil): return
    case let (.some(actual), .some(expected)) where abs(actual - expected) <= 1e-6: return
    default: failures.append("\(path): expected \(String(describing: expected)), got \(String(describing: actual))")
    }
}

private func recording(from input: VectorInput) throws -> ScaleRecording {
    guard let mode = RecordingMode(rawValue: input.mode) else {
        throw NSError(domain: "ScaleBenchConformance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown mode \(input.mode)"])
    }

    let scaleKind = input.deviceKind.flatMap(ScaleKind.init(rawValue:)) ?? .unknown
    let packets = input.frames.map { frame -> RawScalePacket in
        let role: PacketRole = switch frame.kind ?? "weight" {
        case "weight": .weight
        case "battery": .battery
        case "capability": .capabilities
        default: .unknown
        }
        return RawScalePacket(
            arrivalTime: Date(timeIntervalSince1970: frame.monotonicSeconds),
            monotonicSeconds: frame.monotonicSeconds,
            scaleKind: scaleKind,
            characteristicUUID: "VECTOR",
            role: role,
            bytesHex: "",
            rejectionReason: frame.parseFailed == true ? .invalidChecksum : nil,
            weightGrams: frame.weightGrams,
            sequence: frame.sequence.map(UInt8.init(truncatingIfNeeded:)),
            deviceTimestampMilliseconds: frame.deviceTimestampMs.map(UInt32.init(truncatingIfNeeded:))
        )
    }

    let samples = input.frames.compactMap { frame -> ScaleSample? in
        guard (frame.kind ?? "weight") == "weight",
              frame.parseFailed != true,
              let weightGrams = frame.weightGrams else {
            return nil
        }
        return ScaleSample(
            arrivalTime: Date(timeIntervalSince1970: frame.monotonicSeconds),
            monotonicSeconds: frame.monotonicSeconds,
            scaleKind: scaleKind,
            weightGrams: weightGrams,
            deviceTimestampMilliseconds: frame.deviceTimestampMs.map(UInt32.init(truncatingIfNeeded:)),
            sequence: frame.sequence.map(UInt8.init(truncatingIfNeeded:)),
            batteryPercent: nil,
            flowGramsPerSecond: frame.flowGramsPerSecond,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: nil
        )
    }

    let events = (input.events ?? []).compactMap { event -> ScaleRecordingEvent? in
        guard let type = ScaleRecordingEventType(rawValue: event.type) else { return nil }
        return ScaleRecordingEvent(type: type, monotonicSeconds: event.monotonicSeconds)
    }

    let protocolCapabilities = input.protocolCapabilities.map { capabilities in
        let hasClockInFrames = input.frames.contains { $0.deviceTimestampMs != nil }
        let hasClock = capabilities.hasDeviceClock ?? hasClockInFrames
        let semantics = DeviceClockSemantics(rawValue: capabilities.deviceClockSemantics ?? "")
            ?? (hasClock ? .freeRunning : .none)
        return ProtocolScoringCapabilities(
            hasChecksum: capabilities.hasChecksum ?? false,
            hasSequence: capabilities.hasSequence ?? input.frames.contains { $0.sequence != nil },
            sequenceModulus: capabilities.sequenceModulus,
            hasDeviceClock: hasClock,
            deviceClockSemantics: semantics,
            deviceClockModulus: capabilities.deviceClockModulus
        )
    }

    return ScaleRecording(
        mode: mode,
        device: input.deviceKind.map { _ in
            ScaleDeviceIdentity(name: "Vector", identifier: "vector", kind: scaleKind, advertisedServices: [])
        },
        startedAt: Date(timeIntervalSince1970: 0),
        recordingStartMonotonicSeconds: input.recordingStartMonotonicSeconds,
        recordingEndMonotonicSeconds: input.recordingEndMonotonicSeconds,
        notes: "",
        rawPackets: packets,
        samples: samples,
        events: events,
        protocolCapabilities: protocolCapabilities,
        scoringProfile: .standard,
        metrics: .empty
    )
}

private func compare(
    _ metrics: ScaleQualityMetrics,
    analysis: ChartAnalysis,
    with expected: ExpectedResult,
    vector: String
) {
    func path(_ field: String) -> String { "\(vector).\(field)" }

    expect(metrics.scoringModelVersion, Optional(expected.scoringModelVersion), path("scoringModelVersion"))
    expect(metrics.scoringProfileName, Optional(expected.scoringProfileName), path("scoringProfileName"))
    expect(metrics.validity?.isValid, Optional(expected.validity.isValid), path("validity.isValid"))
    expect(Set(metrics.validity?.reasons ?? []), Set(expected.validity.reasons), path("validity.reasons"))

    expect(metrics.delivery?.applicable, Optional(expected.delivery.applicable), path("delivery.applicable"))
    expect(metrics.delivery?.deliveryScore, expected.delivery.deliveryScore, path("delivery.deliveryScore"))
    expectDouble(metrics.delivery?.coverage, expected.delivery.coverage, path("delivery.coverage"))
    expectDouble(metrics.delivery?.purity, expected.delivery.purity, path("delivery.purity"))
    expect(metrics.delivery?.purityIsUpperBound, expected.delivery.purityIsUpperBound, path("delivery.purityIsUpperBound"))

    let frames = metrics.frameClassification
    expect(frames?.usable, Optional(expected.frameClassification.usable), path("frameClassification.usable"))
    expect(frames?.parseFailure, Optional(expected.frameClassification.parseFailure), path("frameClassification.parseFailure"))
    expect(frames?.outOfOrder, Optional(expected.frameClassification.outOfOrder), path("frameClassification.outOfOrder"))
    expect(frames?.stale, Optional(expected.frameClassification.stale), path("frameClassification.stale"))
    expect(frames?.duplicate, Optional(expected.frameClassification.duplicate), path("frameClassification.duplicate"))
    expect(frames?.implausible, Optional(expected.frameClassification.implausible), path("frameClassification.implausible"))

    let verification = metrics.protocolVerification
    expect(Set(verification?.verifiableClasses ?? []), Set(expected.protocolVerification.verifiableClasses), path("protocolVerification.verifiableClasses"))
    expect(Set(verification?.unverifiableClasses ?? []), Set(expected.protocolVerification.unverifiableClasses), path("protocolVerification.unverifiableClasses"))
    expect(verification?.verificationCoveragePercent, Optional(expected.protocolVerification.verificationCoveragePercent), path("protocolVerification.verificationCoveragePercent"))
    expect(verification?.purityIsUpperBound, Optional(expected.protocolVerification.purityIsUpperBound), path("protocolVerification.purityIsUpperBound"))
    expect(metrics.signalUnreconstructable, Optional(expected.signalUnreconstructable), path("signalUnreconstructable"))

    let diagnostics = expected.diagnostics
    expect(metrics.relevantWeightFrameCount, Optional(diagnostics.relevantWeightFrames), path("diagnostics.relevantWeightFrames"))
    expect(metrics.excludedFrameCount, Optional(diagnostics.excludedFrames), path("diagnostics.excludedFrames"))
    expect(metrics.usableSampleCount, Optional(diagnostics.usableSampleCount), path("diagnostics.usableSampleCount"))
    expectDouble(metrics.recordingSpanSeconds, Optional(diagnostics.spanSeconds), path("diagnostics.spanSeconds"))
    expect(metrics.recordingBoundaryInferred, Optional(diagnostics.recordingBoundaryInferred), path("diagnostics.recordingBoundaryInferred"))
    expectDouble(metrics.frameRateHz, diagnostics.frameRateHz, path("diagnostics.frameRateHz"))
    expectDouble(metrics.usableRateHz, diagnostics.usableRateHz, path("diagnostics.usableRateHz"))
    expectDouble(metrics.estimatedResolutionGrams, diagnostics.estimatedResolutionGrams, path("diagnostics.estimatedResolutionGrams"))
    expect(metrics.slotCount, diagnostics.slotCount, path("diagnostics.slotCount"))
    expect(metrics.servedSlots, diagnostics.servedSlots, path("diagnostics.servedSlots"))
    expectDouble(metrics.longestUnservedRunMilliseconds, diagnostics.longestUnservedRunMs, path("diagnostics.longestUnservedRunMs"))
    expectDouble(metrics.packetIntervalP50Milliseconds, diagnostics.intervalP50Ms, path("diagnostics.intervalP50Ms"))
    expectDouble(metrics.robustCoefficientOfVariation, diagnostics.robustCoefficientOfVariation, path("diagnostics.robustCoefficientOfVariation"))
    expectDouble(metrics.packetIntervalMaxMilliseconds, diagnostics.intervalMaxMs, path("diagnostics.intervalMaxMs"))
    expect(metrics.disconnectCount, Optional(diagnostics.disconnectCount), path("diagnostics.disconnectCount"))

    let expectedSignals = expected.signalDiagnostics
    if let expectedFlow = expectedSignals.flowValidation {
        expect(analysis.signalDiagnostics.flowValidation?.sampleCount, Optional(expectedFlow.sampleCount), path("signalDiagnostics.flowValidation.sampleCount"))
        expectDouble(analysis.signalDiagnostics.flowValidation?.medianAbsoluteErrorGramsPerSecond, Optional(expectedFlow.medianAbsoluteErrorGramsPerSecond), path("signalDiagnostics.flowValidation.medianAbsoluteErrorGramsPerSecond"))
        expectDouble(analysis.signalDiagnostics.flowValidation?.lagMilliseconds, expectedFlow.lagMilliseconds, path("signalDiagnostics.flowValidation.lagMilliseconds"))
        expectDouble(analysis.signalDiagnostics.flowValidation?.correlation, expectedFlow.correlation, path("signalDiagnostics.flowValidation.correlation"))
    } else {
        expect(analysis.signalDiagnostics.flowValidation, nil, path("signalDiagnostics.flowValidation"))
    }
    if let expectedClock = expectedSignals.clockSkew {
        expect(analysis.signalDiagnostics.clockSkew?.sampleCount, Optional(expectedClock.sampleCount), path("signalDiagnostics.clockSkew.sampleCount"))
        expectDouble(analysis.signalDiagnostics.clockSkew?.skewPartsPerMillion, Optional(expectedClock.skewPartsPerMillion), path("signalDiagnostics.clockSkew.skewPartsPerMillion"))
    } else {
        expect(analysis.signalDiagnostics.clockSkew, nil, path("signalDiagnostics.clockSkew"))
    }
    if let expectedPacket = expectedSignals.packetCoalescing {
        expectDouble(analysis.signalDiagnostics.packetCoalescing?.observedFrameRateHz, Optional(expectedPacket.observedFrameRateHz), path("signalDiagnostics.packetCoalescing.observedFrameRateHz"))
        expectDouble(analysis.signalDiagnostics.packetCoalescing?.servedSlotRateHz, Optional(expectedPacket.servedSlotRateHz), path("signalDiagnostics.packetCoalescing.servedSlotRateHz"))
        expectDouble(analysis.signalDiagnostics.packetCoalescing?.framesPerServedSlot, Optional(expectedPacket.framesPerServedSlot), path("signalDiagnostics.packetCoalescing.framesPerServedSlot"))
    } else {
        expect(analysis.signalDiagnostics.packetCoalescing, nil, path("signalDiagnostics.packetCoalescing"))
    }

    if let idle = expected.idle {
        expect(metrics.stabilityScore, idle.idleStabilityScore, path("idle.idleStabilityScore"))
        expect(metrics.idleNoiseScore, idle.noiseScore, path("idle.noiseScore"))
        expect(metrics.idleDriftScore, idle.driftScore, path("idle.driftScore"))
        expect(metrics.idleAnalysedSampleCount, Optional(idle.analysedSampleCount), path("idle.analysedSampleCount"))
        expectDouble(metrics.idleNoiseStandardDeviationGrams, idle.residualStandardDeviationGrams, path("idle.residualStandardDeviationGrams"))
        expectDouble(metrics.idleNoisePeakToPeakGrams, idle.residualPeakToPeakGrams, path("idle.residualPeakToPeakGrams"))
        expectDouble(metrics.driftGramsPerMinute, idle.driftGramsPerMinute, path("idle.driftGramsPerMinute"))
        expectDouble(metrics.idleResolutionGrams, idle.resolutionGrams, path("idle.resolutionGrams"))
    } else {
        expect(metrics.stabilityScore, nil, path("idle"))
    }

    if let step = expected.stepResponse {
        expect(metrics.stepResponse?.stepDetected, Optional(step.stepDetected), path("stepResponse.stepDetected"))
        expectDouble(metrics.stepResponse?.onsetSecondsFromRecordingStart, step.onsetSecondsFromRecordingStart, path("stepResponse.onsetSecondsFromRecordingStart"))
        expectDouble(metrics.stepResponse?.baselineGrams, step.baselineGrams, path("stepResponse.baselineGrams"))
        expectDouble(metrics.stepResponse?.finalGrams, step.finalGrams, path("stepResponse.finalGrams"))
        expectDouble(metrics.stepResponse?.amplitudeGrams, step.amplitudeGrams, path("stepResponse.amplitudeGrams"))
        expectDouble(metrics.stepResponse?.riseTime10To90Seconds, step.riseTime10To90Seconds, path("stepResponse.riseTime10To90Seconds"))
        expectDouble(metrics.stepResponse?.settlingTimeSeconds, step.settlingTimeSeconds, path("stepResponse.settlingTimeSeconds"))
        expectDouble(metrics.stepResponse?.overshootPercent, step.overshootPercent, path("stepResponse.overshootPercent"))
    } else {
        expect(metrics.stepResponse, nil, path("stepResponse"))
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "ScaleBenchConformance", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: runner /path/to/scoring/vectors"])
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let decoder = JSONDecoder()
    let index = try decoder.decode(VectorIndex.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
    expect(index.scoringModelVersion, ScaleQualityAnalyzer.scoringModelVersion, "index.scoringModelVersion")

    for entry in index.vectors {
        let directory = root.appendingPathComponent(entry.vectorId, isDirectory: true)
        let input = try decoder.decode(VectorInput.self, from: Data(contentsOf: directory.appendingPathComponent("input.json")))
        let expected = try decoder.decode(ExpectedResult.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        let recording = try recording(from: input)
        let metrics = ScaleQualityAnalyzer.analyze(recording)
        compare(
            metrics,
            analysis: ChartAnalysis.make(recording: recording, metrics: metrics),
            with: expected,
            vector: entry.vectorId
        )
    }

    if failures.isEmpty {
        print("Swift scoring conformance passed: \(index.vectors.count) vectors")
    } else {
        failures.forEach { FileHandle.standardError.write(Data(("FAIL: \($0)\n").utf8)) }
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data(("Conformance runner failed: \(error)\n").utf8))
    exit(1)
}
