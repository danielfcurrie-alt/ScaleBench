import Foundation

enum ScaleQualityAnalyzer {
    static func analyze(_ recording: ScaleRecording, profile inputProfile: ScoringProfile? = nil) -> ScaleQualityMetrics {
        let profile = (inputProfile ?? recording.scoringProfile).normalized
        let samples = recording.samples
        let rejected = recording.rawPackets.filter { $0.rejectionReason != nil }.count
        let batteryValues = (
            samples.compactMap(\.batteryPercent) + recording.batteryEvents.map(\.percent)
        ).filter { (0...100).contains($0) }
        let firmwareQuality = samples.compactMap(\.firmwareQualityScore).filter { (0...100).contains($0) }
        let bumpCount = firmwareBumpEventCount(samples)
        guard samples.count >= 2 else {
            var metrics = ScaleQualityMetrics.empty
            metrics.rejectedPacketCount = rejected
            metrics.batteryMinPercent = batteryValues.min()
            metrics.batteryMaxPercent = batteryValues.max()
            metrics.firmwareQualityAverage = average(firmwareQuality)
            metrics.firmwareBumpCount = bumpCount
            return metrics
        }

        let intervals = sampleIntervalsMilliseconds(samples)
        let p50 = percentile(intervals, 0.50)
        let p95 = percentile(intervals, 0.95)
        let maxInterval = intervals.max()
        let duration = samples.last!.monotonicSeconds - samples.first!.monotonicSeconds
        let effectiveRate = duration > 0 ? Double(samples.count - 1) / duration : nil
        let longGapThreshold = longGapThresholdMilliseconds(forTypicalIntervalMilliseconds: p50, profile: profile)
        let longGaps = intervals.filter { $0 >= longGapThreshold }.count
        let missingSequence = missingSequenceCount(samples)
        let timestampIssues = duplicateOrOutOfOrderDeviceTimestamps(samples)
        let weights = samples.map(\.weightGrams)
        let noisePeakToPeak = weights.max().flatMap { maxWeight in weights.min().map { maxWeight - $0 } }
        let standardDeviation = standardDeviation(weights)
        let drift = driftGramsPerMinute(samples)
        let transportScore = scoreTransport(
            longGaps: longGaps,
            missingSequence: missingSequence,
            timestampIssues: timestampIssues,
            rejected: rejected,
            sampleCount: samples.count,
            profile: profile
        )
        let stabilityScore = recording.mode == .idleStability
            ? scoreIdleStability(
                noisePeakToPeak: noisePeakToPeak,
                standardDeviation: standardDeviation,
                drift: drift,
                profile: profile
            )
            : scoreDynamicStability(bumpCount: bumpCount)
        let validBatteryEventCount = recording.batteryEvents.filter { (0...100).contains($0.percent) }.count
        let metadataScore = scoreMetadata(samples, batteryEventCount: validBatteryEventCount)
        let overall = min(100, max(0, Int(round(
            Double(transportScore) * profile.transportWeight
            + Double(stabilityScore) * profile.stabilityWeight
            + Double(metadataScore) * profile.metadataWeight
        ))))

        return ScaleQualityMetrics(
            overallScore: overall,
            transportScore: transportScore,
            stabilityScore: stabilityScore,
            metadataScore: metadataScore,
            effectiveSampleRateHz: effectiveRate,
            packetIntervalP50Milliseconds: p50,
            packetIntervalP95Milliseconds: p95,
            packetIntervalMaxMilliseconds: maxInterval,
            longGapCount: longGaps,
            missingSequenceCount: missingSequence,
            duplicateOrOutOfOrderTimestampCount: timestampIssues,
            rejectedPacketCount: rejected,
            idleNoisePeakToPeakGrams: recording.mode == .idleStability ? noisePeakToPeak : nil,
            idleNoiseStandardDeviationGrams: recording.mode == .idleStability ? standardDeviation : nil,
            driftGramsPerMinute: recording.mode == .idleStability ? drift : nil,
            batteryMinPercent: batteryValues.min(),
            batteryMaxPercent: batteryValues.max(),
            firmwareQualityAverage: average(firmwareQuality),
            firmwareBumpCount: bumpCount
        )
    }

    static func sampleIntervalsMilliseconds(_ samples: [ScaleSample]) -> [Double] {
        samples.adjacentPairs().map { previous, current in
            if let previousTimestamp = previous.deviceTimestampMilliseconds,
               let currentTimestamp = current.deviceTimestampMilliseconds,
               previous.scaleKind == current.scaleKind {
                return Double(deviceTimestampDelta(
                    previousTimestamp,
                    currentTimestamp,
                    kind: current.scaleKind
                ))
            }
            return max(0, current.monotonicSeconds - previous.monotonicSeconds) * 1000.0
        }
    }

    static func longGapThresholdMilliseconds(forTypicalIntervalMilliseconds typicalInterval: Double?, profile: ScoringProfile) -> Double {
        guard let typicalInterval, typicalInterval > 0 else { return profile.minimumLongGapMilliseconds }
        return max(profile.minimumLongGapMilliseconds, typicalInterval * profile.longGapMultiplier)
    }

    private static func missingSequenceCount(_ samples: [ScaleSample]) -> Int {
        samples.adjacentPairs().reduce(0) { count, pair in
            guard let previous = pair.0.sequence, let current = pair.1.sequence else { return count }
            let delta = Int(current &- previous)
            guard delta > 1, delta <= 127 else { return count }
            return count + delta - 1
        }
    }

    private static func duplicateOrOutOfOrderDeviceTimestamps(_ samples: [ScaleSample]) -> Int {
        samples.adjacentPairs().filter { previous, current in
            guard let previousTimestamp = previous.deviceTimestampMilliseconds,
                  let currentTimestamp = current.deviceTimestampMilliseconds,
                  previous.scaleKind == current.scaleKind else {
                return false
            }
            let delta = deviceTimestampDelta(previousTimestamp, currentTimestamp, kind: current.scaleKind)
            return delta == 0 || delta > deviceTimestampHalfRange(kind: current.scaleKind)
        }.count
    }

    private static func deviceTimestampDelta(_ previous: UInt32, _ current: UInt32, kind: ScaleKind) -> UInt32 {
        guard uses24BitDeviceTimestamp(kind) else { return current &- previous }
        let mask: UInt32 = 0x00FF_FFFF
        return ((current & mask) &- (previous & mask)) & mask
    }

    private static func deviceTimestampHalfRange(kind: ScaleKind) -> UInt32 {
        uses24BitDeviceTimestamp(kind) ? 0x007F_FFFF : UInt32.max / 2
    }

    private static func uses24BitDeviceTimestamp(_ kind: ScaleKind) -> Bool {
        switch kind {
        case .bookoo, .bookooMini, .bookooUltra, .weighMyBruPlus:
            true
        default:
            false
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * p))))
        return sorted[index]
    }

    private static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func driftGramsPerMinute(_ samples: [ScaleSample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let minutes = (last.monotonicSeconds - first.monotonicSeconds) / 60.0
        guard minutes > 0 else { return nil }
        return (last.weightGrams - first.weightGrams) / minutes
    }

    private static func average(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private static func firmwareBumpEventCount(_ samples: [ScaleSample]) -> Int {
        var count = 0
        var bumpIsActive = false
        for sample in samples {
            let hasBump = sample.diagnosticFlags?.recentBump == true
            if hasBump && !bumpIsActive {
                count += 1
            }
            bumpIsActive = hasBump
        }
        return count
    }

    private static func scoreTransport(
        longGaps: Int,
        missingSequence: Int,
        timestampIssues: Int,
        rejected: Int,
        sampleCount: Int,
        profile: ScoringProfile
    ) -> Int {
        var score = 100
        score -= cappedPenalty(count: longGaps, unit: profile.longGapPenalty, cap: 40)
        score -= cappedPenalty(count: missingSequence, unit: profile.missingSequencePenalty, cap: 30)
        score -= cappedPenalty(count: timestampIssues, unit: profile.timestampIssuePenalty, cap: 20)
        let parseAttemptCount = max(sampleCount + rejected, 1)
        score -= min(30, Int(round(
            Double(rejected) / Double(parseAttemptCount) * profile.rejectedPacketRatePenaltyScale
        )))
        return max(0, score)
    }

    private static func cappedPenalty(count: Int, unit: Int, cap: Int) -> Int {
        Int(min(Double(cap), Double(max(0, count)) * Double(max(0, unit))))
    }

    private static func scoreIdleStability(
        noisePeakToPeak: Double?,
        standardDeviation: Double?,
        drift: Double?,
        profile: ScoringProfile
    ) -> Int {
        var score = 100
        if let noisePeakToPeak {
            score -= min(35, Int(round(max(0, noisePeakToPeak - profile.idleNoiseFreePeakToPeakGrams) * profile.idleNoisePeakToPeakPenaltyScale)))
        }
        if let standardDeviation {
            score -= min(35, Int(round(max(0, standardDeviation - profile.idleStandardDeviationFreeGrams) * profile.idleStandardDeviationPenaltyScale)))
        }
        if let drift {
            score -= min(30, Int(round(abs(drift) * profile.driftPenaltyScale)))
        }
        return max(0, score)
    }

    private static func scoreDynamicStability(bumpCount: Int) -> Int {
        max(0, 100 - cappedPenalty(count: bumpCount, unit: 8, cap: 40))
    }

    private static func scoreMetadata(_ samples: [ScaleSample], batteryEventCount: Int) -> Int {
        let count = Double(max(samples.count, 1))
        let timestampCoverage = Double(samples.filter { $0.deviceTimestampMilliseconds != nil }.count) / count
        let sequenceCoverage = Double(samples.filter { $0.sequence != nil }.count) / count
        let sampleBatteryCoverage = Double(samples.filter {
            $0.batteryPercent.map { (0...100).contains($0) } == true
        }.count) / count
        let separateBatteryCoverage = batteryEventCount > 0 ? 1.0 : 0.0
        let batteryCoverage = max(sampleBatteryCoverage, separateBatteryCoverage)
        let qualityCoverage = Double(samples.filter {
            $0.firmwareQualityScore.map { (0...100).contains($0) } == true
        }.count) / count
        return Int(round(40 * timestampCoverage + 25 * sequenceCoverage + 20 * batteryCoverage + 15 * qualityCoverage))
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count >= 2 else { return [] }
        return zip(self, dropFirst()).map { ($0, $1) }
    }
}
