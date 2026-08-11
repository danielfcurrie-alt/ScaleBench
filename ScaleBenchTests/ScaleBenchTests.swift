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
        var packet: [UInt8] = [
            0x03, 0x0B,
            0x00, 0x10, 0x00,
            0x02,
            0x2D, 0x00, 0x00, 0x64,
            0x2B, 0x00, 0xC8,
            0x63,
            0, 30, 2, 0, 1, 0
        ]
        packet[19] = xorChecksum(packet.dropLast())
        let bytes = Data(packet)

        let result = BookooParser.parseWeightPacket(bytes, kind: .bookooUltra, arrivalTime: Date(), monotonicSeconds: 1)

        guard case let .success(sample) = result else {
            return XCTFail("Expected success")
        }

        XCTAssertEqual(sample.scaleKind, .bookooUltra)
        XCTAssertEqual(sample.deviceTimestampMilliseconds, 0x001000)
        XCTAssertEqual(sample.weightGrams, -1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.flowGramsPerSecond), 2.0, accuracy: 0.001)
        XCTAssertEqual(sample.batteryPercent, 99)
    }



    func testAcaiaPacketParse() throws {
        let frame = Data([0xEF, 0xDD, 0x0C, 0x04, 0x7B, 0x00, 0x01, 0x00, 0x7C, 0x00])
        let events = AcaiaParser.Codec().receive(frame, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .sample(sample) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected Acaia sample")
        }
        XCTAssertEqual(sample.scaleKind, .acaia)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
    }

    func testDecentPacketParse() throws {
        let data = Data([0x03, 0xCE, 0x00, 0x7B, 0x00, 0x01, 0x02, 0x03, 0x00, 0x00])
        let result = DecentEspressiParser.parseWeightPacket(data, kind: .decent, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Decent sample") }
        XCTAssertEqual(sample.scaleKind, .decent)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
        XCTAssertEqual(sample.deviceTimestampMilliseconds, 62_300)
    }

    func testDiFluidSensorAndBatteryPacketsParse() throws {
        var sensor: [UInt8] = [
            0xDF, 0xDF, 0x03, 0x00, 0x0D,
            0x00, 0x00, 0x00, 0x7B,
            0x00, 0x0C,
            0x00, 0x00,
            0x00, 0x00, 0x03, 0xE8,
            0x00,
            0x00
        ]
        sensor[18] = sensor.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
        let sensorEvent = DiFluidParser.parse(Data(sensor), kind: .difluidTi, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .sample(sample) = sensorEvent else { return XCTFail("Expected DiFluid sample") }
        XCTAssertEqual(sample.scaleKind, .difluidTi)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.flowGramsPerSecond), 1.2, accuracy: 0.001)
        XCTAssertEqual(sample.deviceTimestampMilliseconds, 1000)

        var status: [UInt8] = [0xDF, 0xDF, 0x03, 0x05, 0x08, 0x00, 0x55, 0, 0, 0, 0, 0, 0, 0]
        status[13] = status.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
        let statusEvent = DiFluidParser.parse(Data(status), kind: .difluid, arrivalTime: Date(), monotonicSeconds: 1)
        XCTAssertEqual(statusEvent, .battery(percent: 85))
    }

    func testEurekaPacketParse() throws {
        let data = Data([0xAA, 0x09, 0x41, 0x00, 0x1D, 0x00, 0x00, 0x7B, 0x00, 0x00, 0x00])
        let result = EurekaPrecisaParser.parse(data, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Eureka sample") }
        XCTAssertEqual(sample.scaleKind, .eureka)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
    }

    func testFelicitaPacketParse() throws {
        var bytes = Array(repeating: UInt8(0), count: 18)
        bytes[2] = 0x2D
        for (index, byte) in Array("001234".utf8).enumerated() {
            bytes[3 + index] = byte
        }
        let result = FelicitaParser.parse(Data(bytes), arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Felicita sample") }
        XCTAssertEqual(sample.scaleKind, .felicita)
        XCTAssertEqual(sample.weightGrams, -12.34, accuracy: 0.001)
    }

    func testFutulaPacketParse() throws {
        let data = Data([0, 0, 0, 0x7B, 0x00, 0x01, 0, 0, 0])
        let result = FutulaParser.parse(data, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Futula sample") }
        XCTAssertEqual(sample.scaleKind, .futula)
        XCTAssertEqual(sample.weightGrams, -12.3, accuracy: 0.001)
    }

    func testSkale2PacketParse() throws {
        let data = Data([0x00, 0x7B, 0x00])
        let result = Skale2Parser.parse(data, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Skale2 sample") }
        XCTAssertEqual(sample.scaleKind, .skale2)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
    }

    func testTimemoreDotPacketParse() throws {
        let frame = Data(TimemoreDotParser.frame(opcode: 0x01, command: 0x01, payload: [0x00, 0x00, 0x00, 0x7B, 0, 0, 0, 0]))
        let events = TimemoreDotParser.Codec().receive(frame, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .sample(sample) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected Timemore sample")
        }
        XCTAssertEqual(sample.scaleKind, .timemoreDot)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
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

    func testStandardScoringProfileUsesStableBenchmarkName() {
        XCTAssertEqual(ScoringProfile.standard.name, "ScaleBench Standard v1")
        XCTAssertEqual(ScoringPreset.standard.displayName, "ScaleBench Standard v1")
    }

    func testOfficialScorecardRecordingUsesStandardProfile() {
        var recording = ScaleRecording.empty(mode: .idleStability, scoringProfile: .strict)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.2),
            makeSample(seconds: 0.2, weight: -0.2)
        ]
        recording.metrics = ScaleQualityAnalyzer.analyze(recording, profile: .strict)

        let official = ScoreCardExporter.officialRecording(from: recording)
        let expectedStandard = ScaleQualityAnalyzer.analyze(recording, profile: .standard)

        XCTAssertEqual(official.scoringProfile.name, ScoringProfile.standardBenchmarkName)
        XCTAssertEqual(official.metrics, expectedStandard)
        XCTAssertNotNil(official.endedAt)
    }

    func testCustomScoringProfileStoreRoundTripsJSONAndNormalizesWeights() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBenchScoringTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var profile = ScoringProfile.strict
        profile.name = "My Strict Profile"
        profile.transportWeight = 2
        profile.stabilityWeight = 1
        profile.metadataWeight = 1

        let store = CustomScoringProfileStore(fileURL: fileURL)
        let saved = try XCTUnwrap(store.save(profile: profile))

        XCTAssertEqual(saved.profile.name, "My Strict Profile")
        XCTAssertEqual(saved.profile.transportWeight, 0.5, accuracy: 0.0001)
        XCTAssertEqual(saved.profile.stabilityWeight, 0.25, accuracy: 0.0001)
        XCTAssertEqual(saved.profile.metadataWeight, 0.25, accuracy: 0.0001)

        let reloaded = CustomScoringProfileStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.id, saved.id)
        XCTAssertEqual(reloaded.profiles.first?.profile.name, "My Strict Profile")
    }

    func testSavedRecordingStoresNotesAndScoreSnapshot() throws {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.device = ScaleDeviceIdentity(
            name: "WeighMyBru+",
            identifier: UUID(),
            kind: .weighMyBruPlus,
            advertisedServices: [WeighMyBruParser.serviceUUID]
        )
        recording.samples = [
            makePlusSample(index: 0),
            makePlusSample(index: 1),
            makePlusSample(index: 2),
            makePlusSample(index: 3),
            makePlusSample(index: 4)
        ]

        let saved = SavedScaleRecording.make(
            recording: recording,
            title: "WMB+ bench shot",
            notes: "80 SPS reference unit, no visible bumps"
        )

        XCTAssertEqual(saved.title, "WMB+ bench shot")
        XCTAssertEqual(saved.notes, "80 SPS reference unit, no visible bumps")
        XCTAssertEqual(saved.recording.notes, saved.notes)
        XCTAssertEqual(saved.protocolKind, .weighMyBruPlus)
        XCTAssertEqual(saved.scoreSnapshot.overallScore, saved.recording.metrics.overallScore)
        XCTAssertNotNil(saved.scoreSnapshot.effectiveSampleRateHz)
    }

    func testSavedRecordingStoreRoundTripsJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBenchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var recording = ScaleRecording.empty(mode: .idleStability)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.01),
            makeSample(seconds: 0.2, weight: 0.0)
        ]

        let store = SavedRecordingStore(directoryURL: directory)
        let saved = try XCTUnwrap(store.save(recording: recording, notes: "quiet table"))

        let reloaded = SavedRecordingStore(directoryURL: directory)
        XCTAssertEqual(reloaded.recordings.count, 1)
        XCTAssertEqual(reloaded.recordings.first?.id, saved.id)
        XCTAssertEqual(reloaded.recordings.first?.notes, "quiet table")
        XCTAssertEqual(reloaded.recordings.first?.scoreSnapshot.overallScore, saved.scoreSnapshot.overallScore)
    }

    func testProtocolComparisonRanksSavedRecordingsByScore() throws {
        let low = savedRecording(kind: .eureka, score: 68, title: "Eureka")
        let high = savedRecording(kind: .weighMyBruPlus, score: 95, title: "WMB+")
        let comparison = ProtocolComparison.make(from: [low, high])

        XCTAssertEqual(comparison.rows.first?.protocolKind, .weighMyBruPlus)
        XCTAssertEqual(comparison.bestOverall?.score, 95)
        XCTAssertEqual(comparison.groupedByProtocol.count, 2)
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

    private func savedRecording(kind: ScaleKind, score: Int, title: String) -> SavedScaleRecording {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.device = ScaleDeviceIdentity(
            name: title,
            identifier: UUID(),
            kind: kind,
            advertisedServices: []
        )
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.1)
        ]
        recording.metrics = ScaleQualityMetrics(
            overallScore: score,
            transportScore: score,
            stabilityScore: score,
            metadataScore: score,
            effectiveSampleRateHz: 10,
            packetIntervalP50Milliseconds: 100,
            packetIntervalP95Milliseconds: 100,
            packetIntervalMaxMilliseconds: 100,
            longGapCount: 0,
            missingSequenceCount: 0,
            duplicateOrOutOfOrderTimestampCount: 0,
            rejectedPacketCount: 0,
            idleNoisePeakToPeakGrams: nil,
            idleNoiseStandardDeviationGrams: nil,
            driftGramsPerMinute: nil,
            batteryMinPercent: nil,
            batteryMaxPercent: nil,
            firmwareQualityAverage: nil,
            firmwareBumpCount: 0
        )
        return SavedScaleRecording(
            savedAt: Date(),
            title: title,
            notes: "",
            recording: recording,
            scoreSnapshot: recording.metrics
        )
    }
}
