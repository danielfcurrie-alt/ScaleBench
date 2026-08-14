import CoreBluetooth
import Foundation
import QuartzCore

final class BluetoothScaleManager: NSObject, ObservableObject {
    @Published private(set) var discoveredScales: [DiscoveredScale] = []
    @Published private(set) var connectedDevice: DiscoveredScale?
    @Published private(set) var activeProtocol: ScaleKind = .unknown
    private(set) var latestSample: ScaleSample?
    private(set) var latestBatteryPercent: Int?
    private(set) var currentRecording: ScaleRecording = .empty()
    @Published private(set) var currentMetrics: ScaleQualityMetrics = .empty
    @Published private(set) var completedRecording: ScaleRecording?
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var isScanning = false
    @Published private(set) var isConnectionReady = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var bluetoothStateTitle = "Bluetooth initializing"
    @Published private(set) var liveDisplayRevision = 0

    private var centralManager: CBCentralManager!
    private let bluetoothQueue = DispatchQueue(label: "com.scalebench.bluetooth", qos: .userInitiated)
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var advertisedServicesByID: [UUID: [String]] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var wmbPlusCapabilities: WMBPlusCapabilities?
    private var acaiaCodec = AcaiaParser.Codec()
    private var timemoreDotCodec = TimemoreDotParser.Codec()
    private var didSendInitialConfiguration = false
    private var reconnectPending = false
    private var notifyingMeasurementCharacteristicUUIDs: Set<String> = []
    private var recordingAppIsForeground = true
    private let liveUIRefreshIntervalSeconds: Double = 0.2
    private let liveMetricsRefreshIntervalSeconds: Double = 2.0
    private let maxSamplesForFullLiveMetrics = 2_000
    private let maxDiscoveredScales = 40
    private let liveMetricsQueue = DispatchQueue(label: "com.scalebench.live-metrics", qos: .utility)
    private var liveUIRefreshWorkItem: DispatchWorkItem?
    private var liveMetricsAnalysisInFlight = false
    private var recordingGeneration = 0
    private var lastLiveMetricsRefreshSeconds = -Double.infinity
    private var hasSeenWMBPlusWeightTransport = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: bluetoothQueue)
    }

    func startScanning() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startScanning() }
            return
        }
        guard centralManager.state == .poweredOn else {
            statusMessage = "Bluetooth is not powered on"
            return
        }
        discoveredScales = connectedDevice.map { [$0] } ?? []
        isScanning = true
        statusMessage = "Scanning for Bluetooth scales"
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopScanning() }
            return
        }
        centralManager.stopScan()
        isScanning = false
        statusMessage = "Scan stopped"
    }

    func disconnect() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.disconnect() }
            return
        }
        guard let device = connectedDevice else {
            statusMessage = "No Bluetooth scale connected"
            return
        }

        if isRecording {
            stopRecording()
        }

        let peripheral = peripheralsByID[device.id]
        centralManager.stopScan()
        isScanning = false
        isConnectionReady = false
        notifyingMeasurementCharacteristicUUIDs.removeAll()
        writeCharacteristic = nil
        wmbPlusCapabilities = nil
        didSendInitialConfiguration = false
        acaiaCodec = AcaiaParser.Codec()
        timemoreDotCodec = TimemoreDotParser.Codec()
        latestSample = nil
        latestBatteryPercent = nil
        connectedDevice = nil
        activeProtocol = .unknown
        reconnectPending = false
        hasSeenWMBPlusWeightTransport = false
        statusMessage = "Disconnected from \(device.name)"

        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func connect(to device: DiscoveredScale) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.connect(to: device) }
            return
        }
        guard let peripheral = peripheralsByID[device.id] else {
            statusMessage = "Peripheral no longer available"
            return
        }
        if isRecording {
            stopRecording()
        }
        stopScanning()
        latestSample = nil
        latestBatteryPercent = nil
        writeCharacteristic = nil
        wmbPlusCapabilities = nil
        isConnectionReady = false
        notifyingMeasurementCharacteristicUUIDs.removeAll()
        hasSeenWMBPlusWeightTransport = false
        reconnectPending = false
        connectedDevice = device
        activeProtocol = device.kind
        peripheral.delegate = self
        statusMessage = "Connecting to \(device.name)"
        centralManager.connect(peripheral)
    }

    func startRecording(mode: RecordingMode, scoringProfile: ScoringProfile = .standard) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startRecording(mode: mode, scoringProfile: scoringProfile) }
            return
        }
        guard isConnectionReady else {
            statusMessage = "Wait for the scale to finish connecting"
            return
        }
        let recordingStart = CACurrentMediaTime()
        recordingGeneration &+= 1
        recordingAppIsForeground = true
        completedRecording = nil
        isRecording = true
        currentRecording = ScaleRecording.empty(mode: mode, scoringProfile: scoringProfile)
        currentRecording.recordingStartMonotonicSeconds = recordingStart
        currentRecording.recordingEndMonotonicSeconds = nil
        if let connectedDevice {
            currentRecording.device = ScaleDeviceIdentity(
                name: connectedDevice.name,
                identifier: connectedDevice.id.uuidString,
                kind: activeProtocol,
                advertisedServices: advertisedServicesByID[connectedDevice.id] ?? []
            )
        }
        currentRecording.capabilities = wmbPlusCapabilities
        currentRecording.protocolCapabilities = baseScoringCapabilities(for: activeProtocol)
        if let batteryPercent = latestSample?.batteryPercent ?? latestBatteryPercent,
           (0...100).contains(batteryPercent) {
            currentRecording.batteryEvents.append(ScaleBatteryEvent(
                arrivalTime: Date(),
                monotonicSeconds: CACurrentMediaTime(),
                scaleKind: activeProtocol,
                percent: batteryPercent
            ))
        }
        currentMetrics = .empty
        liveMetricsAnalysisInFlight = false
        lastLiveMetricsRefreshSeconds = -Double.infinity
        isFinalizing = false
        statusMessage = "Recording \(mode.displayName)"
        flushLiveUIRefresh()
    }

    func stopRecording(atMonotonicSeconds recordingEnd: Double = CACurrentMediaTime()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopRecording(atMonotonicSeconds: recordingEnd) }
            return
        }
        guard isRecording else { return }
        recordingGeneration &+= 1
        let generation = recordingGeneration
        isRecording = false
        isFinalizing = true
        reconnectPending = false
        currentRecording.endedAt = Date()
        currentRecording.recordingEndMonotonicSeconds = recordingEnd
        liveMetricsAnalysisInFlight = false
        lastLiveMetricsRefreshSeconds = -Double.infinity
        let snapshot = currentRecording
        statusMessage = "Analyzing recording"
        flushLiveUIRefresh()
        liveMetricsQueue.async { [weak self] in
            var finalized = snapshot
            finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)
            DispatchQueue.main.async {
                guard let self,
                      self.recordingGeneration == generation,
                      self.currentRecording.id == snapshot.id else { return }
                self.currentRecording = finalized
                self.currentMetrics = finalized.metrics
                self.completedRecording = finalized
                self.isFinalizing = false
                self.statusMessage = "Recording stopped"
                self.flushLiveUIRefresh()
            }
        }
    }

    func noteAppEnteredBackground(atMonotonicSeconds timestamp: Double = CACurrentMediaTime()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.noteAppEnteredBackground(atMonotonicSeconds: timestamp) }
            return
        }
        guard isRecording, recordingAppIsForeground else { return }
        recordingAppIsForeground = false
        currentRecording.events.append(ScaleRecordingEvent(
            type: .appBackgrounded,
            monotonicSeconds: timestamp
        ))
        statusMessage = "Recording continued, but this result is not eligible for an official score"
    }

    func noteAppBecameForeground(atMonotonicSeconds timestamp: Double = CACurrentMediaTime()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.noteAppBecameForeground(atMonotonicSeconds: timestamp) }
            return
        }
        guard isRecording, !recordingAppIsForeground else {
            recordingAppIsForeground = true
            return
        }
        recordingAppIsForeground = true
        currentRecording.events.append(ScaleRecordingEvent(
            type: .appForegrounded,
            monotonicSeconds: timestamp
        ))
        statusMessage = "Recording resumed; app backgrounding invalidated the official result"
    }

    func resetRecording() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.resetRecording() }
            return
        }
        recordingGeneration &+= 1
        recordingAppIsForeground = true
        completedRecording = nil
        isRecording = false
        isFinalizing = false
        currentRecording = .empty()
        currentMetrics = .empty
        latestSample = nil
        liveMetricsAnalysisInFlight = false
        lastLiveMetricsRefreshSeconds = -Double.infinity
        statusMessage = connectedDevice == nil ? "Idle" : "Connected"
        flushLiveUIRefresh()
    }

    func takeCompletedRecording() -> ScaleRecording? {
        guard Thread.isMainThread else { return nil }
        defer { completedRecording = nil }
        return completedRecording
    }

    var connectedAdvertisedServices: [String] {
        guard let connectedDevice else { return [] }
        return advertisedServicesByID[connectedDevice.id] ?? []
    }

    func applyScoringProfile(_ profile: ScoringProfile) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.applyScoringProfile(profile) }
            return
        }
        currentRecording.scoringProfile = profile
        currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording, profile: profile)
        currentMetrics = currentRecording.metrics
    }

    func finalizedCurrentRecording(notes: String = "") -> ScaleRecording {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                finalizedCurrentRecording(notes: notes)
            }
        }
        var finalized = currentRecording
        finalized.endedAt = finalized.endedAt ?? Date()
        if finalized.recordingEndMonotonicSeconds == nil {
            finalized.recordingEndMonotonicSeconds = CACurrentMediaTime()
        }
        finalized.notes = notes
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)
        return finalized
    }

    func exportCurrentRecording(notes: String = "") -> URL? {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync {
                exportCurrentRecording(notes: notes)
            }
        }
        do {
            let finalized = finalizedCurrentRecording(notes: notes)
            currentRecording = finalized
            currentMetrics = finalized.metrics
            return try RecordingExporter.export(finalized)
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func sendAtomicTareAndStart() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.sendAtomicTareAndStart() }
            return
        }
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

    private func scheduleTransportReconnect(to peripheral: CBPeripheral) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.isRecording,
                  self.currentRecording.mode == .transportStress,
                  self.connectedDevice?.id == peripheral.identifier,
                  !self.isConnectionReady else { return }
            self.statusMessage = "Reconnecting to \(self.connectedDevice?.name ?? "scale")"
            self.centralManager.connect(peripheral)
        }
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func recordRawPacket(
        data: Data,
        characteristic: CBCharacteristic,
        role: PacketRole,
        rejectionReason: ParseRejectionReason?,
        sample: ScaleSample? = nil,
        arrivalTime: Date = Date(),
        monotonicSeconds: Double = CACurrentMediaTime()
    ) {
        guard isRecording else { return }

        let packetKind = sample?.scaleKind ?? activeProtocol
        let characteristicUUID = characteristic.uuid.uuidString.uppercased()

        currentRecording.rawPackets.append(RawScalePacket(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: packetKind,
            characteristicUUID: characteristicUUID,
            role: role,
            bytesHex: data.hexString,
            rejectionReason: rejectionReason,
            weightGrams: sample?.weightGrams,
            sequence: sample?.sequence,
            deviceTimestampMilliseconds: sample?.deviceTimestampMilliseconds,
            fields: nil
        ))

        if let sample {
            updateScoringCapabilities(for: sample, characteristic: characteristic)
        }
        scheduleLiveUIRefresh()
    }

    private func receiveSample(_ sample: ScaleSample) {
        latestSample = sample
        if let batteryPercent = sample.batteryPercent, (0...100).contains(batteryPercent) {
            latestBatteryPercent = batteryPercent
        }
        if !(activeProtocol == .weighMyBruPlus && sample.scaleKind == .weighMyBru),
           activeProtocol != sample.scaleKind {
            activeProtocol = sample.scaleKind
        }

        scheduleLiveUIRefresh()
        guard isRecording else { return }
        currentRecording.samples.append(sample)
        refreshCurrentMetricsIfNeeded(monotonicSeconds: sample.monotonicSeconds)
    }

    private func receiveBattery(_ percent: Int, arrivalTime: Date = Date(), monotonicSeconds: Double = CACurrentMediaTime()) {
        guard (0...100).contains(percent) else { return }
        latestBatteryPercent = percent
        scheduleLiveUIRefresh()
        guard isRecording else { return }
        currentRecording.batteryEvents.append(ScaleBatteryEvent(
            arrivalTime: arrivalTime,
            monotonicSeconds: monotonicSeconds,
            scaleKind: activeProtocol,
            percent: percent
        ))
        refreshCurrentMetricsIfNeeded(monotonicSeconds: monotonicSeconds)
    }

    private func refreshCurrentMetricsIfNeeded(monotonicSeconds: Double) {
        guard isRecording else { return }
        guard monotonicSeconds - lastLiveMetricsRefreshSeconds >= liveMetricsRefreshIntervalSeconds else { return }
        guard !liveMetricsAnalysisInFlight else { return }

        lastLiveMetricsRefreshSeconds = monotonicSeconds
        guard currentRecording.samples.count <= maxSamplesForFullLiveMetrics else { return }
        liveMetricsAnalysisInFlight = true
        let snapshot = currentRecording
        let generation = recordingGeneration
        liveMetricsQueue.async { [weak self] in
            let metrics = ScaleQualityAnalyzer.analyze(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.liveMetricsAnalysisInFlight = false
                guard self.isRecording,
                      self.recordingGeneration == generation,
                      self.currentRecording.id == snapshot.id else { return }
                self.currentRecording.metrics = metrics
                self.currentMetrics = metrics
                self.scheduleLiveUIRefresh()
            }
        }
    }

    private func scheduleLiveUIRefresh() {
        guard liveUIRefreshWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveUIRefreshWorkItem = nil
            self.liveDisplayRevision &+= 1
        }
        liveUIRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + liveUIRefreshIntervalSeconds,
            execute: workItem
        )
    }

    private func flushLiveUIRefresh() {
        liveUIRefreshWorkItem?.cancel()
        liveUIRefreshWorkItem = nil
        liveDisplayRevision &+= 1
    }

    private func handleParserEvent(_ event: ScaleParserEvent, data: Data, characteristic: CBCharacteristic, arrivalTime: Date, monotonicSeconds: Double) {
        switch event {
        case let .sample(sample):
            recordRawPacket(data: data, characteristic: characteristic, role: .weight, rejectionReason: nil, sample: sample, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
            receiveSample(sample)
        case let .battery(percent):
            recordRawPacket(data: data, characteristic: characteristic, role: .battery, rejectionReason: nil, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
            receiveBattery(percent, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
        case let .rejected(reason):
            let role: PacketRole = reason == .unsupportedFrame ? .unknown : .weight
            recordRawPacket(data: data, characteristic: characteristic, role: role, rejectionReason: reason, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
        }
    }

    private func handleResult(_ result: Result<ScaleSample, ParseRejectionReason>, data: Data, characteristic: CBCharacteristic, arrivalTime: Date, monotonicSeconds: Double) {
        let characteristicUUID = characteristic.uuid.uuidString.uppercased()
        switch result {
        case let .success(sample):
            if characteristicUUID == WeighMyBruParser.weight20UUID {
                hasSeenWMBPlusWeightTransport = true
            }
            if shouldTreatAsCompatibilityTransport(sample: sample, characteristicUUID: characteristicUUID) {
                recordRawPacket(data: data, characteristic: characteristic, role: .unknown, rejectionReason: nil, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
                return
            }
            recordRawPacket(data: data, characteristic: characteristic, role: .weight, rejectionReason: nil, sample: sample, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
            receiveSample(sample)
        case let .failure(reason):
            recordRawPacket(data: data, characteristic: characteristic, role: .weight, rejectionReason: reason, arrivalTime: arrivalTime, monotonicSeconds: monotonicSeconds)
        }
    }

    private func shouldTreatAsCompatibilityTransport(sample: ScaleSample, characteristicUUID: String) -> Bool {
        guard sample.scaleKind == .weighMyBru,
              characteristicUUID == WeighMyBruParser.float32UUID else {
            return false
        }
        return activeProtocol == .weighMyBruPlus
            || wmbPlusCapabilities?.supportsExtendedPacket == true
            || notifyingMeasurementCharacteristicUUIDs.contains(WeighMyBruParser.weight20UUID)
            || hasSeenWMBPlusWeightTransport
    }

    private func baseScoringCapabilities(for kind: ScaleKind) -> ProtocolScoringCapabilities {
        let hasChecksum: Bool
        switch kind {
        case .bookoo, .bookooMini, .bookooUltra, .weighMyBruPlus, .acaia, .difluid, .difluidTi, .timemoreDot:
            hasChecksum = true
        default:
            hasChecksum = false
        }
        let clockSemantics: DeviceClockSemantics
        switch kind {
        case .decent, .espressi:
            clockSemantics = .shotTimer
        default:
            clockSemantics = .none
        }
        return ProtocolScoringCapabilities(
            hasChecksum: hasChecksum,
            hasSequence: false,
            sequenceModulus: nil,
            hasDeviceClock: false,
            deviceClockSemantics: clockSemantics,
            deviceClockModulus: nil
        )
    }

    private func updateScoringCapabilities(for sample: ScaleSample, characteristic: CBCharacteristic) {
        var capabilities = currentRecording.protocolCapabilities ?? baseScoringCapabilities(for: sample.scaleKind)
        if characteristic.uuid.uuidString.uppercased() == WeighMyBruParser.weight20UUID {
            capabilities.hasChecksum = true
        }
        capabilities.hasSequence = capabilities.hasSequence || sample.sequence != nil
        if sample.sequence != nil, capabilities.sequenceModulus == nil {
            capabilities.sequenceModulus = 256
        }
        capabilities.hasDeviceClock = capabilities.hasDeviceClock || sample.deviceTimestampMilliseconds != nil
        if sample.deviceTimestampMilliseconds != nil {
            switch sample.scaleKind {
            case .decent, .espressi:
                capabilities.deviceClockSemantics = .shotTimer
            case .bookoo, .bookooMini, .bookooUltra, .weighMyBruPlus:
                capabilities.deviceClockSemantics = .freeRunning
                capabilities.deviceClockModulus = 1 << 24
            case .difluid, .difluidTi:
                capabilities.deviceClockSemantics = .freeRunning
                capabilities.deviceClockModulus = 1 << 32
            default:
                capabilities.deviceClockSemantics = .freeRunning
            }
        }
        currentRecording.protocolCapabilities = capabilities
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
                if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
                return lhs.kind.displayName == rhs.kind.displayName ? lhs.name < rhs.name : lhs.kind.displayName < rhs.kind.displayName
            }
            if discoveredScales.count > maxDiscoveredScales {
                discoveredScales.removeSubrange(maxDiscoveredScales...)
            }
        }
    }

    private func handleValueUpdate(data: Data, characteristic: CBCharacteristic, arrival: Date, monotonic: Double) {
        let uuid = characteristic.uuid.uuidString.uppercased()

        switch uuid {
        case BookooParser.notifyUUID:
            handleResult(
                BookooParser.parseWeightPacket(data, kind: activeProtocol, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic,
                arrivalTime: arrival,
                monotonicSeconds: monotonic
            )

        case WeighMyBruParser.weight20UUID:
            handleResult(
                WeighMyBruParser.parse20BytePacket(data, capabilities: wmbPlusCapabilities, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic,
                arrivalTime: arrival,
                monotonicSeconds: monotonic
            )

        case WeighMyBruParser.float32UUID:
            handleResult(
                WeighMyBruParser.parseFloat32Packet(data, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic,
                arrivalTime: arrival,
                monotonicSeconds: monotonic
            )

        case WeighMyBruParser.capabilitiesUUID:
            recordRawPacket(data: data, characteristic: characteristic, role: .capabilities, rejectionReason: nil, arrivalTime: arrival, monotonicSeconds: monotonic)
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
            if let value = data.first, value <= 100 { receiveBattery(Int(value), arrivalTime: arrival, monotonicSeconds: monotonic) }
            recordRawPacket(data: data, characteristic: characteristic, role: .battery, rejectionReason: nil, arrivalTime: arrival, monotonicSeconds: monotonic)

        case WeighMyBruParser.commandUUID:
            recordRawPacket(data: data, characteristic: characteristic, role: .commandAck, rejectionReason: nil, arrivalTime: arrival, monotonicSeconds: monotonic)

        case AcaiaParser.modernCharUUID, AcaiaParser.fullModernCharUUID, AcaiaParser.legacyNotifyUUID:
            for event in acaiaCodec.receive(data, arrivalTime: arrival, monotonicSeconds: monotonic) {
                handleParserEvent(event, data: data, characteristic: characteristic, arrivalTime: arrival, monotonicSeconds: monotonic)
            }

        case DecentEspressiParser.notifyUUID where activeProtocol == .decent || activeProtocol == .espressi:
            handleResult(
                DecentEspressiParser.parseWeightPacket(data, kind: activeProtocol, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic,
                arrivalTime: arrival,
                monotonicSeconds: monotonic
            )

        case DiFluidParser.charUUID where activeProtocol == .difluid || activeProtocol == .difluidTi:
            handleParserEvent(
                DiFluidParser.parse(data, kind: activeProtocol, arrivalTime: arrival, monotonicSeconds: monotonic),
                data: data,
                characteristic: characteristic,
                arrivalTime: arrival,
                monotonicSeconds: monotonic
            )

        case EurekaPrecisaParser.notifyUUID where activeProtocol == .eureka:
            handleResult(EurekaPrecisaParser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic, arrivalTime: arrival, monotonicSeconds: monotonic)

        case FelicitaParser.charUUID:
            handleResult(FelicitaParser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic, arrivalTime: arrival, monotonicSeconds: monotonic)

        case FutulaParser.notifyUUID where activeProtocol == .futula:
            handleResult(FutulaParser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic, arrivalTime: arrival, monotonicSeconds: monotonic)

        case Skale2Parser.notifyUUID:
            handleResult(Skale2Parser.parse(data, arrivalTime: arrival, monotonicSeconds: monotonic), data: data, characteristic: characteristic, arrivalTime: arrival, monotonicSeconds: monotonic)

        case TimemoreDotParser.notifyUUID where activeProtocol == .timemoreDot:
            for event in timemoreDotCodec.receive(data, arrivalTime: arrival, monotonicSeconds: monotonic) {
                handleParserEvent(event, data: data, characteristic: characteristic, arrivalTime: arrival, monotonicSeconds: monotonic)
            }

        default:
            recordRawPacket(data: data, characteristic: characteristic, role: .unknown, rejectionReason: nil, arrivalTime: arrival, monotonicSeconds: monotonic)
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

    private func isMeasurementCharacteristic(_ uuid: String) -> Bool {
        switch uuid {
        case BookooParser.notifyUUID,
             WeighMyBruParser.weight20UUID,
             WeighMyBruParser.float32UUID,
             AcaiaParser.modernCharUUID,
             AcaiaParser.fullModernCharUUID,
             AcaiaParser.legacyNotifyUUID,
             DecentEspressiParser.notifyUUID,
             DiFluidParser.charUUID,
             EurekaPrecisaParser.notifyUUID,
             FelicitaParser.charUUID,
             FutulaParser.notifyUUID,
             Skale2Parser.notifyUUID,
             TimemoreDotParser.notifyUUID:
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
        let title: String
        switch central.state {
        case .unknown: title = "Bluetooth unknown"
        case .resetting: title = "Bluetooth resetting"
        case .unsupported: title = "Bluetooth unsupported"
        case .unauthorized: title = "Bluetooth unauthorized"
        case .poweredOff: title = "Bluetooth off"
        case .poweredOn: title = "Bluetooth on"
        @unknown default: title = "Bluetooth unknown"
        }
        performOnMain {
            self.bluetoothStateTitle = title
            if central.state != .poweredOn {
                self.isConnectionReady = false
                self.notifyingMeasurementCharacteristicUUIDs.removeAll()
            }
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
        let device = DiscoveredScale(
            id: peripheral.identifier,
            name: name,
            kind: kind,
            rssi: RSSI.intValue
        )
        performOnMain {
            self.peripheralsByID[peripheral.identifier] = peripheral
            self.advertisedServicesByID[peripheral.identifier] = services
            self.appendOrUpdate(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        performOnMain {
            self.isConnectionReady = false
            self.notifyingMeasurementCharacteristicUUIDs.removeAll()
            self.statusMessage = "Configuring \(peripheral.name ?? "scale")"
            peripheral.delegate = self
            self.didSendInitialConfiguration = false
            self.acaiaCodec = AcaiaParser.Codec()
            self.timemoreDotCodec = TimemoreDotParser.Codec()
            peripheral.discoverServices(nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        performOnMain {
            guard self.connectedDevice?.id == peripheral.identifier else { return }
            self.isConnectionReady = false
            self.notifyingMeasurementCharacteristicUUIDs.removeAll()
            self.writeCharacteristic = nil
            self.latestSample = nil
            self.latestBatteryPercent = nil
            if self.isRecording, self.currentRecording.mode == .transportStress {
                self.reconnectPending = true
                self.statusMessage = "Reconnect failed; retrying"
                self.scheduleTransportReconnect(to: peripheral)
            } else {
                self.statusMessage = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
                self.connectedDevice = nil
                self.activeProtocol = .unknown
                self.reconnectPending = false
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let disconnectedAt = CACurrentMediaTime()
        performOnMain {
            guard self.connectedDevice?.id == peripheral.identifier else { return }
            self.isConnectionReady = false
            self.notifyingMeasurementCharacteristicUUIDs.removeAll()
            self.writeCharacteristic = nil
            self.didSendInitialConfiguration = false
            self.acaiaCodec = AcaiaParser.Codec()
            self.timemoreDotCodec = TimemoreDotParser.Codec()
            if self.isRecording {
                self.currentRecording.events.append(ScaleRecordingEvent(type: .disconnect, monotonicSeconds: disconnectedAt))
                if self.currentRecording.mode == .transportStress {
                    self.reconnectPending = true
                    self.statusMessage = "Disconnected; Transport Stress is reconnecting"
                    self.scheduleTransportReconnect(to: peripheral)
                    return
                }
                self.stopRecording(atMonotonicSeconds: disconnectedAt)
                self.statusMessage = "Disconnected; recording stopped"
            } else {
                self.statusMessage = "Disconnected"
            }
            self.connectedDevice = nil
            self.activeProtocol = .unknown
            self.wmbPlusCapabilities = nil
            self.latestSample = nil
            self.latestBatteryPercent = nil
            self.reconnectPending = false
        }
    }
}

extension BluetoothScaleManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        performOnMain {
            if let error {
                self.statusMessage = "Service discovery failed: \(error.localizedDescription)"
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
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        performOnMain {
            if let error {
                self.statusMessage = "Characteristic discovery failed: \(error.localizedDescription)"
                return
            }

            service.characteristics?.forEach { characteristic in
                let uuid = characteristic.uuid.uuidString.uppercased()

                if self.isWritableCharacteristic(uuid) && (characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)) {
                    self.writeCharacteristic = characteristic
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
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        performOnMain {
            let uuid = characteristic.uuid.uuidString.uppercased()
            let isMeasurement = self.isMeasurementCharacteristic(uuid)
            if let error {
                if isMeasurement {
                    self.notifyingMeasurementCharacteristicUUIDs.remove(uuid)
                    if self.notifyingMeasurementCharacteristicUUIDs.isEmpty {
                        self.isConnectionReady = false
                        self.statusMessage = "Weight notification setup failed: \(error.localizedDescription)"
                    }
                }
                return
            }

            guard isMeasurement else { return }
            if characteristic.isNotifying {
                self.notifyingMeasurementCharacteristicUUIDs.insert(uuid)
                self.sendInitialConfigurationIfNeeded()
                if !self.isConnectionReady {
                    self.isConnectionReady = true
                    if self.reconnectPending {
                        if self.isRecording {
                            self.currentRecording.events.append(ScaleRecordingEvent(
                                type: .reconnect,
                                monotonicSeconds: CACurrentMediaTime()
                            ))
                        }
                        self.reconnectPending = false
                        self.statusMessage = self.isRecording
                            ? "Reconnected; recording \(self.currentRecording.mode.displayName)"
                            : "Ready"
                    } else {
                        self.statusMessage = self.isRecording
                            ? "Recording \(self.currentRecording.mode.displayName)"
                            : "Ready"
                    }
                }
            } else {
                self.notifyingMeasurementCharacteristicUUIDs.remove(uuid)
                if self.notifyingMeasurementCharacteristicUUIDs.isEmpty {
                    self.isConnectionReady = false
                    self.statusMessage = "Weight notifications stopped"
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let monotonic = CACurrentMediaTime()
        let arrival = Date()
        if let error {
            performOnMain {
                self.statusMessage = "Value update failed: \(error.localizedDescription)"
            }
            return
        }
        guard let data = characteristic.value else { return }
        performOnMain {
            self.handleValueUpdate(data: data, characteristic: characteristic, arrival: arrival, monotonic: monotonic)
        }
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
        manager.isConnectionReady = true
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
