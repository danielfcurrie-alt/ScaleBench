import Foundation

struct ChartAnalysis: Equatable {
    static let schemaVersion = 1

    var weightPoints: [ChartPoint]
    var flowPoints: [ChartPoint]
    var packetTimeline: PacketTimeline
    var problemWindows: [ChartProblemWindow]
    var deductionBreakdown: [ChartDeduction]
    var signalDiagnostics: SignalDiagnostics

    static func make(recording: ScaleRecording, metrics: ScaleQualityMetrics) -> ChartAnalysis {
        let referenceTime = chartReferenceTime(recording: recording)
        let timeline = PacketTimeline.make(recording: recording, metrics: metrics, referenceTime: referenceTime)
        let weightPoints = chartPoints(samples: recording.samples, referenceTime: referenceTime)
        let flowPoints = flowChartPoints(samples: recording.samples, referenceTime: referenceTime)
        return ChartAnalysis(
            weightPoints: weightPoints,
            flowPoints: flowPoints,
            packetTimeline: timeline,
            problemWindows: makeProblemWindows(points: weightPoints, timeline: timeline),
            deductionBreakdown: deductions(metrics: metrics),
            signalDiagnostics: makeSignalDiagnostics(recording: recording, metrics: metrics)
        )
    }
}

struct ChartPoint: Identifiable, Equatable {
    var id: Double { seconds }
    var seconds: Double
    var value: Double
}

struct SignalDiagnostics: Codable, Equatable {
    var flowValidation: FlowValidationDiagnostics?
    var clockSkew: ClockSkewDiagnostics?
    var packetCoalescing: PacketCoalescingDiagnostics?

    var isEmpty: Bool {
        flowValidation == nil && clockSkew == nil && packetCoalescing == nil
    }
}

struct FlowValidationDiagnostics: Codable, Equatable {
    var sampleCount: Int
    var medianAbsoluteErrorGramsPerSecond: Double
    var lagMilliseconds: Double?
    var correlation: Double?
}

struct ClockSkewDiagnostics: Codable, Equatable {
    var sampleCount: Int
    var skewPartsPerMillion: Double
}

struct PacketCoalescingDiagnostics: Codable, Equatable {
    var observedFrameRateHz: Double
    var servedSlotRateHz: Double
    var framesPerServedSlot: Double
}

struct ChartProblemWindow: Identifiable, Equatable {
    var id: String
    var title: String
    var category: ChartProblemCategory
    var severity: PacketSeverity
    var startSeconds: Double
    var endSeconds: Double
    var relatedPacketIndex: Int?
}

enum ChartProblemCategory: String, Equatable {
    case gap
    case parseFailure
    case outOfOrder
    case staleClock
    case duplicate
    case implausible
    case disconnect
    case validity
    case diagnostic
}

struct ChartDeduction: Identifiable, Equatable {
    var id: String { category.rawValue }
    var category: ChartProblemCategory
    var title: String
    var detail: String
    var pointsLost: Int?
    var severity: PacketSeverity
}

struct PacketTimeline: Equatable {
    var entries: [PacketTimelineEntry]
    var sampleIntervals: [SampleIntervalEntry]
    var scoringGaps: [ScoringGap]
    var longGapThresholdMilliseconds: Double
    var recordingDurationSeconds: Double

    var durationSeconds: Double {
        let rawEnd = entries.last?.relativeSeconds ?? 0
        let sampleEnd = sampleIntervals.last?.relativeSeconds ?? 0
        return max(0, recordingDurationSeconds, rawEnd, sampleEnd)
    }

    var warningIntervalCount: Int {
        sampleIntervals.filter { $0.severity == .warning }.count
    }

    static func make(
        recording: ScaleRecording,
        metrics _: ScaleQualityMetrics,
        referenceTime: Double
    ) -> PacketTimeline {
        let packets = recording.rawPackets.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
        let threshold = packetLongGapThresholdMilliseconds(recording: recording)
        let sampleIntervals = sampleIntervalEntries(
            samples: recording.samples,
            firstReferenceTime: referenceTime,
            thresholdMilliseconds: threshold,
            recordingStartTime: recording.recordingStartMonotonicSeconds,
            recordingEndTime: recording.recordingEndMonotonicSeconds
        )
        let recordingDuration = recording.recordingEndMonotonicSeconds.map {
            max(0, $0 - referenceTime)
        } ?? 0
        let scoringGaps = sampleIntervals.compactMap { entry -> ScoringGap? in
            guard entry.severity == .penalty else { return nil }
            return ScoringGap(
                id: entry.index,
                startRelativeSeconds: entry.previousRelativeSeconds,
                endRelativeSeconds: entry.relativeSeconds,
                intervalMilliseconds: entry.intervalMilliseconds
            )
        }

        guard !packets.isEmpty else {
            return PacketTimeline(
                entries: [],
                sampleIntervals: sampleIntervals,
                scoringGaps: scoringGaps,
                longGapThresholdMilliseconds: threshold,
                recordingDurationSeconds: recordingDuration
            )
        }

        var entries: [PacketTimelineEntry] = []
        var previousPacket: RawScalePacket?
        let scorerEvidence = ScaleQualityAnalyzer.packetEvidence(recording: recording)
        for (index, packet) in packets.enumerated() {
            let interval = previousPacket.map { max(0, packet.monotonicSeconds - $0.monotonicSeconds) * 1_000 }
            let relative = packet.monotonicSeconds - referenceTime
            let previousRelative = previousPacket.map { $0.monotonicSeconds - referenceTime }
            let timelineSeverity = packetSeverity(
                packet: packet,
                intervalMilliseconds: interval,
                longGapThresholdMilliseconds: threshold
            )
            let timelineEvidence = packetEvidence(
                packet: packet,
                intervalMilliseconds: interval,
                longGapThresholdMilliseconds: threshold
            )
            let packetScorerEvidence = scorerEvidence[packet.id] ?? []
            let evidence = timelineEvidence + packetScorerEvidence
            let severity = packetScorerEvidence.isEmpty ? timelineSeverity : .penalty

            entries.append(
                PacketTimelineEntry(
                    id: packet.id,
                    index: index,
                    packet: packet,
                    relativeSeconds: relative,
                    previousRelativeSeconds: previousRelative,
                    intervalMilliseconds: interval,
                    severity: severity,
                    evidence: evidence
                )
            )
            previousPacket = packet
        }

        return PacketTimeline(
            entries: entries,
            sampleIntervals: sampleIntervals,
            scoringGaps: scoringGaps,
            longGapThresholdMilliseconds: threshold,
            recordingDurationSeconds: recordingDuration
        )
    }
}

struct SampleIntervalEntry: Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var previousRelativeSeconds: Double
    var relativeSeconds: Double
    var intervalMilliseconds: Double
    var severity: PacketSeverity
}

struct ScoringGap: Identifiable, Equatable {
    var id: Int
    var startRelativeSeconds: Double
    var endRelativeSeconds: Double
    var intervalMilliseconds: Double
}

struct PacketTimelineEntry: Identifiable, Equatable {
    var id: UUID
    var index: Int
    var packet: RawScalePacket
    var relativeSeconds: Double
    var previousRelativeSeconds: Double?
    var intervalMilliseconds: Double?
    var severity: PacketSeverity
    var evidence: [String]

    var hasLongGapBefore: Bool {
        guard intervalMilliseconds != nil else { return false }
        return severity == .penalty && evidence.contains { $0.localizedCaseInsensitiveContains("long gap") }
    }

    var lane: PacketLane {
        if severity == .penalty { return .penalty }
        switch packet.role {
        case .weight:
            return .weight
        case .battery:
            return .metadata
        case .capabilities, .commandAck:
            return .control
        case .unknown:
            return .unknown
        }
    }
}

enum PacketSeverity: Int, Equatable {
    case normal
    case info
    case warning
    case penalty

    var label: String {
        switch self {
        case .normal:
            "normal"
        case .info:
            "metadata or control"
        case .warning:
            "warning"
        case .penalty:
            "score penalty"
        }
    }

    var systemImage: String {
        switch self {
        case .normal:
            "checkmark.circle"
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .penalty:
            "xmark.octagon"
        }
    }
}

enum PacketLane: CaseIterable {
    case weight
    case metadata
    case control
    case penalty
    case unknown

    var index: Int {
        switch self {
        case .weight:
            0
        case .metadata:
            1
        case .control:
            2
        case .penalty:
            3
        case .unknown:
            4
        }
    }
}

private func chartReferenceTime(recording: ScaleRecording) -> Double {
    if let recordingStart = recording.recordingStartMonotonicSeconds {
        return recordingStart
    }
    let firstPacket = recording.rawPackets.map(\.monotonicSeconds).min()
    let firstSample = recording.samples.map(\.monotonicSeconds).min()
    return [firstPacket, firstSample].compactMap { $0 }.min() ?? 0
}

private func chartPoints(samples inputSamples: [ScaleSample], referenceTime: Double) -> [ChartPoint] {
    let samples = inputSamples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
    return samples.map { ChartPoint(seconds: $0.monotonicSeconds - referenceTime, value: $0.weightGrams) }
}

private func flowChartPoints(samples inputSamples: [ScaleSample], referenceTime: Double) -> [ChartPoint] {
    let samples = inputSamples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
    return samples.compactMap { sample in
        sample.flowGramsPerSecond.map { ChartPoint(seconds: sample.monotonicSeconds - referenceTime, value: $0) }
    }
}

private func makeProblemWindows(points: [ChartPoint], timeline: PacketTimeline) -> [ChartProblemWindow] {
    let lastSecond = max(points.last?.seconds ?? 0, timeline.durationSeconds)
    guard lastSecond > 0 else { return [] }
    var windows: [ChartProblemWindow] = []

    for (index, gap) in timeline.scoringGaps.prefix(3).enumerated() {
        windows.append(
            ChartProblemWindow(
                id: "gap-\(gap.id)",
                title: "Gap \(index + 1) (\(formatAnalysisMilliseconds(gap.intervalMilliseconds)))",
                category: .gap,
                severity: .penalty,
                startSeconds: max(0, gap.startRelativeSeconds - 2),
                endSeconds: min(lastSecond, gap.endRelativeSeconds + 2),
                relatedPacketIndex: nil
            )
        )
    }

    for entry in timeline.entries.filter({ $0.severity == .penalty }).prefix(max(0, 3 - windows.count)) {
        windows.append(
            ChartProblemWindow(
                id: "packet-\(entry.index)",
                title: "Packet \(entry.index + 1) \(entry.severity.label)",
                category: entry.packet.rejectionReason == nil ? .diagnostic : .parseFailure,
                severity: entry.severity,
                startSeconds: max(0, entry.relativeSeconds - 2),
                endSeconds: min(lastSecond, entry.relativeSeconds + 2),
                relatedPacketIndex: entry.index
            )
        )
    }

    if windows.isEmpty {
        for entry in timeline.entries.filter({ $0.severity == .warning }).prefix(2) {
            windows.append(
                ChartProblemWindow(
                    id: "warning-\(entry.index)",
                    title: "Packet \(entry.index + 1) warning",
                    category: .diagnostic,
                    severity: .warning,
                    startSeconds: max(0, entry.relativeSeconds - 2),
                    endSeconds: min(lastSecond, entry.relativeSeconds + 2),
                    relatedPacketIndex: entry.index
                )
            )
        }
    }

    var seen: Set<String> = []
    return windows.compactMap { window in
        var copy = window
        if copy.endSeconds - copy.startSeconds < 0.5 {
            copy.endSeconds = min(lastSecond, copy.startSeconds + 0.5)
        }
        let key = "\(String(format: "%.2f", copy.startSeconds))-\(String(format: "%.2f", copy.endSeconds))"
        guard seen.insert(key).inserted else { return nil }
        return copy
    }
    .prefix(3)
    .map { $0 }
}

private func deductions(metrics: ScaleQualityMetrics) -> [ChartDeduction] {
    var result: [ChartDeduction] = []
    if let delivery = metrics.delivery, delivery.applicable, let score = delivery.deliveryScore {
        result.append(
            ChartDeduction(
                category: .gap,
                title: "Delivery",
                detail: "Delivered packets and usable readings account for \(max(0, 100 - score)) lost points.",
                pointsLost: max(0, 100 - score),
                severity: score < 100 ? .penalty : .normal
            )
        )
    }
    if let validity = metrics.validity, !validity.isValid {
        result.append(
            ChartDeduction(
                category: .validity,
                title: "Validity",
                detail: validity.reasons.joined(separator: ", "),
                pointsLost: nil,
                severity: .penalty
            )
        )
    }
    if let frames = metrics.frameClassification {
        let classifiedProblems = frames.parseFailure + frames.outOfOrder + frames.stale + frames.duplicate + frames.implausible
        if classifiedProblems > 0 {
            result.append(
                ChartDeduction(
                    category: .diagnostic,
                    title: "Frame classification",
                    detail: "\(classifiedProblems) unusable or suspicious frame classes were observed.",
                    pointsLost: nil,
                    severity: .warning
                )
            )
        }
    }
    return result
}

private func packetLongGapThresholdMilliseconds(recording: ScaleRecording) -> Double {
    let intervals = ScaleQualityAnalyzer.sampleIntervalsMilliseconds(recording.samples)
    let typicalInterval = percentile(intervals, 0.50)
    return ScaleQualityAnalyzer.longGapThresholdMilliseconds(
        forTypicalIntervalMilliseconds: typicalInterval,
        profile: recording.scoringProfile.normalized
    )
}

private func sampleIntervalEntries(
    samples inputSamples: [ScaleSample],
    firstReferenceTime: Double,
    thresholdMilliseconds: Double,
    recordingStartTime: Double?,
    recordingEndTime: Double?
) -> [SampleIntervalEntry] {
    let samples = inputSamples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
    func entry(index: Int, previousTime: Double, currentTime: Double) -> SampleIntervalEntry? {
        guard currentTime > previousTime else { return nil }
        let interval = (currentTime - previousTime) * 1_000
        let severity: PacketSeverity
        if interval >= thresholdMilliseconds {
            severity = .penalty
        } else if interval >= thresholdMilliseconds * 0.66 {
            severity = .warning
        } else {
            severity = .normal
        }
        return SampleIntervalEntry(
            index: index,
            previousRelativeSeconds: previousTime - firstReferenceTime,
            relativeSeconds: currentTime - firstReferenceTime,
            intervalMilliseconds: interval,
            severity: severity
        )
    }

    var result: [SampleIntervalEntry] = []
    let boundaryIndexOffset = recordingStartTime == nil ? 0 : 1
    if let recordingStartTime, let first = samples.first,
       let leading = entry(index: 0, previousTime: recordingStartTime, currentTime: first.monotonicSeconds) {
        result.append(leading)
    }

    if samples.count >= 2 {
        for index in 1..<samples.count {
            if let interval = entry(
                index: index - 1 + boundaryIndexOffset,
                previousTime: samples[index - 1].monotonicSeconds,
                currentTime: samples[index].monotonicSeconds
            ) {
                result.append(interval)
            }
        }
    }

    if let recordingEndTime, let last = samples.last,
       let trailing = entry(
        index: max(0, samples.count - 1 + boundaryIndexOffset),
        previousTime: last.monotonicSeconds,
        currentTime: recordingEndTime
       ) {
        result.append(trailing)
    } else if samples.isEmpty,
              let recordingStartTime,
              let recordingEndTime,
              let fullRecording = entry(
                index: 0,
                previousTime: recordingStartTime,
                currentTime: recordingEndTime
              ) {
        result.append(fullRecording)
    }
    return result
}

private func packetSeverity(
    packet: RawScalePacket,
    intervalMilliseconds: Double?,
    longGapThresholdMilliseconds: Double
) -> PacketSeverity {
    if packet.rejectionReason != nil {
        return .penalty
    }
    if let intervalMilliseconds, intervalMilliseconds >= longGapThresholdMilliseconds * 0.66 {
        return .warning
    }
    switch packet.role {
    case .unknown:
        return .warning
    case .battery, .capabilities, .commandAck:
        return .info
    case .weight:
        return .normal
    }
}

private func packetEvidence(
    packet: RawScalePacket,
    intervalMilliseconds: Double?,
    longGapThresholdMilliseconds: Double
) -> [String] {
    var evidence: [String] = []
    if let rejectionReason = packet.rejectionReason {
        evidence.append("Rejected by parser: \(rejectionReason.rawValue). This directly lowers transport quality.")
    }
    if let intervalMilliseconds, intervalMilliseconds >= longGapThresholdMilliseconds {
        evidence.append("Raw packet interval before this packet: \(formatAnalysisMilliseconds(intervalMilliseconds)). Scoring uses parsed sample intervals; see the cadence chart for direct gap penalties.")
    } else if let intervalMilliseconds, intervalMilliseconds >= longGapThresholdMilliseconds * 0.66 {
        evidence.append("Near-threshold raw packet interval before this packet: \(formatAnalysisMilliseconds(intervalMilliseconds)). Warning only.")
    }
    if packet.role == .unknown {
        evidence.append("Unknown packet role. Kept for diagnostics; may indicate unsupported protocol traffic.")
    }
    if packet.role == .battery {
        evidence.append("Battery/metadata packet. This can improve metadata coverage when parsed.")
    }
    if packet.role == .capabilities {
        evidence.append("Capability packet. Useful context for WMB+ features and parser behavior.")
    }
    if packet.role == .commandAck {
        evidence.append("Command acknowledgement packet. Useful context around tare/start/stop actions.")
    }
    if evidence.isEmpty {
        evidence.append("Normal parsed packet. No direct score penalty attached.")
    }
    return evidence
}

private func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * p))))
    return sorted[index]
}

private func formatAnalysisMilliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "--"
}

private func makeSignalDiagnostics(recording: ScaleRecording, metrics: ScaleQualityMetrics) -> SignalDiagnostics {
    guard recording.recordingEndMonotonicSeconds != nil else {
        return SignalDiagnostics(flowValidation: nil, clockSkew: nil, packetCoalescing: nil)
    }
    return SignalDiagnostics(
        flowValidation: flowValidation(samples: recording.samples),
        clockSkew: clockSkew(recording: recording),
        packetCoalescing: packetCoalescing(metrics: metrics)
    )
}

private func flowValidation(samples inputSamples: [ScaleSample]) -> FlowValidationDiagnostics? {
    let samples = strictlyIncreasingSamples(inputSamples)
    guard samples.count >= 5,
          let firstTime = samples.first?.monotonicSeconds,
          let lastTime = samples.last?.monotonicSeconds,
          lastTime - firstTime >= 1 else {
        return nil
    }

    let reported = samples.compactMap { sample -> TimedValue? in
        guard let flow = sample.flowGramsPerSecond, flow.isFinite else { return nil }
        return TimedValue(seconds: sample.monotonicSeconds, value: flow)
    }
    guard reported.count >= 5 else { return nil }

    let halfWindow = 0.5
    let derived = samples.compactMap { sample -> TimedValue? in
        let leftTime = sample.monotonicSeconds - halfWindow
        let rightTime = sample.monotonicSeconds + halfWindow
        guard let left = interpolatedWeight(at: leftTime, samples: samples),
              let right = interpolatedWeight(at: rightTime, samples: samples) else {
            return nil
        }
        return TimedValue(
            seconds: sample.monotonicSeconds,
            value: (right - left) / (halfWindow * 2)
        )
    }
    guard derived.count >= 5 else { return nil }

    var bestLag: Double?
    var bestCorrelation: Double?
    for step in -20...20 {
        let lag = Double(step) * 0.05
        let pairs = reported.compactMap { item -> (Double, Double)? in
            interpolatedValue(at: item.seconds - lag, points: derived).map { (item.value, $0) }
        }
        guard pairs.count >= 8, let correlation = pearsonCorrelation(pairs) else { continue }
        if bestCorrelation == nil
            || correlation > bestCorrelation! + 0.000_001
            || (abs(correlation - bestCorrelation!) <= 0.000_001 && abs(lag) < abs(bestLag ?? .infinity)) {
            bestCorrelation = correlation
            bestLag = lag
        }
    }

    if let bestCorrelation, bestCorrelation < 0.25 {
        bestLag = nil
    }
    let alignmentLag = bestLag ?? 0
    let errors = reported.compactMap { item -> Double? in
        interpolatedValue(at: item.seconds - alignmentLag, points: derived).map { abs(item.value - $0) }
    }
    guard errors.count >= 5, let medianError = median(errors) else { return nil }

    return FlowValidationDiagnostics(
        sampleCount: errors.count,
        medianAbsoluteErrorGramsPerSecond: medianError,
        lagMilliseconds: bestLag.map { $0 * 1_000 },
        correlation: bestLag == nil ? nil : bestCorrelation
    )
}

private func clockSkew(recording: ScaleRecording) -> ClockSkewDiagnostics? {
    let samples = recording.samples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
    let kind = recording.device?.kind ?? samples.first?.scaleKind ?? .unknown
    let supportedKinds: Set<ScaleKind> = [.bookoo, .bookooMini, .bookooUltra, .weighMyBruPlus]
    guard supportedKinds.contains(kind),
          recording.protocolCapabilities?.deviceClockSemantics != .shotTimer else {
        return nil
    }

    let modulus = Double(recording.protocolCapabilities?.deviceClockModulus ?? (UInt64(1) << 24))
    var points: [(hostMilliseconds: Double, deviceMilliseconds: Double)] = []
    var previousRaw: Double?
    var previousUnwrapped: Double?
    var offset = 0.0

    for sample in samples {
        guard let timestamp = sample.deviceTimestampMilliseconds else { continue }
        let raw = Double(timestamp)
        if let previousRaw, raw < previousRaw {
            if previousRaw - raw > modulus / 2 {
                offset += modulus
            } else {
                continue
            }
        }
        let unwrapped = raw + offset
        if let previousUnwrapped, unwrapped <= previousUnwrapped { continue }
        points.append((sample.monotonicSeconds * 1_000, unwrapped))
        previousRaw = raw
        previousUnwrapped = unwrapped
    }

    guard points.count >= 10,
          let first = points.first,
          let last = points.last,
          last.hostMilliseconds - first.hostMilliseconds >= 5_000 else {
        return nil
    }
    let meanHost = points.map(\.hostMilliseconds).reduce(0, +) / Double(points.count)
    let meanDevice = points.map(\.deviceMilliseconds).reduce(0, +) / Double(points.count)
    let numerator = points.reduce(0.0) {
        $0 + ($1.hostMilliseconds - meanHost) * ($1.deviceMilliseconds - meanDevice)
    }
    let denominator = points.reduce(0.0) {
        $0 + pow($1.hostMilliseconds - meanHost, 2)
    }
    guard denominator > 0 else { return nil }
    let skew = (numerator / denominator - 1) * 1_000_000
    guard skew.isFinite else { return nil }
    return ClockSkewDiagnostics(sampleCount: points.count, skewPartsPerMillion: skew)
}

private func packetCoalescing(metrics: ScaleQualityMetrics) -> PacketCoalescingDiagnostics? {
    guard metrics.delivery?.applicable == true,
          let coverage = metrics.delivery?.coverage,
          let frameRate = metrics.frameRateHz,
          coverage > 0,
          frameRate >= 0 else {
        return nil
    }
    let servedSlotRate = coverage * 20
    guard servedSlotRate > 0 else { return nil }
    return PacketCoalescingDiagnostics(
        observedFrameRateHz: frameRate,
        servedSlotRateHz: servedSlotRate,
        framesPerServedSlot: frameRate / servedSlotRate
    )
}

private struct TimedValue {
    var seconds: Double
    var value: Double
}

private func strictlyIncreasingSamples(_ inputSamples: [ScaleSample]) -> [ScaleSample] {
    inputSamples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }.reduce(into: []) { result, sample in
        guard sample.monotonicSeconds.isFinite, sample.weightGrams.isFinite else { return }
        if let previous = result.last, sample.monotonicSeconds <= previous.monotonicSeconds { return }
        result.append(sample)
    }
}

private func interpolatedWeight(at time: Double, samples: [ScaleSample]) -> Double? {
    guard let first = samples.first, let last = samples.last,
          time >= first.monotonicSeconds, time <= last.monotonicSeconds else {
        return nil
    }
    var low = 0
    var high = samples.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let sample = samples[middle]
        if sample.monotonicSeconds == time { return sample.weightGrams }
        if sample.monotonicSeconds < time {
            low = middle + 1
        } else {
            high = middle - 1
        }
    }
    guard low > 0, low < samples.count else { return nil }
    let before = samples[low - 1]
    let after = samples[low]
    let span = after.monotonicSeconds - before.monotonicSeconds
    guard span > 0 else { return nil }
    let fraction = (time - before.monotonicSeconds) / span
    return before.weightGrams + (after.weightGrams - before.weightGrams) * fraction
}

private func interpolatedValue(at time: Double, points: [TimedValue]) -> Double? {
    guard let first = points.first, let last = points.last,
          time >= first.seconds, time <= last.seconds else {
        return nil
    }
    var low = 0
    var high = points.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let point = points[middle]
        if point.seconds == time { return point.value }
        if point.seconds < time {
            low = middle + 1
        } else {
            high = middle - 1
        }
    }
    guard low > 0, low < points.count else { return nil }
    let before = points[low - 1]
    let after = points[low]
    let span = after.seconds - before.seconds
    guard span > 0 else { return nil }
    let fraction = (time - before.seconds) / span
    return before.value + (after.value - before.value) * fraction
}

private func pearsonCorrelation(_ pairs: [(Double, Double)]) -> Double? {
    guard pairs.count >= 2 else { return nil }
    let count = Double(pairs.count)
    let meanX = pairs.map(\.0).reduce(0, +) / count
    let meanY = pairs.map(\.1).reduce(0, +) / count
    let numerator = pairs.reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    let xVariance = pairs.reduce(0.0) { $0 + pow($1.0 - meanX, 2) }
    let yVariance = pairs.reduce(0.0) { $0 + pow($1.1 - meanY, 2) }
    let denominator = sqrt(xVariance * yVariance)
    guard denominator > 0 else { return nil }
    return numerator / denominator
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}
