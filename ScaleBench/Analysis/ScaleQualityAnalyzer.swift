import Foundation

enum ScaleQualityAnalyzer {
    static func analyze(_ recording: ScaleRecording, profile inputProfile: ScoringProfile? = nil) -> ScaleQualityMetrics {
        let profile = (inputProfile ?? recording.scoringProfile).normalized
        let samples = recording.samples
        let rejected = recording.rawPackets.filter { $0.rejectionReason != nil }.count
        guard samples.count >= 2 else {
            var metrics = ScaleQualityMetrics.empty
            metrics.rejectedPacketCount = rejected
            return metrics
        }

        let intervals = sampleIntervalsMilliseconds(samples)
        let p50 = percentile(intervals, 0.50)
        let p95 = percentile(intervals, 0.95)
        let maxInterval = intervals.max()
        let duration = samples.last!.monotonicSeconds - samples.first!.monotonicSeconds
        let effectiveRate = duration > 0 ? Double(samples.count - 1) / duration : nil
        let longGapThreshold = longGapThresholdMilliseconds(for: effectiveRate, profile: profile)
        let longGaps = intervals.filter { $0 >= longGapThreshold }.count
        let missingSequence = missingSequenceCount(samples)
        let timestampIssues = duplicateOrOutOfOrderDeviceTimestamps(samples)
        let weights = samples.map(\.weightGrams)
        let noisePeakToPeak = weights.max().flatMap { maxWeight in weights.min().map { maxWeight - $0 } }
        let standardDeviation = standardDeviation(weights)
        let drift = driftGramsPerMinute(samples)
        let batteryValues = samples.compactMap(\.batteryPercent)
        let firmwareQuality = samples.compactMap(\.firmwareQualityScore)
        let bumpCount = samples.filter { $0.diagnosticFlags?.recentBump == true }.count

        let transportScore = scoreTransport(
            longGaps: longGaps,
            missingSequence: missingSequence,
            timestampIssues: timestampIssues,
            rejected: rejected,
            sampleCount: samples.count,
            profile: profile
        )
        let stabilityScore = scoreStability(
            noisePeakToPeak: noisePeakToPeak,
            standardDeviation: standardDeviation,
            drift: drift,
            profile: profile
        )
        let metadataScore = scoreMetadata(samples)
        let overall = Int(round(
            Double(transportScore) * profile.transportWeight
            + Double(stabilityScore) * profile.stabilityWeight
            + Double(metadataScore) * profile.metadataWeight
        ))

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
            firmwareQualityAverage: firmwareQuality.isEmpty ? nil : Double(firmwareQuality.reduce(0, +)) / Double(firmwareQuality.count),
            firmwareBumpCount: bumpCount
        )
    }

    private static func sampleIntervalsMilliseconds(_ samples: [ScaleSample]) -> [Double] {
        samples.adjacentPairs().map { previous, current in
            if let previousTimestamp = previous.deviceTimestampMilliseconds,
               let currentTimestamp = current.deviceTimestampMilliseconds {
                return Double(deltaUInt24(previousTimestamp, currentTimestamp))
            }
            return max(0, current.monotonicSeconds - previous.monotonicSeconds) * 1000.0
        }
    }

    private static func longGapThresholdMilliseconds(for sampleRate: Double?, profile: ScoringProfile) -> Double {
        guard let sampleRate, sampleRate > 0 else { return 500 }
        let expected = 1000.0 / sampleRate
        return max(profile.minimumLongGapMilliseconds, expected * profile.longGapMultiplier)
    }

    private static func missingSequenceCount(_ samples: [ScaleSample]) -> Int {
        let sequences = samples.compactMap(\.sequence)
        guard sequences.count >= 2 else { return 0 }

        return sequences.adjacentPairs().reduce(0) { count, pair in
            let expected = pair.0 &+ 1
            if pair.1 == expected { return count }
            let delta = Int(pair.1 &- pair.0)
            return count + max(0, delta - 1)
        }
    }

    private static func duplicateOrOutOfOrderDeviceTimestamps(_ samples: [ScaleSample]) -> Int {
        let timestamps = samples.compactMap(\.deviceTimestampMilliseconds)
        guard timestamps.count >= 2 else { return 0 }

        return timestamps.adjacentPairs().filter { previous, current in
            current == previous || deltaUInt24(previous, current) > 8_000_000
        }.count
    }

    private static func deltaUInt24(_ previous: UInt32, _ current: UInt32) -> UInt32 {
        let mask: UInt32 = 0x00FF_FFFF
        return current >= previous ? current - previous : (mask - previous) + current + 1
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

    private static func scoreTransport(
        longGaps: Int,
        missingSequence: Int,
        timestampIssues: Int,
        rejected: Int,
        sampleCount: Int,
        profile: ScoringProfile
    ) -> Int {
        var score = 100
        score -= min(40, longGaps * profile.longGapPenalty)
        score -= min(30, missingSequence * profile.missingSequencePenalty)
        score -= min(20, timestampIssues * profile.timestampIssuePenalty)
        score -= min(30, Int(round(Double(rejected) / Double(max(sampleCount, 1)) * profile.rejectedPacketRatePenaltyScale)))
        return max(0, score)
    }

    private static func scoreStability(
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

    private static func scoreMetadata(_ samples: [ScaleSample]) -> Int {
        let count = Double(max(samples.count, 1))
        let timestampCoverage = Double(samples.filter { $0.deviceTimestampMilliseconds != nil }.count) / count
        let sequenceCoverage = Double(samples.filter { $0.sequence != nil }.count) / count
        let batteryCoverage = Double(samples.filter { $0.batteryPercent != nil }.count) / count
        let qualityCoverage = Double(samples.filter { $0.firmwareQualityScore != nil }.count) / count
        return Int(round(40 * timestampCoverage + 25 * sequenceCoverage + 20 * batteryCoverage + 15 * qualityCoverage))
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count >= 2 else { return [] }
        return zip(self, dropFirst()).map { ($0, $1) }
    }
}
