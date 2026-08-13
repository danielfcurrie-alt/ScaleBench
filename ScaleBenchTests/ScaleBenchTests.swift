import XCTest
@testable import ScaleBench

final class ScaleBenchTests: XCTestCase {
    func testWMBPlusUSBSerialValidSampleParses() throws {
        var parser = WMBPlusUSBSerialParser()
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = parser.parse(
            line: "WMBP_WEIGHT_V1,123456,9821,18.423,1.731,0x0041,98,75,79.82,0",
            hostReceivedAt: receivedAt,
            hostMonotonicSeconds: 42
        )

        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB sample") }
        XCTAssertEqual(row.firmwareMillis, 123_456)
        XCTAssertEqual(row.sequenceNumber, 9_821)
        XCTAssertEqual(row.weightGrams, 18.423, accuracy: 0.000_001)
        XCTAssertEqual(row.flowGramsPerSecond, 1.731, accuracy: 0.000_001)
        XCTAssertEqual(row.firmwareQuality, 98)
        XCTAssertEqual(row.batteryPercent, 75)
        XCTAssertEqual(row.hx711Hz, 79.82, accuracy: 0.000_001)
        XCTAssertEqual(row.hostReceivedAt, receivedAt)
        XCTAssertEqual(row.hostMonotonicSeconds, 42)
        XCTAssertTrue(row.status.contains(.hx711Connected))
        XCTAssertTrue(row.status.contains(.batteryValid))
    }

    func testWMBPlusUSBSerialOptionalHeaderIsIgnored() {
        var parser = WMBPlusUSBSerialParser()
        XCTAssertEqual(
            parser.parse(line: WMBPlusUSBSerialParser.header, hostReceivedAt: Date(), hostMonotonicSeconds: 1),
            .ignored
        )
    }

    func testWMBPlusUSBSerialUnknownLineIsIgnored() {
        var parser = WMBPlusUSBSerialParser()
        XCTAssertEqual(
            parser.parse(line: "WMB+ ready", hostReceivedAt: Date(), hostMonotonicSeconds: 1),
            .ignored
        )
    }

    func testWMBPlusUSBSerialMalformedLineIsRejected() {
        var parser = WMBPlusUSBSerialParser()
        XCTAssertEqual(
            parser.parse(line: "WMBP_WEIGHT_V1,1,2", hostReceivedAt: Date(), hostMonotonicSeconds: 1),
            .rejected(.fieldCount)
        )
    }

    func testWMBPlusUSBSerialInvalidNumericFieldIsRejected() {
        var parser = WMBPlusUSBSerialParser()
        XCTAssertEqual(
            parser.parse(
                line: "WMBP_WEIGHT_V1,1,2,not-a-float,1.0,0x0041,98,75,79.82,0",
                hostReceivedAt: Date(),
                hostMonotonicSeconds: 1
            ),
            .rejected(.invalidFloat(field: "weight_g"))
        )
    }

    func testWMBPlusUSBSerialStatusHexParses() throws {
        var parser = WMBPlusUSBSerialParser()
        let result = parser.parse(
            line: "WMBP_WEIGHT_V1,1,2,3,4,0x01C5,90,80,79.9,0",
            hostReceivedAt: Date(),
            hostMonotonicSeconds: 1
        )
        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB sample") }
        XCTAssertEqual(row.status.rawValue, 0x01C5)
    }

    func testWMBPlusUSBSerialBatteryUnavailableWithoutValidBit() throws {
        var parser = WMBPlusUSBSerialParser()
        let result = parser.parse(
            line: "WMBP_WEIGHT_V1,1,2,3,4,0x0001,90,-1,79.9,0",
            hostReceivedAt: Date(),
            hostMonotonicSeconds: 1
        )
        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB sample") }
        XCTAssertNil(row.batteryPercent)
    }

    func testWMBPlusUSBSerialRejectsInvalidAvailableBattery() {
        var parser = WMBPlusUSBSerialParser()
        XCTAssertEqual(
            parser.parse(
                line: "WMBP_WEIGHT_V1,1,2,3,4,0x0041,90,101,79.9,0",
                hostReceivedAt: Date(),
                hostMonotonicSeconds: 1
            ),
            .rejected(.invalidRange(field: "battery_pct"))
        )
    }

    func testWMBPlusUSBSerialRequiresConnectedHX711ForValidWeight() throws {
        var parser = WMBPlusUSBSerialParser()
        let result = parser.parse(
            line: "WMBP_WEIGHT_V1,1,2,3,4,0x0040,90,80,79.9,0",
            hostReceivedAt: Date(),
            hostMonotonicSeconds: 1
        )
        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB row") }
        XCTAssertFalse(row.isValidWeightSample)
    }

    func testWMBPlusUSBSerialDroppedDeltaIsDetected() throws {
        var parser = WMBPlusUSBSerialParser()
        _ = parser.parse(
            line: "WMBP_WEIGHT_V1,1,2,3,4,0x0041,90,80,79.9,7",
            hostReceivedAt: Date(),
            hostMonotonicSeconds: 1
        )
        let result = parser.parse(
            line: "WMBP_WEIGHT_V1,2,3,3,4,0x0041,90,80,79.9,11",
            hostReceivedAt: Date(),
            hostMonotonicSeconds: 2
        )
        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB sample") }
        XCTAssertEqual(row.droppedDelta, 4)
    }

    func testWMBPlusUSBSerialBumpAndGlitchFlagsDecode() throws {
        var parser = WMBPlusUSBSerialParser()
        let result = parser.parse(
            line: "WMBP_WEIGHT_V1,1,2,3,4,0x000D,90,80,79.9,0",
            hostReceivedAt: Date(),
            hostMonotonicSeconds: 1
        )
        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB sample") }
        XCTAssertTrue(row.status.contains(.recentBump))
        XCTAssertTrue(row.status.contains(.recentGlitch))
        XCTAssertTrue(row.status.labels.contains("Recent bump"))
        XCTAssertTrue(row.status.labels.contains("Recent glitch"))
    }

    func testWMBPlusUSBSerialRequiresExactFieldCount() {
        var parser = WMBPlusUSBSerialParser()
        let tooMany = "WMBP_WEIGHT_V1,1,2,3,4,0x0041,90,80,79.9,0,extra"
        XCTAssertEqual(
            parser.parse(line: tooMany, hostReceivedAt: Date(), hostMonotonicSeconds: 1),
            .rejected(.fieldCount)
        )
    }

    func testWMBPlusUSBSerialLineBufferHandlesPartialLines() {
        var buffer = USBSerialLineBuffer()
        XCTAssertTrue(buffer.append(Data("WMBP_WEIGHT".utf8)).isEmpty)
        XCTAssertEqual(
            buffer.append(Data("_V1,1,2,3,4,0x0041,90,80,79.9,0\r\n".utf8)),
            ["WMBP_WEIGHT_V1,1,2,3,4,0x0041,90,80,79.9,0"]
        )
    }

    func testWMBPlusUSBSerialScoringUsesDeviceCadenceAndDroppedFrames() throws {
        var parser = WMBPlusUSBSerialParser()
        var recording = ScaleRecording.empty(mode: .shot)
        recording.source = .usbSerial
        recording.protocolName = WMBPlusUSBSerialRow.protocolName
        recording.serialBaud = WMBPlusUSBSerialRow.baud
        recording.recordingStartMonotonicSeconds = 100
        recording.recordingEndMonotonicSeconds = 120.05
        recording.protocolCapabilities = ProtocolScoringCapabilities(
            hasChecksum: false,
            hasSequence: true,
            sequenceModulus: UInt64(UInt32.max) + 1,
            hasDeviceClock: true,
            deviceClockSemantics: .freeRunning,
            deviceClockModulus: UInt64(UInt32.max) + 1
        )

        for index in 0...400 {
            let sequence = index < 200 ? index : index + 10
            let dropped = index < 200 ? 0 : 10
            let line = "WMBP_WEIGHT_V1,\(index * 50),\(sequence),\(Double(index) * 0.02),0.4,0x0041,98,75,80.0,\(dropped)"
            let result = parser.parse(
                line: line,
                hostReceivedAt: Date(timeIntervalSince1970: Double(index) / 1_000),
                hostMonotonicSeconds: 100 + Double(index) / 1_000
            )
            guard case let .sample(row) = result else { return XCTFail("Expected row \(index)") }
            let sample = row.sample
            recording.samples.append(sample)
            recording.rawPackets.append(RawScalePacket(
                arrivalTime: row.hostReceivedAt,
                monotonicSeconds: row.hostMonotonicSeconds,
                scaleKind: .weighMyBruPlus,
                characteristicUUID: "USB-SERIAL-115200",
                role: .weight,
                bytesHex: Data(line.utf8).hexString,
                rejectionReason: nil,
                weightGrams: row.weightGrams,
                deviceTimestampMilliseconds: row.firmwareMillis,
                fields: row.fields,
                usbSerial: row.metadata
            ))
        }

        let metrics = ScaleQualityAnalyzer.analyze(recording)
        XCTAssertEqual(try XCTUnwrap(metrics.effectiveSampleRateHz), 20, accuracy: 0.1)
        XCTAssertEqual(metrics.missingSequenceCount, 10)
        XCTAssertEqual(try XCTUnwrap(metrics.delivery?.purity), 401.0 / 411.0, accuracy: 0.000_001)
        XCTAssertLessThan(try XCTUnwrap(metrics.transportScore), 100)
    }

    func testWMBPlusUSBSerialSharedExportRoundTrip() throws {
        var parser = WMBPlusUSBSerialParser()
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let line = "WMBP_WEIGHT_V1,4294967290,4294967291,18.423,1.731,0x004D,98,75,79.82,4"
        let result = parser.parse(
            line: line,
            hostReceivedAt: receivedAt,
            hostMonotonicSeconds: 42
        )
        guard case let .sample(row) = result else { return XCTFail("Expected a parsed USB sample") }

        var recording = ScaleRecording.empty(mode: .shot)
        recording.source = .usbSerial
        recording.protocolName = WMBPlusUSBSerialRow.protocolName
        recording.serialBaud = WMBPlusUSBSerialRow.baud
        recording.device = ScaleDeviceIdentity(
            name: "WMB+ USB",
            identifier: "/dev/cu.usbmodem-test",
            kind: .weighMyBruPlus,
            advertisedServices: []
        )
        recording.samples = [row.sample]
        recording.rawPackets = [RawScalePacket(
            arrivalTime: receivedAt,
            monotonicSeconds: 42,
            scaleKind: .weighMyBruPlus,
            characteristicUUID: "USB-SERIAL-115200",
            role: .weight,
            bytesHex: Data(line.utf8).hexString,
            weightGrams: row.weightGrams,
            deviceTimestampMilliseconds: row.firmwareMillis,
            fields: row.fields,
            usbSerial: row.metadata
        )]

        let data = try SharedRecordingCodec.exportData(from: recording, recalculateMetrics: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "usbSerial")
        XCTAssertEqual(object["protocol"] as? String, WMBPlusUSBSerialRow.protocolName)
        XCTAssertEqual(object["serialBaud"] as? Int, 115_200)
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.first?["firmwareMillis"] as? UInt32, row.firmwareMillis)
        XCTAssertEqual(samples.first?["sequenceNumber"] as? UInt32, row.sequenceNumber)
        XCTAssertEqual(samples.first?["usbStatusRaw"] as? UInt16, row.status.rawValue)
        XCTAssertEqual(samples.first?["usbDroppedCumulative"] as? UInt32, 4)

        let decoded = try SharedRecordingCodec.decodeRecording(from: data)
        XCTAssertEqual(decoded.source, .usbSerial)
        XCTAssertEqual(decoded.protocolName, WMBPlusUSBSerialRow.protocolName)
        XCTAssertEqual(decoded.serialBaud, 115_200)
        XCTAssertEqual(decoded.samples.first?.usbSerial, row.metadata)
        XCTAssertEqual(decoded.rawPackets.first?.usbSerial, row.metadata)
    }

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

    func testSharedPacketFieldContractAndRuntimeHex() throws {
        XCTAssertEqual(PacketFieldDecoder.normalizedHex("030B00"), "03 0B 00")
        for fileName in ["packet-fields.json", "packet-fields-bookoo.json"] {
            let fixture = try JSONDecoder().decode(
                PacketFieldFixture.self,
                from: sharedFixtureData(fileName)
            )
            let bytes = try XCTUnwrap(PacketFieldDecoder.bytes(fromHex: fixture.bytesHex))
            XCTAssertEqual(Data(bytes).hexString, fixture.bytesHex)
            XCTAssertEqual(
                PacketFieldDecoder.annotations(
                    scaleKind: fixture.scaleKind,
                    characteristicUUID: fixture.characteristicUUID,
                    bytes: bytes
                ),
                fixture.fields,
                fileName
            )
        }
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

    func testAcaiaPacketRejectsBadChecksum() throws {
        let frame = Data([0xEF, 0xDD, 0x0C, 0x04, 0x7B, 0x00, 0x01, 0x00, 0x7D, 0x00])
        let events = AcaiaParser.Codec().receive(frame, arrivalTime: Date(), monotonicSeconds: 1)

        guard case .rejected(.invalidChecksum)? = events.first else {
            return XCTFail("Expected invalid checksum rejection")
        }
    }

    func testAcaiaPacketHandlesMinimumInt16WeightWithoutOverflow() throws {
        let frame = Data([0xEF, 0xDD, 0x0C, 0x04, 0x00, 0x80, 0x00, 0x00, 0x00, 0x80])
        let events = AcaiaParser.Codec().receive(frame, arrivalTime: Date(), monotonicSeconds: 1)

        guard case let .sample(sample) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected Acaia sample")
        }
        XCTAssertEqual(sample.weightGrams, 32_768, accuracy: 0.001)
    }

    func testDecentPacketParse() throws {
        let data = Data([0x03, 0xCE, 0x00, 0x7B, 0x00, 0x01, 0x02, 0x03, 0x00, 0x00])
        let result = DecentEspressiParser.parseWeightPacket(data, kind: .decent, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Decent sample") }
        XCTAssertEqual(sample.scaleKind, .decent)
        XCTAssertEqual(sample.weightGrams, 12.3, accuracy: 0.001)
        XCTAssertEqual(sample.deviceTimestampMilliseconds, 62_300)
    }

    func testDecentZeroTimerTimestampIsIgnored() throws {
        let data = Data([0x03, 0xCE, 0x00, 0x7B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let result = DecentEspressiParser.parseWeightPacket(data, kind: .decent, arrivalTime: Date(), monotonicSeconds: 1)
        guard case let .success(sample) = result else { return XCTFail("Expected Decent sample") }
        XCTAssertNil(sample.deviceTimestampMilliseconds)
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

    func legacyTransportScoringUsesHostArrivalIntervalsEvenWhenDeviceTimestampsArePerfect() throws {
        let hostTimes = [0.00, 0.01, 0.02, 0.03, 0.04, 0.52, 0.53, 0.54, 0.55, 0.56]
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = hostTimes.enumerated().map { index, seconds in
            var sample = makePlusSample(index: index)
            sample.monotonicSeconds = seconds
            sample.arrivalTime = Date(timeIntervalSince1970: seconds)
            sample.deviceTimestampMilliseconds = UInt32(index * 100)
            return sample
        }

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(try XCTUnwrap(metrics.packetIntervalP50Milliseconds), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.packetIntervalMaxMilliseconds), 480, accuracy: 0.001)
        XCTAssertEqual(metrics.longGapCount, 1)
        XCTAssertLessThan(try XCTUnwrap(metrics.transportScore), 100)
    }

    func legacyStandardScoreDoesNotDeductMissingOptionalMetadata() throws {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = (0..<12).map { index in
            makeSample(seconds: Double(index) * 0.1, weight: Double(index) * 0.2)
        }

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.metadataScore, 0)
        XCTAssertEqual(metrics.overallScore, 100)
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

    func legacyShotScoringDoesNotTreatBeverageGrowthAsInstability() {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 1.0, weight: 4.0),
            makeSample(seconds: 2.0, weight: 12.0),
            makeSample(seconds: 3.0, weight: 24.0),
            makeSample(seconds: 4.0, weight: 36.0)
        ]

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.stabilityScore, 100)
        XCTAssertNil(metrics.idleNoisePeakToPeakGrams)
        XCTAssertNil(metrics.driftGramsPerMinute)
    }

    func testLongGapDetectionUsesTypicalCadenceInsteadOfWholeRecordingAverage() {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.1),
            makeSample(seconds: 0.2, weight: 0.2),
            makeSample(seconds: 1.0, weight: 0.3)
        ]
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = 1.01

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.longGapCount, 1)
        XCTAssertEqual(metrics.packetIntervalMaxMilliseconds ?? 0, 800, accuracy: 0.001)
    }

    func testSeparateBatteryEventsCountTowardMetadataAndBatteryRange() {
        var recording = ScaleRecording.empty(mode: .batteryStability)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.0),
            makeSample(seconds: 0.2, weight: 0.0)
        ]
        recording.batteryEvents = [
            ScaleBatteryEvent(arrivalTime: Date(timeIntervalSince1970: 0), monotonicSeconds: 0.05, scaleKind: .weighMyBruPlus, percent: 86),
            ScaleBatteryEvent(arrivalTime: Date(timeIntervalSince1970: 1), monotonicSeconds: 1.05, scaleKind: .weighMyBruPlus, percent: 84)
        ]

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.batteryMinPercent, 84)
        XCTAssertEqual(metrics.batteryMaxPercent, 86)
        XCTAssertGreaterThanOrEqual(metrics.metadataScore ?? 0, 20)
    }

    func testBatteryOnlyRecordingStillReportsBatteryRange() {
        var recording = ScaleRecording.empty(mode: .batteryStability)
        recording.batteryEvents = [
            ScaleBatteryEvent(arrivalTime: Date(timeIntervalSince1970: 0), monotonicSeconds: 0, scaleKind: .weighMyBru, percent: 91),
            ScaleBatteryEvent(arrivalTime: Date(timeIntervalSince1970: 1), monotonicSeconds: 1, scaleKind: .weighMyBru, percent: 89)
        ]

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertNil(metrics.overallScore)
        XCTAssertEqual(metrics.batteryMinPercent, 89)
        XCTAssertEqual(metrics.batteryMaxPercent, 91)
    }

    func legacyDynamicStabilityCountsContiguousBumpFlagsAsOneEvent() {
        var samples = (0..<5).map { makeSample(seconds: Double($0) * 0.1, weight: Double($0)) }
        samples[0].diagnosticFlags = ScaleDiagnosticFlags(byte: 0x01)
        samples[1].diagnosticFlags = ScaleDiagnosticFlags(byte: 0x01)
        samples[3].diagnosticFlags = ScaleDiagnosticFlags(byte: 0x01)
        samples[4].diagnosticFlags = ScaleDiagnosticFlags(byte: 0x01)
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = samples

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.firmwareBumpCount, 2)
        XCTAssertEqual(metrics.stabilityScore, 84)
    }

    func legacyDynamicStabilityInfersTransientWeightSpikeAsBump() {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.2),
            makeSample(seconds: 0.2, weight: 5.4),
            makeSample(seconds: 0.3, weight: 0.4),
            makeSample(seconds: 0.4, weight: 0.6)
        ]

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.firmwareBumpCount, 1)
        XCTAssertEqual(metrics.stabilityScore, 92)
    }

    func testDuplicateAndReverseSequenceValuesDoNotInflateMissingCount() {
        var first = makePlusSample(index: 0)
        var second = makePlusSample(index: 1)
        first.sequence = 100
        second.sequence = 99
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = [first, second]
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = 0.2
        XCTAssertEqual(ScaleQualityAnalyzer.analyze(recording).missingSequenceCount, 0)

        second.sequence = 100
        recording.samples = [first, second]
        XCTAssertEqual(ScaleQualityAnalyzer.analyze(recording).missingSequenceCount, 0)
    }

    func legacyRejectedPacketPenaltyUsesAllParseAttemptsAsRateDenominator() {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = (0..<90).map { makeSample(seconds: Double($0) * 0.1, weight: 0) }
        recording.rawPackets = (0..<10).map { index in
            RawScalePacket(
                arrivalTime: Date(timeIntervalSince1970: Double(index)),
                monotonicSeconds: Double(index),
                scaleKind: .weighMyBru,
                characteristicUUID: WeighMyBruParser.weight20UUID,
                role: .weight,
                bytesHex: "00",
                rejectionReason: .invalidLength
            )
        }

        XCTAssertEqual(ScaleQualityAnalyzer.analyze(recording).transportScore, 90)
    }

    func legacyCadenceJitterPenalizesTransportBeforeLongGapThreshold() throws {
        let times = [
            0.00,
            0.10,
            0.20,
            0.30,
            0.40,
            0.58,
            0.68,
            0.78,
            0.88,
            0.98,
            1.16,
            1.26
        ]
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = times.map { makeSample(seconds: $0, weight: $0) }

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.longGapCount, 0)
        XCTAssertLessThan(try XCTUnwrap(metrics.transportScore), 100)
        XCTAssertLessThan(try XCTUnwrap(metrics.overallScore), 90)
    }

    func testFullWidthDeviceTimestampRolloverUsesUInt32Range() throws {
        var first = makeSample(seconds: 0, weight: 0)
        first.scaleKind = .difluid
        first.deviceTimestampMilliseconds = UInt32.max - 49
        var second = makeSample(seconds: 0.1, weight: 0)
        second.scaleKind = .difluid
        second.deviceTimestampMilliseconds = 50
        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = [first, second]
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = 0.2

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(try XCTUnwrap(metrics.packetIntervalP50Milliseconds), 100, accuracy: 0.001)
        XCTAssertEqual(metrics.duplicateOrOutOfOrderTimestampCount, 0)
    }

    func testStandardV1RateAnchors() throws {
        let clean20 = ScaleQualityAnalyzer.analyze(shotRecording(hertz: 20, seconds: 30))
        XCTAssertEqual(clean20.scoringModelVersion, "standard-1.0.0")
        XCTAssertEqual(clean20.delivery?.deliveryScore, 100)
        XCTAssertEqual(try XCTUnwrap(clean20.delivery?.coverage), 1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(clean20.delivery?.purity), 1, accuracy: 0.000001)

        let clean10 = ScaleQualityAnalyzer.analyze(shotRecording(hertz: 10, seconds: 30))
        XCTAssertEqual(clean10.delivery?.deliveryScore, 50)
        XCTAssertEqual(try XCTUnwrap(clean10.delivery?.coverage), 0.5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(clean10.delivery?.purity), 1, accuracy: 0.000001)
    }

    func testGoldenScoringVectors() throws {
        let bundle = Bundle(for: Self.self)
        let root = try XCTUnwrap(
            bundle.url(forResource: "vectors", withExtension: nil),
            "Golden scoring vectors must be bundled with the test target"
        )
        let decoder = JSONDecoder()
        let index = try decoder.decode(VectorIndex.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
        XCTAssertEqual(index.scoringModelVersion, ScaleQualityAnalyzer.scoringModelVersion)

        let requestedVector = ProcessInfo.processInfo.environment["SCALEBENCH_VECTOR_ID"]
        for entry in index.vectors where requestedVector == nil || requestedVector == entry.vectorId {
            try XCTContext.runActivity(named: entry.vectorId) { _ in
                let directory = root.appendingPathComponent(entry.vectorId, isDirectory: true)
                let input = try decoder.decode(VectorInput.self, from: Data(contentsOf: directory.appendingPathComponent("input.json")))
                let expected = try decoder.decode(VectorExpected.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
                let metrics = ScaleQualityAnalyzer.analyze(input.recording())
                assertVector(metrics, equals: expected, vector: entry.vectorId)
            }
        }
    }

    func testChartAnalysisFindsGapsAndPacketPenalties() {
        var recording = shotRecording(hertz: 20, seconds: 30)
        recording.samples.removeAll { $0.monotonicSeconds > 5 && $0.monotonicSeconds < 5.5 }
        recording.rawPackets = recording.samples.enumerated().map { index, sample in
            RawScalePacket(
                arrivalTime: sample.arrivalTime,
                monotonicSeconds: sample.monotonicSeconds,
                scaleKind: sample.scaleKind,
                characteristicUUID: "VECTOR",
                role: .weight,
                bytesHex: "",
                rejectionReason: index == 10 ? .invalidChecksum : nil,
                weightGrams: index == 10 ? nil : sample.weightGrams,
                sequence: sample.sequence,
                deviceTimestampMilliseconds: sample.deviceTimestampMilliseconds
            )
        }
        let metrics = ScaleQualityAnalyzer.analyze(recording)

        let analysis = ChartAnalysis.make(recording: recording, metrics: metrics)

        XCTAssertEqual(analysis.weightPoints.count, recording.samples.count)
        XCTAssertEqual(analysis.packetTimeline.scoringGaps.count, 1)
        XCTAssertTrue(analysis.packetTimeline.entries.contains { $0.severity == .penalty })
        XCTAssertEqual(analysis.problemWindows.first?.category, .gap)
        XCTAssertEqual(analysis.deductionBreakdown.first?.category, .gap)
    }

    func testLegacyWMBPlusDualTransportUsesTwentyByteStreamOnly() {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.device = ScaleDeviceIdentity(name: "Legacy WMB+", identifier: "legacy", kind: .weighMyBru, advertisedServices: [])
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = 30

        for index in 0..<300 {
            let baseTime = Double(index) / 10.0
            let weight = Double(index) / 100.0
            let twentyByteSample = makeSample(seconds: baseTime, weight: weight)
            let floatSample = makeSample(seconds: baseTime + 0.002, weight: weight)
            recording.samples.append(twentyByteSample)
            recording.samples.append(floatSample)
            recording.rawPackets.append(RawScalePacket(
                arrivalTime: twentyByteSample.arrivalTime,
                monotonicSeconds: twentyByteSample.monotonicSeconds,
                scaleKind: .weighMyBru,
                characteristicUUID: WeighMyBruParser.weight20UUID,
                role: .weight,
                bytesHex: "",
                weightGrams: weight
            ))
            recording.rawPackets.append(RawScalePacket(
                arrivalTime: floatSample.arrivalTime,
                monotonicSeconds: floatSample.monotonicSeconds,
                scaleKind: .weighMyBru,
                characteristicUUID: WeighMyBruParser.float32UUID,
                role: .weight,
                bytesHex: "",
                weightGrams: weight
            ))
        }

        let metrics = ScaleQualityAnalyzer.analyze(recording)
        let analysis = ChartAnalysis.make(recording: recording, metrics: metrics)

        XCTAssertEqual(metrics.usableSampleCount, 300)
        XCTAssertEqual(metrics.effectiveSampleRateHz ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(analysis.weightPoints.count, 300)
    }

    func testChartAnalysisUsesRecordingStartForEverySeries() {
        var recording = shotRecording(hertz: 20, seconds: 3)
        recording.samples.removeAll { $0.monotonicSeconds < 1 }
        recording.rawPackets = recording.samples.map { sample in
            RawScalePacket(
                arrivalTime: sample.arrivalTime,
                monotonicSeconds: sample.monotonicSeconds,
                scaleKind: sample.scaleKind,
                characteristicUUID: "WEIGHT",
                role: .weight,
                bytesHex: "",
                weightGrams: sample.weightGrams,
                sequence: sample.sequence,
                deviceTimestampMilliseconds: sample.deviceTimestampMilliseconds
            )
        }
        recording.rawPackets.append(
            RawScalePacket(
                arrivalTime: Date(timeIntervalSince1970: 0.25),
                monotonicSeconds: 0.25,
                scaleKind: .weighMyBru,
                characteristicUUID: "BATTERY",
                role: .battery,
                bytesHex: "64",
                weightGrams: nil
            )
        )

        let analysis = ChartAnalysis.make(
            recording: recording,
            metrics: ScaleQualityAnalyzer.analyze(recording)
        )

        XCTAssertEqual(analysis.weightPoints[0].seconds, 1, accuracy: 0.0001)
        XCTAssertEqual(analysis.packetTimeline.entries[0].relativeSeconds, 0.25, accuracy: 0.0001)
        XCTAssertEqual(analysis.packetTimeline.sampleIntervals[0].previousRelativeSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(analysis.packetTimeline.sampleIntervals[0].relativeSeconds, 1, accuracy: 0.0001)
        XCTAssertEqual(analysis.packetTimeline.scoringGaps[0].startRelativeSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(analysis.packetTimeline.durationSeconds, 3, accuracy: 0.0001)
    }

    func testSignalDiagnosticsMeasureFlowClockAndPacketGrouping() throws {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = 20
        recording.device = ScaleDeviceIdentity(
            name: "Diagnostic WMB+",
            identifier: UUID().uuidString,
            kind: .weighMyBruPlus,
            advertisedServices: []
        )
        recording.protocolCapabilities = ProtocolScoringCapabilities(
            hasChecksum: true,
            hasSequence: true,
            sequenceModulus: 256,
            hasDeviceClock: true,
            deviceClockSemantics: .freeRunning,
            deviceClockModulus: UInt64(1) << 24
        )
        recording.samples = (0..<400).map { index in
            let seconds = Double(index) / 20
            return ScaleSample(
                arrivalTime: Date(timeIntervalSince1970: seconds),
                monotonicSeconds: seconds,
                scaleKind: .weighMyBruPlus,
                weightGrams: 20 + seconds + 2 * sin(0.8 * seconds),
                deviceTimestampMilliseconds: UInt32((seconds * 1_000 * 1.0001).rounded()),
                sequence: UInt8(index % 256),
                batteryPercent: nil,
                flowGramsPerSecond: 1 + 1.6 * cos(0.8 * (seconds - 0.2)),
                firmwareQualityScore: nil,
                detectedSampleRateHz: 20,
                statusFlags: nil,
                diagnosticFlags: nil
            )
        }

        let analysis = ChartAnalysis.make(
            recording: recording,
            metrics: ScaleQualityAnalyzer.analyze(recording)
        )
        let flow = try XCTUnwrap(analysis.signalDiagnostics.flowValidation)
        XCTAssertLessThan(flow.medianAbsoluteErrorGramsPerSecond, 0.08)
        XCTAssertEqual(try XCTUnwrap(flow.lagMilliseconds), 200, accuracy: 51)
        let clock = try XCTUnwrap(analysis.signalDiagnostics.clockSkew)
        XCTAssertEqual(clock.skewPartsPerMillion, 100, accuracy: 20)
        let packet = try XCTUnwrap(analysis.signalDiagnostics.packetCoalescing)
        XCTAssertEqual(packet.framesPerServedSlot, 1, accuracy: 0.01)

        recording.device?.kind = .decent
        recording.protocolCapabilities?.deviceClockSemantics = .shotTimer
        XCTAssertNil(
            ChartAnalysis.make(recording: recording, metrics: ScaleQualityAnalyzer.analyze(recording))
                .signalDiagnostics.clockSkew
        )
    }

    func testOfficialAnalysisPayloadExportsSharedContract() throws {
        var recording = shotRecording(hertz: 20, seconds: 30)
        recording.samples.removeAll { $0.monotonicSeconds > 5 && $0.monotonicSeconds < 5.5 }
        recording.rawPackets = recording.samples.enumerated().map { index, sample in
            RawScalePacket(
                arrivalTime: sample.arrivalTime,
                monotonicSeconds: sample.monotonicSeconds,
                scaleKind: sample.scaleKind,
                characteristicUUID: "VECTOR",
                role: .weight,
                bytesHex: "00",
                rejectionReason: index == 10 ? .invalidChecksum : nil,
                weightGrams: index == 10 ? nil : sample.weightGrams,
                sequence: sample.sequence,
                deviceTimestampMilliseconds: sample.deviceTimestampMilliseconds
            )
        }

        let payload = OfficialAnalysisPayload.make(
            from: recording,
            generatedAt: Date(timeIntervalSince1970: 1_785_600_005)
        )

        XCTAssertEqual(payload.schemaVersion, OfficialAnalysisPayload.schemaVersion)
        XCTAssertEqual(payload.recordingId, recording.id)
        XCTAssertEqual(payload.chartAnalysis.schemaVersion, ChartAnalysis.schemaVersion)
        XCTAssertEqual(payload.chartAnalysis.weightPoints.count, recording.samples.count)
        XCTAssertEqual(payload.chartAnalysis.packetTimeline.scoringGaps.count, 1)
        XCTAssertTrue(payload.chartAnalysis.packetTimeline.entries.contains { $0.severity == "penalty" })
        XCTAssertEqual(payload.chartAnalysis.problemWindows.first?.category, "gap")
        XCTAssertEqual(payload.chartAnalysis.deductionBreakdown.first?.category, "gap")
        XCTAssertNotNil(payload.chartAnalysis.signalDiagnostics.packetCoalescing)

        let exportedAnalysis = try payload.exportData()
        try writeContractOutput(exportedAnalysis, named: "ios-analysis.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedAnalysis) as? [String: Any])
        let chartObject = try XCTUnwrap(object["chartAnalysis"] as? [String: Any])
        try writeContractOutput(
            JSONSerialization.data(withJSONObject: chartObject, options: [.prettyPrinted, .sortedKeys]),
            named: "ios-chart-analysis.json"
        )
        let timelineObject = try XCTUnwrap(chartObject["packetTimeline"] as? [String: Any])
        XCTAssertNotNil(timelineObject["longGapThresholdMilliseconds"])
    }

    func testOfficialAnalysisFixtureDecodesAndRoundTrips() throws {
        let fixture = try JSONDecoder().decode(
            OfficialAnalysisPayload.self,
            from: sharedFixtureData("official-analysis.json")
        )

        XCTAssertEqual(fixture.schemaVersion, OfficialAnalysisPayload.schemaVersion)
        XCTAssertEqual(fixture.recordingId.uuidString.lowercased(), "44444444-4444-4444-8444-444444444444")
        XCTAssertEqual(fixture.protocolKind, .weighMyBruPlus)
        XCTAssertEqual(fixture.chartAnalysis.packetTimeline.entries.count, 2)
        XCTAssertEqual(fixture.chartAnalysis.packetTimeline.entries.first?.bytesHex, "03 0B 00")
        XCTAssertEqual(fixture.chartAnalysis.signalDiagnostics.packetCoalescing?.framesPerServedSlot, 1)

        let roundTrip = try JSONDecoder().decode(OfficialAnalysisPayload.self, from: fixture.exportData())
        XCTAssertEqual(roundTrip, fixture)
    }

    func testSharedRecordingFixturesDecodeOnSwift() throws {
        let iosRecording = try sharedFixtureObject("ios-recording.json")
        XCTAssertEqual(iosRecording["id"] as? String, "11111111-aaaa-4aaa-8aaa-111111111111")
        XCTAssertEqual(iosRecording["platform"] as? String, "ios")
        XCTAssertEqual(iosRecording["title"] as? String, "Fixture iOS WMB+ Shot")
        XCTAssertEqual(iosRecording["mode"] as? String, "shot")
        XCTAssertNotNil(iosRecording["startedAtMillis"])
        XCTAssertNil(iosRecording["startedAt"])
        XCTAssertEqual((iosRecording["device"] as? [String: Any])?["kind"] as? String, "weighMyBruPlus")
        XCTAssertEqual((iosRecording["samples"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((iosRecording["rawPackets"] as? [[String: Any]])?.count, 3)
        let decodedIOS = try SharedRecordingCodec.decodeRecording(from: sharedFixtureData("ios-recording.json"))
        XCTAssertEqual(decodedIOS.samples.first?.statusFlags?.timerRunning, true)
        XCTAssertEqual(decodedIOS.samples.first?.diagnosticFlags?.recentBump, true)

        let androidRecording = try sharedFixtureObject("android-recording.json")
        XCTAssertEqual(androidRecording["id"] as? String, "22222222-bbbb-4bbb-8bbb-222222222222")
        XCTAssertEqual(androidRecording["platform"] as? String, "android")
        XCTAssertEqual(androidRecording["title"] as? String, "Fixture Android Eureka Shot")
        XCTAssertEqual((androidRecording["device"] as? [String: Any])?["kind"] as? String, "eureka")
        let androidPackets = try XCTUnwrap(androidRecording["rawPackets"] as? [[String: Any]])
        XCTAssertEqual(androidPackets.count, 3)
        XCTAssertEqual(androidPackets[1]["rejectionReason"] as? String, "invalidLength")
        let decodedAndroid = try SharedRecordingCodec.decodeRecording(from: sharedFixtureData("android-recording.json"))
        XCTAssertEqual(decodedAndroid.device?.identifier, "AA:BB:CC:DD:EE:FF")
        let reexported = try SharedRecordingCodec.exportData(from: decodedAndroid)
        let reexportedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: reexported) as? [String: Any])
        XCTAssertEqual((reexportedObject["device"] as? [String: Any])?["identifier"] as? String, "AA:BB:CC:DD:EE:FF")
    }

    func testSwiftRecordingExportUsesSharedSchemaShape() throws {
        var recording = SampleRecordingFactory.examples[0].recording
        recording.events = [
            ScaleRecordingEvent(type: .disconnect, monotonicSeconds: 12.5),
            ScaleRecordingEvent(type: .reconnect, monotonicSeconds: 13),
            ScaleRecordingEvent(type: .appBackgrounded, monotonicSeconds: 14),
            ScaleRecordingEvent(type: .appForegrounded, monotonicSeconds: 15),
        ]
        let data = try SharedRecordingCodec.exportData(from: recording)
        try writeContractOutput(data, named: "ios-recording.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(object["startedAtMillis"])
        XCTAssertNil(object["startedAt"])
        XCTAssertEqual(object["mode"] as? String, "shot")
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertNotNil(samples.first?["arrivalTimeMillis"])
        XCTAssertNil(samples.first?["arrivalTime"])

        XCTAssertEqual((object["device"] as? [String: Any])?["kind"] as? String, recording.device?.kind.rawValue)
        XCTAssertEqual(object["id"] as? String, recording.id.uuidString)
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, [
            "disconnect", "reconnect", "appBackgrounded", "appForegrounded",
        ])
        XCTAssertNil(events.first?["id"])
    }

    func testSharedRecordingImportRejectsInvalidContractValues() throws {
        let fixture = try sharedFixtureObject("ios-recording.json")

        var unknownMode = fixture
        unknownMode["mode"] = "mystery"
        XCTAssertThrowsError(
            try SharedRecordingCodec.decodeRecording(
                from: JSONSerialization.data(withJSONObject: unknownMode)
            )
        )

        var oldSchema = fixture
        oldSchema["schemaVersion"] = 5
        XCTAssertThrowsError(
            try SharedRecordingCodec.decodeRecording(
                from: JSONSerialization.data(withJSONObject: oldSchema)
            )
        )

        var compactHex = fixture
        var packets = try XCTUnwrap(compactHex["rawPackets"] as? [[String: Any]])
        packets[0]["bytesHex"] = "030B00"
        compactHex["rawPackets"] = packets
        XCTAssertThrowsError(
            try SharedRecordingCodec.decodeRecording(
                from: JSONSerialization.data(withJSONObject: compactHex)
            )
        )
    }

    func testOfficialScorecardPayloadFixtureAndExport() throws {
        let fixture = try JSONDecoder().decode(OfficialScorecardPayload.self, from: sharedFixtureData("official-scorecard.json"))
        XCTAssertEqual(fixture.schemaVersion, OfficialScorecardPayload.schemaVersion)
        XCTAssertEqual(fixture.score, 100)
        XCTAssertEqual(fixture.protocolKind, .weighMyBruPlus)
        XCTAssertEqual(fixture.scoringProfileName, ScoringProfile.standardBenchmarkName)
        XCTAssertEqual(fixture.mode, .shot)

        let encoded = try fixture.exportData()
        try writeContractOutput(encoded, named: "ios-scorecard.json")
        let roundTrip = try JSONDecoder().decode(OfficialScorecardPayload.self, from: encoded)
        XCTAssertEqual(roundTrip, fixture)
    }

    func testSequenceHighWaterRejectsConsecutiveBackwardValues() {
        var recording = shotRecording(hertz: 20, seconds: 30)
        for index in recording.samples.indices {
            recording.samples[index].sequence = UInt8(truncatingIfNeeded: index)
        }
        recording.samples[100].sequence = 90
        recording.samples[101].sequence = 95
        recording.protocolCapabilities = ProtocolScoringCapabilities(
            hasChecksum: false,
            hasSequence: true,
            sequenceModulus: 256,
            hasDeviceClock: false,
            deviceClockSemantics: .none,
            deviceClockModulus: nil
        )

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.frameClassification?.outOfOrder, 2)
    }

    func testShotTimerDoesNotClassifyStaleFrames() {
        var recording = shotRecording(hertz: 20, seconds: 30)
        for index in recording.samples.indices {
            let seconds = recording.samples[index].monotonicSeconds
            recording.samples[index].deviceTimestampMilliseconds = UInt32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000)
        }
        recording.protocolCapabilities = ProtocolScoringCapabilities(
            hasChecksum: false,
            hasSequence: false,
            sequenceModulus: nil,
            hasDeviceClock: true,
            deviceClockSemantics: .shotTimer,
            deviceClockModulus: nil
        )

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.frameClassification?.stale, 0)
        XCTAssertEqual(metrics.delivery?.deliveryScore, 100)
    }

    func testTransportStressDoesNotApplyShotPhysics() {
        var recording = timedRecording(mode: .transportStress, hertz: 20, seconds: 130)
        for index in recording.samples.indices {
            recording.samples[index].weightGrams = index.isMultiple(of: 2) ? -100 : 100
        }

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.frameClassification?.implausible, 0)
        XCTAssertEqual(metrics.delivery?.deliveryScore, 100)
    }

    func testMissingRecordingBoundariesSuppressOfficialScore() {
        var recording = shotRecording(hertz: 20, seconds: 30)
        recording.recordingStartMonotonicSeconds = nil
        recording.recordingEndMonotonicSeconds = nil

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.validity?.isValid, false)
        XCTAssertTrue(metrics.validity?.reasons.contains("recordingBoundariesMissing") == true)
        XCTAssertNil(metrics.delivery?.deliveryScore)
    }

    func testIdleProducesSeparateValidScore() {
        var recording = timedRecording(mode: .idleStability, hertz: 20, seconds: 70)
        for index in recording.samples.indices {
            recording.samples[index].weightGrams = Double(index % 3) * 0.001
        }

        let metrics = ScaleQualityAnalyzer.analyze(recording)

        XCTAssertEqual(metrics.validity?.isValid, true)
        XCTAssertNotNil(metrics.stabilityScore)
        XCTAssertNil(metrics.transportScore)
        XCTAssertNil(metrics.delivery?.deliveryScore)
    }

    func testStandardScoringProfileUsesStableBenchmarkName() {
        XCTAssertEqual(ScoringProfile.standard.name, "ScaleBench Standard v1")
        XCTAssertEqual(ScoringPreset.standard.displayName, "ScaleBench Standard v1")
    }

    func testBenchmarkIdentityRequiresStandardParametersNotOnlyName() {
        var impostor = ScoringProfile.standard
        impostor.transportWeight = 0.90
        impostor.stabilityWeight = 0.10
        impostor.metadataWeight = 0

        XCTAssertTrue(ScoringProfile.standard.isStandardBenchmark)
        XCTAssertFalse(impostor.isStandardBenchmark)
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

    func testCustomScoringProfileAllZeroWeightsFallBackToStandardWeights() {
        var profile = ScoringProfile.standard
        profile.transportWeight = 0
        profile.stabilityWeight = 0
        profile.metadataWeight = 0

        let normalized = profile.normalized

        XCTAssertEqual(normalized.transportWeight, ScoringProfile.standard.transportWeight, accuracy: 0.0001)
        XCTAssertEqual(normalized.stabilityWeight, ScoringProfile.standard.stabilityWeight, accuracy: 0.0001)
        XCTAssertEqual(normalized.metadataWeight, ScoringProfile.standard.metadataWeight, accuracy: 0.0001)
    }

    func testCustomScoringProfileClampsNegativeWeightsBeforeNormalizing() {
        var profile = ScoringProfile.standard
        profile.name = "Negative input"
        profile.transportWeight = -1
        profile.stabilityWeight = 2
        profile.metadataWeight = 0

        let normalized = profile.normalized

        XCTAssertEqual(normalized.transportWeight, 0, accuracy: 0.0001)
        XCTAssertEqual(normalized.stabilityWeight, 1, accuracy: 0.0001)
        XCTAssertEqual(normalized.metadataWeight, 0, accuracy: 0.0001)
        XCTAssertFalse(normalized.isStandardBenchmark)
    }

    func testSampleRecordingFactoryProvidesBundledExamples() {
        let examples = SampleRecordingFactory.examples

        XCTAssertEqual(examples.count, 3)
        XCTAssertEqual(Set(examples.map(\.title)).count, examples.count)
        XCTAssertTrue(examples.allSatisfy { $0.recording.metrics.overallScore != nil })
        XCTAssertEqual(examples[0].recording.samples.first?.diagnosticFlags?.flowPresent, true)
        XCTAssertEqual(examples[0].recording.samples.first?.diagnosticFlags?.detected10SPS, true)
        XCTAssertEqual(examples[0].recording.rawPackets.first?.bytesHex.split(separator: " ").count, 20)
        XCTAssertEqual(examples[2].recording.rawPackets.first?.bytesHex.split(separator: " ").count, 11)
    }

    func testSavedRecordingStoresNotesAndScoreSnapshot() throws {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.device = ScaleDeviceIdentity(
            name: "WeighMyBru+",
            identifier: UUID().uuidString,
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
        let savedFile = directory.appendingPathComponent("\(saved.id.uuidString).json")
        let savedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: savedFile)) as? [String: Any]
        XCTAssertNotNil(savedObject?["startedAtMillis"])
        XCTAssertNil(savedObject?["recording"])
        XCTAssertEqual(savedObject?["id"] as? String, saved.id.uuidString)
        XCTAssertEqual(savedObject?["title"] as? String, saved.title)

        let reloaded = SavedRecordingStore(directoryURL: directory)
        XCTAssertEqual(reloaded.recordings.count, 1)
        XCTAssertEqual(reloaded.recordings.first?.id, saved.id)
        XCTAssertEqual(reloaded.recordings.first?.notes, "quiet table")
        XCTAssertEqual(reloaded.recordings.first?.scoreSnapshot.overallScore, saved.scoreSnapshot.overallScore)
    }

    func testSavedRecordingStoreReplacesDuplicateIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBenchDuplicateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var recording = ScaleRecording.empty(mode: .shot)
        recording.title = "First title"
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.2)
        ]

        let store = SavedRecordingStore(directoryURL: directory)
        let first = try XCTUnwrap(store.save(recording: recording, notes: "first", title: "First title"))
        let second = try XCTUnwrap(store.save(recording: recording, notes: "second", title: "Second title"))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.title, "Second title")
        XCTAssertEqual(store.recordings.first?.notes, "second")

        let reloaded = SavedRecordingStore(directoryURL: directory)
        XCTAssertEqual(reloaded.recordings.count, 1)
        XCTAssertEqual(reloaded.recordings.first?.id, first.id)
        XCTAssertEqual(reloaded.recordings.first?.title, "Second title")
    }

    func testSavedRecordingStoreDeleteRemovesBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBenchDeleteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var recording = ScaleRecording.empty(mode: .shot)
        recording.samples = [
            makeSample(seconds: 0.0, weight: 0.0),
            makeSample(seconds: 0.1, weight: 0.2)
        ]

        let store = SavedRecordingStore(directoryURL: directory)
        _ = try XCTUnwrap(store.save(recording: recording, notes: "first"))
        let saved = try XCTUnwrap(store.save(recording: recording, notes: "second"))
        let backupDirectory = directory.appendingPathComponent(".backups", isDirectory: true)
        let prefix = "\(saved.id.uuidString)-"
        let backupsBeforeDelete = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(backupsBeforeDelete.contains { $0.lastPathComponent.hasPrefix(prefix) })

        store.delete(saved)

        let backupsAfterDelete = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertFalse(backupsAfterDelete.contains { $0.lastPathComponent.hasPrefix(prefix) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(saved.id.uuidString).json").path))
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testSavedRecordingStoreDoesNotSeedExamplesWhenUnreadableFilesExist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBenchUnreadableSaveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ not valid json".utf8).write(to: corruptURL)

        let reloaded = SavedRecordingStore(directoryURL: directory, seedExamples: true)

        XCTAssertTrue(reloaded.recordings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(reloaded.lastErrorMessage?.contains("could not be read") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".examples-seeded-v1").path))
    }

    func testSavedRecordingStoreRefreshesSharedRecordingScoreSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBenchSharedRefreshTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var recording = ScaleRecording.empty(mode: .shot)
        recording.schemaVersion = 3
        recording.scoringProfile = ScoringProfile(
            name: ScoringProfile.standardBenchmarkName,
            transportWeight: 0.50,
            stabilityWeight: 0.35,
            metadataWeight: 0.15,
            minimumLongGapMilliseconds: 300,
            longGapMultiplier: 3,
            longGapPenalty: 5,
            missingSequencePenalty: 3,
            timestampIssuePenalty: 4,
            rejectedPacketRatePenaltyScale: 100,
            idleNoiseFreePeakToPeakGrams: 0.20,
            idleNoisePeakToPeakPenaltyScale: 10,
            idleStandardDeviationFreeGrams: 0.05,
            idleStandardDeviationPenaltyScale: 50,
            driftPenaltyScale: 4
        )
        recording.samples = [
            makeSample(seconds: 0, weight: 0),
            makeSample(seconds: 1, weight: 10)
        ]
        recording.metrics = .empty
        recording.title = "Old score"
        try SharedRecordingCodec.exportData(from: recording).write(
            to: directory.appendingPathComponent("\(recording.id.uuidString).json"),
            options: .atomic
        )

        let refreshed = try XCTUnwrap(SavedRecordingStore(directoryURL: directory).recordings.first)

        XCTAssertEqual(refreshed.title, "Old score")
        XCTAssertEqual(refreshed.recording.schemaVersion, ScaleRecording.schemaVersion)
        XCTAssertEqual(refreshed.recording.scoringProfile, .standard)
        XCTAssertEqual(refreshed.scoreSnapshot, ScaleQualityAnalyzer.analyze(refreshed.recording))
        XCTAssertNil(refreshed.scoreSnapshot.overallScore)
        XCTAssertTrue(refreshed.scoreSnapshot.validity?.reasons.contains("recordingBoundariesMissing") == true)
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

    private func shotRecording(hertz: Int, seconds: Int) -> ScaleRecording {
        var recording = timedRecording(mode: .shot, hertz: hertz, seconds: seconds)
        for index in recording.samples.indices {
            let elapsed = recording.samples[index].monotonicSeconds
            let weight = elapsed < 2 ? 0 : min(36, (elapsed - 2) * 2)
            recording.samples[index].weightGrams = (weight * 10).rounded() / 10
        }
        return recording
    }

    private func timedRecording(mode: RecordingMode, hertz: Int, seconds: Int) -> ScaleRecording {
        var recording = ScaleRecording.empty(mode: mode)
        recording.recordingStartMonotonicSeconds = 0
        recording.recordingEndMonotonicSeconds = Double(seconds)
        recording.samples = (0..<(hertz * seconds)).map { index in
            makeSample(seconds: Double(index) / Double(hertz), weight: 0)
        }
        return recording
    }

    private func savedRecording(kind: ScaleKind, score: Int, title: String) -> SavedScaleRecording {
        var recording = ScaleRecording.empty(mode: .shot)
        recording.device = ScaleDeviceIdentity(
            name: title,
            identifier: UUID().uuidString,
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

private struct PacketFieldFixture: Decodable {
    var scaleKind: ScaleKind
    var characteristicUUID: String
    var bytesHex: String
    var fields: [PacketFieldAnnotation]
}

private struct VectorIndex: Decodable {
    let scoringModelVersion: String
    let vectors: [VectorEntry]
}

private struct VectorEntry: Decodable {
    let vectorId: String
}

private struct VectorInput: Decodable {
    let vectorId: String
    let mode: RecordingMode
    let source: RecordingSource?
    let deviceKind: ScaleKind?
    let frames: [VectorFrame]
    let events: [VectorEvent]
    let protocolCapabilities: VectorProtocolCapabilities?
    let recordingStartMonotonicSeconds: Double?
    let recordingEndMonotonicSeconds: Double?

    func recording() -> ScaleRecording {
        var recording = ScaleRecording.empty(mode: mode)
        let recordingSource = source ?? .bluetooth
        let scaleKind = deviceKind ?? (recordingSource == .usbSerial ? .weighMyBruPlus : .weighMyBru)
        recording.source = recordingSource
        recording.protocolName = recordingSource == .usbSerial ? WMBPlusUSBSerialRow.protocolName : nil
        recording.serialBaud = recordingSource == .usbSerial ? WMBPlusUSBSerialRow.baud : nil
        recording.device = ScaleDeviceIdentity(name: "Vector", identifier: UUID().uuidString, kind: scaleKind, advertisedServices: [])
        recording.recordingStartMonotonicSeconds = recordingStartMonotonicSeconds
        recording.recordingEndMonotonicSeconds = recordingEndMonotonicSeconds
        recording.protocolCapabilities = protocolCapabilities?.native
        recording.events = events.map(\.native)
        recording.rawPackets = frames.map { frame in
            RawScalePacket(
                arrivalTime: Date(timeIntervalSince1970: frame.monotonicSeconds),
                monotonicSeconds: frame.monotonicSeconds,
                scaleKind: scaleKind,
                characteristicUUID: "VECTOR",
                role: frame.packetRole,
                bytesHex: "",
                rejectionReason: frame.parseFailed == true ? .invalidChecksum : nil,
                weightGrams: frame.weightGrams,
                sequence: recordingSource == .usbSerial ? nil : frame.sequence.map(UInt8.init(truncatingIfNeeded:)),
                deviceTimestampMilliseconds: frame.firmwareMillis
                    ?? frame.deviceTimestampMs.map(UInt32.init(truncatingIfNeeded:)),
                usbSerial: frame.usbMetadata(source: recordingSource)
            )
        }
        recording.samples = frames.compactMap { frame in
            guard frame.kind == "weight", frame.parseFailed != true, let weight = frame.weightGrams else { return nil }
            return ScaleSample(
                arrivalTime: Date(timeIntervalSince1970: frame.monotonicSeconds),
                monotonicSeconds: frame.monotonicSeconds,
                scaleKind: scaleKind,
                weightGrams: weight,
                deviceTimestampMilliseconds: frame.firmwareMillis
                    ?? frame.deviceTimestampMs.map(UInt32.init(truncatingIfNeeded:)),
                sequence: recordingSource == .usbSerial ? nil : frame.sequence.map(UInt8.init(truncatingIfNeeded:)),
                batteryPercent: nil,
                flowGramsPerSecond: nil,
                firmwareQualityScore: nil,
                detectedSampleRateHz: nil,
                statusFlags: nil,
                diagnosticFlags: nil,
                usbSerial: frame.usbMetadata(source: recordingSource)
            )
        }
        return recording
    }
}

private struct VectorFrame: Decodable {
    let kind: String
    let monotonicSeconds: Double
    let weightGrams: Double?
    let parseFailed: Bool?
    let sequence: UInt64?
    let deviceTimestampMs: UInt64?
    let firmwareMillis: UInt32?
    let sequenceNumber: UInt32?
    let usbDroppedCumulative: UInt32?
    let usbDroppedDelta: UInt32?

    func usbMetadata(source: RecordingSource) -> USBSerialSampleMetadata? {
        guard source == .usbSerial, let firmwareMillis, let sequenceNumber else { return nil }
        return USBSerialSampleMetadata(
            firmwareMillis: firmwareMillis,
            sequenceNumber: sequenceNumber,
            usbStatusRaw: 0x0001,
            usbStatusLabels: ["HX711 connected"],
            firmwareQuality: 100,
            hx711Hz: 20,
            usbDroppedCumulative: usbDroppedCumulative ?? 0,
            usbDroppedDelta: usbDroppedDelta ?? 0,
            hostReceivedAt: Date(timeIntervalSince1970: monotonicSeconds)
        )
    }

    var packetRole: PacketRole {
        switch kind {
        case "weight": .weight
        case "battery": .battery
        default: .unknown
        }
    }
}

private struct VectorEvent: Decodable {
    let type: ScaleRecordingEventType
    let monotonicSeconds: Double

    var native: ScaleRecordingEvent {
        ScaleRecordingEvent(type: type, monotonicSeconds: monotonicSeconds)
    }
}

private struct VectorProtocolCapabilities: Decodable {
    let hasChecksum: Bool?
    let hasSequence: Bool?
    let sequenceModulus: UInt64?
    let hasDeviceClock: Bool?
    let deviceClockSemantics: DeviceClockSemantics?
    let deviceClockModulus: UInt64?

    var native: ProtocolScoringCapabilities {
        let clockSemantics = deviceClockSemantics ?? ((hasDeviceClock ?? false) ? .freeRunning : .none)
        return ProtocolScoringCapabilities(
            hasChecksum: hasChecksum ?? false,
            hasSequence: hasSequence ?? false,
            sequenceModulus: sequenceModulus,
            hasDeviceClock: hasDeviceClock ?? false,
            deviceClockSemantics: clockSemantics,
            deviceClockModulus: deviceClockModulus
        )
    }
}

private struct VectorExpected: Decodable {
    let mode: RecordingMode
    let scoringModelVersion: String
    let scoringProfileName: String
    let delivery: VectorExpectedDelivery
    let diagnostics: VectorExpectedDiagnostics
    let frameClassification: FrameClassificationMetrics
    let protocolVerification: ProtocolVerificationMetrics
    let signalUnreconstructable: Bool
    let validity: ScoringValidity
    let idle: VectorExpectedIdle?
    let stepResponse: StepResponseMetrics?
}

private struct VectorExpectedDelivery: Decodable {
    let applicable: Bool
    let deliveryScore: Int?
    let coverage: Double?
    let purity: Double?
    let purityIsUpperBound: Bool?
}

private struct VectorExpectedDiagnostics: Decodable {
    let disconnectCount: Int
    let estimatedResolutionGrams: Double?
    let excludedFrames: Int
    let frameRateHz: Double?
    let intervalMaxMs: Double?
    let intervalP50Ms: Double?
    let intervalP95Ms: Double?
    let longestUnservedRunMs: Double?
    let recordingBoundaryInferred: Bool
    let relevantWeightFrames: Int
    let robustCoefficientOfVariation: Double?
    let servedSlots: Int?
    let slotCount: Int?
    let spanSeconds: Double
    let usableRateHz: Double?
    let usableSampleCount: Int
}

private struct VectorExpectedIdle: Decodable {
    let analysedSampleCount: Int
    let driftGramsPerMinute: Double?
    let driftScore: Int?
    let idleStabilityScore: Int?
    let noiseScore: Int?
    let residualPeakToPeakGrams: Double?
    let residualStandardDeviationGrams: Double?
    let resolutionGrams: Double?
}

private func sharedFixtureData(_ fileName: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("shared/fixtures/\(fileName)"))
}

private func sharedFixtureObject(_ fileName: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: sharedFixtureData(fileName))
    guard let dictionary = object as? [String: Any] else {
        throw NSError(
            domain: "ScaleBenchTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(fileName) is not a JSON object"]
        )
    }
    return dictionary
}

private func writeContractOutput(_ data: Data, named fileName: String) throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("build/contract-output", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
}

private func assertVector(
    _ metrics: ScaleQualityMetrics,
    equals expected: VectorExpected,
    vector: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(metrics.scoringModelVersion, expected.scoringModelVersion, vector, file: file, line: line)
    XCTAssertEqual(metrics.scoringProfileName, expected.scoringProfileName, vector, file: file, line: line)
    XCTAssertEqual(metrics.delivery?.applicable, expected.delivery.applicable, vector, file: file, line: line)
    XCTAssertEqual(metrics.delivery?.deliveryScore, expected.delivery.deliveryScore, vector, file: file, line: line)
    XCTAssertClose(metrics.delivery?.coverage, expected.delivery.coverage, vector, file: file, line: line)
    XCTAssertClose(metrics.delivery?.purity, expected.delivery.purity, vector, file: file, line: line)
    XCTAssertEqual(metrics.delivery?.purityIsUpperBound, expected.delivery.purityIsUpperBound, vector, file: file, line: line)

    XCTAssertEqual(metrics.validity?.isValid, expected.validity.isValid, vector, file: file, line: line)
    XCTAssertEqual(Set(metrics.validity?.reasons ?? []), Set(expected.validity.reasons), vector, file: file, line: line)
    XCTAssertEqual(metrics.signalUnreconstructable, expected.signalUnreconstructable, vector, file: file, line: line)
    XCTAssertEqual(metrics.frameClassification, expected.frameClassification, vector, file: file, line: line)
    XCTAssertEqual(Set(metrics.protocolVerification?.verifiableClasses ?? []), Set(expected.protocolVerification.verifiableClasses), vector, file: file, line: line)
    XCTAssertEqual(Set(metrics.protocolVerification?.unverifiableClasses ?? []), Set(expected.protocolVerification.unverifiableClasses), vector, file: file, line: line)
    XCTAssertEqual(metrics.protocolVerification?.verificationCoveragePercent, expected.protocolVerification.verificationCoveragePercent, vector, file: file, line: line)
    XCTAssertEqual(metrics.protocolVerification?.purityIsUpperBound, expected.protocolVerification.purityIsUpperBound, vector, file: file, line: line)

    XCTAssertEqual(metrics.disconnectCount, expected.diagnostics.disconnectCount, vector, file: file, line: line)
    XCTAssertClose(metrics.estimatedResolutionGrams, expected.diagnostics.estimatedResolutionGrams, vector, file: file, line: line)
    XCTAssertEqual(metrics.excludedFrameCount, expected.diagnostics.excludedFrames, vector, file: file, line: line)
    XCTAssertClose(metrics.frameRateHz, expected.diagnostics.frameRateHz, vector, file: file, line: line)
    XCTAssertClose(metrics.packetIntervalMaxMilliseconds, expected.diagnostics.intervalMaxMs, vector, file: file, line: line)
    XCTAssertClose(metrics.packetIntervalP50Milliseconds, expected.diagnostics.intervalP50Ms, vector, file: file, line: line)
    if expected.diagnostics.intervalP95Ms != nil {
        XCTAssertClose(metrics.packetIntervalP95Milliseconds, expected.diagnostics.intervalP95Ms, vector, file: file, line: line)
    }
    XCTAssertClose(metrics.longestUnservedRunMilliseconds, expected.diagnostics.longestUnservedRunMs, vector, file: file, line: line)
    XCTAssertEqual(metrics.recordingBoundaryInferred, expected.diagnostics.recordingBoundaryInferred, vector, file: file, line: line)
    XCTAssertEqual(metrics.relevantWeightFrameCount, expected.diagnostics.relevantWeightFrames, vector, file: file, line: line)
    XCTAssertClose(metrics.robustCoefficientOfVariation, expected.diagnostics.robustCoefficientOfVariation, vector, file: file, line: line)
    XCTAssertEqual(metrics.servedSlots, expected.diagnostics.servedSlots, vector, file: file, line: line)
    XCTAssertEqual(metrics.slotCount, expected.diagnostics.slotCount, vector, file: file, line: line)
    XCTAssertClose(metrics.recordingSpanSeconds, expected.diagnostics.spanSeconds, vector, file: file, line: line)
    XCTAssertClose(metrics.usableRateHz, expected.diagnostics.usableRateHz, vector, file: file, line: line)
    XCTAssertEqual(metrics.usableSampleCount, expected.diagnostics.usableSampleCount, vector, file: file, line: line)

    XCTAssertEqual(metrics.stabilityScore, expected.idle?.idleStabilityScore, vector, file: file, line: line)
    XCTAssertEqual(metrics.idleNoiseScore, expected.idle?.noiseScore, vector, file: file, line: line)
    XCTAssertEqual(metrics.idleDriftScore, expected.idle?.driftScore, vector, file: file, line: line)
    XCTAssertEqual(metrics.idleAnalysedSampleCount, expected.idle?.analysedSampleCount, vector, file: file, line: line)
    XCTAssertClose(metrics.idleNoisePeakToPeakGrams, expected.idle?.residualPeakToPeakGrams, vector, file: file, line: line)
    XCTAssertClose(metrics.idleNoiseStandardDeviationGrams, expected.idle?.residualStandardDeviationGrams, vector, file: file, line: line)
    XCTAssertClose(metrics.driftGramsPerMinute, expected.idle?.driftGramsPerMinute, vector, file: file, line: line)
    XCTAssertClose(metrics.idleResolutionGrams, expected.idle?.resolutionGrams, vector, file: file, line: line)
    XCTAssertEqual(metrics.stepResponse, expected.stepResponse, vector, file: file, line: line)
}

private func XCTAssertClose(
    _ actual: Double?,
    _ expected: Double?,
    _ message: String,
    accuracy: Double = 0.000001,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (actual, expected) {
    case let (actual?, expected?):
        XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
    case (nil, nil):
        break
    default:
        XCTFail("\(message) expected \(String(describing: expected)) got \(String(describing: actual))", file: file, line: line)
    }
}
