import CoreBluetooth
import Foundation
import QuartzCore

final class BluetoothScaleManager: NSObject, ObservableObject {
    @Published private(set) var discoveredScales: [DiscoveredScale] = []
    @Published private(set) var connectedDevice: DiscoveredScale?
    @Published private(set) var activeProtocol: ScaleKind = .unknown
    @Published private(set) var latestSample: ScaleSample?
    @Published private(set) var latestBatteryPercent: Int?
    @Published private(set) var currentRecording: ScaleRecording = .empty()
    @Published private(set) var currentMetrics: ScaleQualityMetrics = .empty
    @Published private(set) var isRecording = false
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var bluetoothStateTitle = "Bluetooth initializing"

    private var centralManager: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var advertisedServicesByID: [UUID: [String]] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var wmbPlusCapabilities: WMBPlusCapabilities?
    private var acaiaCodec = AcaiaParser.Codec()
    private var timemoreDotCodec = TimemoreDotParser.Codec()
    private var didSendInitialConfiguration = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Bluetooth is not powered on"
            return
        }
        discoveredScales.removeAll()
        peripheralsByID.removeAll()
        advertisedServicesByID.removeAll()
        isScanning = true
        statusMessage = "Scanning for Bluetooth scales"
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        statusMessage = "Scan stopped"
    }

    func connect(to device: DiscoveredScale) {
        guard let peripheral = peripheralsByID[device.id] else {
            statusMessage = "Peripheral no longer available"
            return
        }
        stopScanning()
        connectedDevice = device
        activeProtocol = device.kind
        peripheral.delegate = self
        statusMessage = "Connecting to \(device.name)"
        centralManager.connect(peripheral)
    }

    func startRecording(mode: RecordingMode, scoringProfile: ScoringProfile = .standard) {
        isRecording = true
        currentRecording = ScaleRecording.empty(mode: mode, scoringProfile: scoringProfile)
        if let connectedDevice {
            currentRecording.device = ScaleDeviceIdentity(
                name: connectedDevice.name,
                identifier: connectedDevice.id,
                kind: activeProtocol,
                advertisedServices: advertisedServicesByID[connectedDevice.id] ?? []
            )
        }
        currentRecording.capabilities = wmbPlusCapabilities
        currentMetrics = .empty
        statusMessage = "Recording \(mode.displayName)"
    }

    func stopRecording() {
        isRecording = false
        currentRecording.endedAt = Date()
        currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording)
        currentMetrics = currentRecording.metrics
        statusMessage = "Recording stopped"
    }

    func resetRecording() {
        isRecording = false
        currentRecording = .empty()
        currentMetrics = .empty
        latestSample = nil
        statusMessage = connectedDevice == nil ? "Idle" : "Connected"
    }

    func exportCurrentRecording() -> URL? {
        do {
            currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording)
            currentMetrics = currentRecording.metrics
            return try RecordingExporter.export(currentRecording)
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func sendAtomicTareAndStart() {
        guard let peripheral = connectedPeripheral(), let writeCharacteristic else {
            statusMessage = "No writable command characteristic"
            return
        }

        let bytes: [UInt8]
        switch activeProtocol {
        case .bookoo, .bookooMini, .bookooUltra:
            bytes = BookooParser.tareAndStartCommand
        case .weighMyBruPlus:
            bytes = WeighMyBruParser.atomicTareAndStartCommand
        default:
            bytes = WeighMyBruParser.atomicTareAndStartCommand
        }

        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: writeType(for: writeCharacteristic))
        statusMessage = "Atomic tare/start sent"
    }

    private func connectedPeripheral() -> CBPeripheral? {
        connectedDevice.flatMap { peripheralsByID[$0.id] }
    }

    private func recordRawPacket(
        data: Data,
        characteristic: CBCharacteristic,
        role: PacketRole,
        rejectionReason: ParseRejectionReason?
    ) {
        guard isRecording else { return }

        currentRecording.rawPackets.append(RawScalePacket(
            arrivalTime: Date(),
            monotonicSeconds: CACurrentMediaTime(),
            scaleKind: activeProtocol,
            characteristicUUID: characteristic.uuid.uuidString.uppercased(),
            role: role,
            bytesHex: data.hexString,
            rejectionReason: rejectionReason
        ))
    }

    private func receiveSample(_ sample: ScaleSample) {
        latestSample = sample
        if !(activeProtocol == .weighMyBruPlus && sample.scaleKind == .weighMyBru) {
            activeProtocol = sample.scaleKind
        }

        guard isRecording else { return }
        currentRecording.samples.append(sample)
        currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording)
        currentMetrics = currentRecording.metrics
    }

    private func receiveBattery(_ percent: Int) {
        latestBatteryPercent = percent
    }

    private func handleParserEvent(_ event: ScaleParserEvent, data: Data, characteristic: CBCharacteristic) {
        switch event {
        case let .sample(sample):
            recordRawPacket(data: data, characteristic: characteristic, role: .weight, rejectionReason: nil)
            receiveSample(sample)
        case let .battery(percent):
            recordRawPacket(data: data, characteristic: characteristic, role: .battery, rejectionReason: nil)
            receiveBattery(percent)
        case let .rejected(reason):
            recordRawPacket(data: data, characteristic: characteristic, role: .unknown, rejectionReason: reason)
        }
    }

    private func handleResult(_ result: Result<ScaleSample, ParseRejectionReason>, data: Data, characteristic: CBCharacteristic) {
        switch result {
        case let .success(sample):
            recordRawPacket(data: data, characteristic: characteristic, role: .weight, rejectionReason: nil)
            receiveSample(sample)
        case let .failure(reason):
            recordRawPacket(data: data, characteristic: characteristic, role: .weight, rejectionReason: reason)
        }
    }

    private func identifyScale(name: String?, services: [String]) -> ScaleKind {
        let lowerName = (name ?? "").lowercased()
        if lowerName.contains("weighmybru+") { return .weighMyBruPlus }
        if lowerName.contains("weighmybru") || hasService(WeighMyBruParser.serviceUUID, in: services) { return .weighMyBru }
        if lowerName.contains("bookoo") || hasService(BookooParser.serviceUUID, in: services) { return BookooParser.identifyKind(name: name) }
        if AcaiaParser.nameMatches(name ?? "") || hasService(AcaiaParser.serviceUUID, in: services) || hasService(AcaiaParser.fullServiceUUID, in: services) { return .acaia }
        if FelicitaParser.nameMatches(lowerName) || hasService(FelicitaParser.serviceUUID, in: services) { return .felicita }
        if Skale2Parser.nameMatches(lowerName) || hasService(Skale2Parser.serviceUUID, in: services) { return .skale2 }
        if hasService(DiFluidParser.tiServiceUUID, in: services) || lowerName.contains("microbalance ti") || lowerName.contains("mb ti") { return .difluidTi }
        if hasService(DiFluidParser.serviceUUID, in: services) || lowerName.contains("microbalance") { return .difluid }
        if DecentProtocolNameMatcher.nameMatches(lowerName) { return .decent }
        if lowerName.hasPrefix("espressiscale") { return .espressi }
        if FutulaParser.nameMatches(lowerName) { return .futula }
        if EurekaPrecisaParser.nameMatches(lowerName) { return .eureka }
        if TimemoreDotParser.nameMatches(lowerName) { return .timemoreDot }
        return .unknown
    }

    private func serviceUUIDs(from advertisementData: [String: Any]) -> [String] {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return serviceUUIDs.map { $0.uuidString.uppercased() }
    }

    private func hasService(_ uuid: String, in services: [String]) -> Bool {
        let wanted = uuid.uppercased()
        return services.contains(where: { $0.uppercased() == wanted })
    }

    private func appendOrUpdate(device: DiscoveredScale) {
        if let index = discoveredScales.firstIndex(where: { $0.id == device.id }) {
            discoveredScales[index] = device
        } else if device.kind != .unknown {
            discoveredScales.append(device)
            discoveredScales.sort { lhs, rhs in
                lhs.kind.displayName == rhs.kind.displayName ? lhs.name < rhs.name : lhs.kind.displayName < rhs.kind.displayName
            }
        }
    }

    private func handleValueUpdate(data: Data, characteristic: CBCharacteristic) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        let arrival = Date()
        let monotonic = CACurrentMediaTime()

        switch uuid {
        case BookooParser.notifyUUID:
            handleResult(
                BookooParser.parseWeightPacket(data, kind: activeProtocol, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic
            )

        case WeighMyBruParser.weight20UUID:
            handleResult(
                WeighMyBruParser.parse20BytePacket(data, capabilities: wmbPlusCapabilities, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic
            )

        case WeighMyBruParser.float32UUID:
            handleResult(
                WeighMyBruParser.parseFloat32Packet(data, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic
            )

        case WeighMyBruParser.capabilitiesUUID:
            recordRawPacket(data: data, characteristic: characteristic, role: .capabilities, rejectionReason: nil)
            if let capabilities = WeighMyBruParser.parseCapabilities(data) {
                wmbPlusCapabilities = capabilities
                currentRecording.capabilities = capabilities
                if capabilities.supportsExtendedPacket {
                    activeProtocol = .weighMyBruPlus
                    if var device = connectedDevice {
                        device.kind = .weighMyBruPlus
                        connectedDevice = device
                    }
                }
                statusMessage = "Read WMB+ capabilities"
            } else {
                statusMessage = "Rejected WMB+ capabilities"
            }

        case WeighMyBruParser.batteryLevelUUID:
            if let value = data.first, value <= 100 { receiveBattery(Int(value)) }
            recordRawPacket(data: data, characteristic: characteristic, role: .battery, rejectionReason: nil)

        case WeighMyBruParser.commandUUID:
            recordRawPacket(data: data, characteristic: characteristic, role: .commandAck, rejectionReason: nil)

        case AcaiaParser.modernCharUUID, AcaiaParser.fullModernCharUUID, AcaiaParser.legacyNotifyUUID:
            for event in acaiaCodec.receive(data, arrivalTime: arrival, monotonicSeconds: monotonic) {
                handleParserEvent(event, data: data, characteristic: characteristic)
            }

        case DecentEspressiParser.notifyUUID where activeProtocol == .decent || activeProtocol == .espressi:
            handleResult(
                DecentEspressiParser.parseWeightPacket(data, kind: activeProtocol, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic
            )

        case DiFluidParser.charUUID where activeProtocol == .difluid || activeProtocol == .difluidTi:
            handleParserEvent(
                DiFluidParser.parse(data, kind: activeProtocol, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic
            )

        case EurekaPrecisaParser.notifyUUID where activeProtocol == .eureka:
            handleResult(EurekaPrecisaParser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic)

        case FelicitaParser.charUUID:
            handleResult(FelicitaParser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic)

        case FutulaParser.notifyUUID where activeProtocol == .futula:
            handleResult(FutulaParser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic)

        case Skale2Parser.notifyUUID:
            handleResult(Skale2Parser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic)

        case TimemoreDotParser.notifyUUID where activeProtocol == .timemoreDot:
            for event in timemoreDotCodec.receive(data, arrivalTime: arrival, monotonicSeconds: monotonic) {
                handleParserEvent(event, data: data, characteristic: characteristic)
            }

        default:
            recordRawPacket(data: data, characteristic: characteristic, role: .unknown, rejectionReason: .unsupportedCharacteristic)
        }
    }

    private func isWritableCharacteristic(_ uuid: String) -> Bool {
        switch uuid {
        case BookooParser.writeUUID,
             WeighMyBruParser.commandUUID,
             AcaiaParser.modernCharUUID,
             AcaiaParser.fullModernCharUUID,
             AcaiaParser.legacyWriteUUID,
             DecentEspressiParser.writeUUID,
             DiFluidParser.charUUID,
             EurekaPrecisaParser.writeUUID,
             FelicitaParser.charUUID,
             FutulaParser.writeUUID,
             Skale2Parser.writeUUID,
             TimemoreDotParser.writeUUID:
            return true
        default:
            return false
        }
    }

    private func writeType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    }

    private func write(_ bytes: [UInt8]) {
        guard let peripheral = connectedPeripheral(), let writeCharacteristic else { return }
        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: writeType(for: writeCharacteristic))
    }

    private func sendInitialConfigurationIfNeeded() {
        guard !didSendInitialConfiguration else { return }
        guard writeCharacteristic != nil else { return }
        didSendInitialConfiguration = true

        switch activeProtocol {
        case .acaia:
            let isPyxis = connectedDevice?.name.uppercased().hasPrefix("PYXIS") == true
            write(AcaiaParser.identifyCommand(isPyxis: isPyxis))
            write(AcaiaParser.notificationRequestCommand)
        case .decent:
            write(DecentEspressiParser.decentLEDsOnCommand)
        case .difluid, .difluidTi:
            write(DiFluidParser.config1Command)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.write(DiFluidParser.config2Command) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.write(DiFluidParser.requestStatusCommand) }
        case .futula:
            write(FutulaParser.setGramsCommand)
        case .skale2:
            Skale2Parser.initialCommands.forEach(write)
        case .timemoreDot:
            write(TimemoreDotParser.setGramsCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.write(TimemoreDotParser.setStandardModeCommand) }
        default:
            break
        }
    }
}

private enum DecentProtocolNameMatcher {
    static func nameMatches(_ name: String) -> Bool { name.hasPrefix("decent") }
}

extension BluetoothScaleManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown: bluetoothStateTitle = "Bluetooth unknown"
        case .resetting: bluetoothStateTitle = "Bluetooth resetting"
        case .unsupported: bluetoothStateTitle = "Bluetooth unsupported"
        case .unauthorized: bluetoothStateTitle = "Bluetooth unauthorized"
        case .poweredOff: bluetoothStateTitle = "Bluetooth off"
        case .poweredOn: bluetoothStateTitle = "Bluetooth on"
        @unknown default: bluetoothStateTitle = "Bluetooth unknown"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let services = serviceUUIDs(from: advertisementData)
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unnamed Scale"
        let kind = identifyScale(name: name, services: services)
        peripheralsByID[peripheral.identifier] = peripheral
        advertisedServicesByID[peripheral.identifier] = services
        appendOrUpdate(device: DiscoveredScale(
            id: peripheral.identifier,
            name: name,
            kind: kind,
            rssi: RSSI.intValue
        ))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        statusMessage = "Connected to \(peripheral.name ?? "scale")"
        peripheral.delegate = self
        didSendInitialConfiguration = false
        acaiaCodec = AcaiaParser.Codec()
        timemoreDotCodec = TimemoreDotParser.Codec()
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Disconnected"
        connectedDevice = nil
        activeProtocol = .unknown
        writeCharacteristic = nil
        wmbPlusCapabilities = nil
        didSendInitialConfiguration = false
        acaiaCodec = AcaiaParser.Codec()
        timemoreDotCodec = TimemoreDotParser.Codec()
    }
}

extension BluetoothScaleManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusMessage = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        peripheral.services?.forEach { service in
            switch service.uuid.uuidString.uppercased() {
            case BookooParser.serviceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: BookooParser.notifyUUID), CBUUID(string: BookooParser.writeUUID)], for: service)
            case WeighMyBruParser.serviceUUID:
                peripheral.discoverCharacteristics([
                    CBUUID(string: WeighMyBruParser.weight20UUID),
                    CBUUID(string: WeighMyBruParser.float32UUID),
                    CBUUID(string: WeighMyBruParser.commandUUID),
                    CBUUID(string: WeighMyBruParser.capabilitiesUUID)
                ], for: service)
            case WeighMyBruParser.batteryServiceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: WeighMyBruParser.batteryLevelUUID)], for: service)
            case AcaiaParser.serviceUUID, AcaiaParser.fullServiceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: AcaiaParser.fullModernCharUUID)], for: service)
            case AcaiaParser.legacyServiceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: AcaiaParser.legacyNotifyUUID), CBUUID(string: AcaiaParser.legacyWriteUUID)], for: service)
            case FelicitaParser.serviceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: FelicitaParser.charUUID)], for: service)
            case Skale2Parser.serviceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: Skale2Parser.notifyUUID), CBUUID(string: Skale2Parser.writeUUID)], for: service)
            case DecentEspressiParser.serviceUUID:
                peripheral.discoverCharacteristics([
                    CBUUID(string: DecentEspressiParser.notifyUUID),
                    CBUUID(string: DecentEspressiParser.writeUUID),
                    CBUUID(string: EurekaPrecisaParser.notifyUUID),
                    CBUUID(string: EurekaPrecisaParser.writeUUID),
                    CBUUID(string: FutulaParser.writeUUID)
                ], for: service)
            case DiFluidParser.serviceUUID, DiFluidParser.tiServiceUUID:
                peripheral.discoverCharacteristics([CBUUID(string: DiFluidParser.charUUID)], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            statusMessage = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }

        service.characteristics?.forEach { characteristic in
            let uuid = characteristic.uuid.uuidString.uppercased()

            if isWritableCharacteristic(uuid) && (characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)) {
                writeCharacteristic = characteristic
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.properties.contains(.read)
                && (uuid == WeighMyBruParser.capabilitiesUUID || uuid == WeighMyBruParser.batteryLevelUUID) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusMessage = "Notification setup failed: \(error.localizedDescription)"
            return
        }
        if characteristic.isNotifying {
            sendInitialConfigurationIfNeeded()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusMessage = "Value update failed: \(error.localizedDescription)"
            return
        }
        guard let data = characteristic.value else { return }
        handleValueUpdate(data: data, characteristic: characteristic)
    }
}

extension BluetoothScaleManager {
    static let preview: BluetoothScaleManager = {
        let manager = BluetoothScaleManager()
        manager.discoveredScales = [
            DiscoveredScale(id: UUID(), name: "WeighMyBru+", kind: .weighMyBruPlus, rssi: -48),
            DiscoveredScale(id: UUID(), name: "BooKoo Ultra", kind: .bookooUltra, rssi: -55),
            DiscoveredScale(id: UUID(), name: "CFS-9002", kind: .eureka, rssi: -60)
        ]
        manager.connectedDevice = manager.discoveredScales.first
        manager.activeProtocol = .weighMyBruPlus
        manager.currentRecording.samples = [
            ScaleSample(
                arrivalTime: Date(),
                monotonicSeconds: 0,
                scaleKind: .weighMyBruPlus,
                weightGrams: 0,
                deviceTimestampMilliseconds: 100,
                sequence: 1,
                batteryPercent: 90,
                flowGramsPerSecond: 0,
                firmwareQualityScore: 96,
                detectedSampleRateHz: 12,
                statusFlags: ScaleStatusFlags(byte: 0x42),
                diagnosticFlags: ScaleDiagnosticFlags(byte: 0xE4)
            )
        ]
        manager.latestSample = manager.currentRecording.samples.first
        manager.currentMetrics = ScaleQualityMetrics(
            overallScore: 95,
            transportScore: 96,
            stabilityScore: 94,
            metadataScore: 100,
            effectiveSampleRateHz: 11.8,
            packetIntervalP50Milliseconds: 84,
            packetIntervalP95Milliseconds: 88,
            packetIntervalMaxMilliseconds: 110,
            longGapCount: 0,
            missingSequenceCount: 0,
            duplicateOrOutOfOrderTimestampCount: 0,
            rejectedPacketCount: 0,
            idleNoisePeakToPeakGrams: 0.12,
            idleNoiseStandardDeviationGrams: 0.03,
            driftGramsPerMinute: 0.02,
            batteryMinPercent: 90,
            batteryMaxPercent: 90,
            firmwareQualityAverage: 96,
            firmwareBumpCount: 0
        )
        manager.statusMessage = "Preview"
        manager.bluetoothStateTitle = "Bluetooth on"
        return manager
    }()
}
