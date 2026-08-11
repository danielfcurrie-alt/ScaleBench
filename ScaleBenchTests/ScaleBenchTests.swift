import XCTest
@testable import ScaleBench

final class ScaleBenchTests: XCTestCase {
    func testWMBPlusCapabilitiesParse() {
        let data = Data([0x03, 0x0C, 0x01, 0x10, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x07, 0x00, 0x01, 0x14, 0x00, 0x8D])
        let capabilities = WeighMyBruParser.parseCapabilities(data)

        XCTAssertEqual(capabilities?.featureMask, 0x0000_7FFF)
        XCTAssertEqual(capabilities?.preferredAtomicCommand, 0x07)
        XCTAssertEqual(capabilities?.extensionPacketVersion, 1)
        XCTAssertEqual(capabilities?.extensionPacketLength, 20)
        XCTAssertEqual(capabilities?.supportsAtomicTareStart, true)
        XCTAssertEqual(capabilities?.supportsExtendedPacket, true)
    }

    func testWMBPlusExtendedPacketParse() throws {
        let capabilities = try XCTUnwrap(WeighMyBruParser.parseCapabilities(Data([0x03, 0x0C, 0x01, 0x10, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x07, 0x00, 0x01, 0x14, 0x00, 0x8D])))
        var bytes: [UInt8] = [
            0x03, 0x0B,
            0x00, 0x12, 0x34,
            0x01,
            0x2B, 0x00, 0x09, 0xC4,
            0x2B, 0x00, 0xFA,
            0x55,
            0xFE,
            0x43,
            0x61,
            0x0C,
            0xEC,
            0x00
        ]
        bytes[19] = xorChecksum(bytes.dropLast())

        let result = WeighMyBruParser.parse20BytePacket(Data(bytes), capabilities: capabilities, arrivalTime: Date(), monotonicSeconds: 10)

        guard case let .success(sample) = result else {
            return XCTFail("Expected success")
        }

        XCTAssertEqual(sample.scaleKind, .weighMyBruPlus)
        XCTAssertEqual(sample.deviceTimestampMilliseconds, 0x001234)
        XCTAssertEqual(sample.weightGrams, 25.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.flowGramsPerSecond), 2.5, accuracy: 0.001)
        XCTAssertEqual(sample.batteryPercent, 85)
        XCTAssertEqual(sample.sequence, 254)
        XCTAssertEqual(sample.statusFlags?.timerRunning, true)
        XCTAssertEqual(sample.statusFlags?.batteryPresent, true)
        XCTAssertEqual(sample.firmwareQualityScore, 97)
        XCTAssertEqual(sample.detectedSampleRateHz, 12)
        XCTAssertEqual(sample.diagnosticFlags?.extensionPresent, true)
        XCTAssertEqual(sample.diagnosticFlags?.detected80SPS, true)
    }

    func testBookooPacketParse() throws {
        let bytes = Data([
            0x03, 0x0B,
            0x00, 0x10, 0x00,
            0x00,
            0x2D, 0x00, 0x00, 0x64,
            0x2B, 0x00, 0xC8,
            0x63,
            0, 0, 0, 0, 0, 0
        ])

        let result = BookooParser.parseWeightPacket(bytes, arrivalTime: Date(), monotonicSeconds: 1)

        guard case let .success(sample) = result else {
            return XCTFail("Expected success")
        }

        XCTAssertEqual(sample.scaleKind, .bookoo)
        XCTAssertEqual(sample.deviceTimestampMilliseconds, 0x001000)
        XCTAssertEqual(sample.weightGrams, -1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.flowGramsPerSecond), 2.0, accuracy: 0.001)
        XCTAssertEqual(sample.batteryPercent, 99)
    }

    func testQualityAnalyzerUsesSequenceAndTimestamp() {
        let samples = [
            makePlusSample(index: 0),
            makePlusSample(index: 1),
            makePlusSample(index: 2),
            makePlusSample(index: 3),
            makePlusSample(index: 4)
        ]
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = samples

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.missingSequenceCount, 0)
        XCTAssertEqual(metrics.duplicateOrOutOfOrderTimestampCount, 0)
        XCTAssertEqual(metrics.effectiveSampleRateHz ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(metrics.metadataScore, 100)
    }

    func testStrictScoringCanBeAppliedWithoutChangingStandardProfile() {
        var recording = ScaleRecording.empty(mode: .idleStability)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.2),
            makeSample(seconds: 0.2, weight: -0.2)
        ]

        let standard = ScaleQualityAnalyzer.analyze(recording, profile: .standard)
        let strict = ScaleQualityAnalyzer.analyze(recording, profile: .strict)

        XCTAssertLessThanOrEqual(strict.stabilityScore ?? 100, standard.stabilityScore ?? 100)
        XCTAssertEqual(recording.scoringProfile.name, ScoringProfile.standard.name)
    }

    private func makeSample(seconds: Double, weight: Double) -> ScaleSample {
        ScaleSample(
            arrivalTime: Date(timeIntervalSince1970: seconds),
            monotonicSeconds: seconds,
            scaleKind: .weighMyBru,
            weightGrams: weight,
            deviceTimestampMilliseconds: nil,
            sequence: nil,
            batteryPercent: nil,
            flowGramsPerSecond: nil,
            firmwareQualityScore: nil,
            detectedSampleRateHz: nil,
            statusFlags: nil,
            diagnosticFlags: nil
        )
    }

    private func makePlusSample(index: Int) -> ScaleSample {
        ScaleSample(
            arrivalTime: Date(timeIntervalSince1970: Double(index)),
            monotonicSeconds: Double(index) * 0.1,
            scaleKind: .weighMyBruPlus,
            weightGrams: Double(index) * 0.1,
            deviceTimestampMilliseconds: UInt32(index * 100),
            sequence: UInt8(index),
            batteryPercent: 90,
            flowGramsPerSecond: nil,
            firmwareQualityScore: 95,
            detectedSampleRateHz: 10,
            statusFlags: nil,
            diagnosticFlags: ScaleDiagnosticFlags(byte: 0xA4)
        )
    }
}
