import Foundation
import Combine
import QuartzCore

#if targetEnvironment(macCatalyst)
import Darwin
#endif

protocol USBSerialTransport: AnyObject {
    var onLine: ((String, Date, Double) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func open(path: String, baud: Int) throws
    func send(_ data: Data) throws
    func close()
}

enum USBSerialTransportError: LocalizedError {
    case unavailable
    case alreadyOpen
    case disconnected
    case openFailed(path: String, code: Int32)
    case configureFailed(code: Int32)
    case writeFailed(code: Int32)
    case readFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "USB serial recording is currently available on Mac. iPhone/iPad support requires external accessory/USB host support."
        case .alreadyOpen:
            "The selected serial port is already open."
        case .disconnected:
            "The USB serial device disconnected."
        case let .openFailed(path, code):
            "Could not open \(path) (error \(code))."
        case let .configureFailed(code):
            "Could not configure the serial port (error \(code))."
        case let .writeFailed(code):
            "Could not send a serial command (error \(code))."
        case let .readFailed(code):
            "USB serial reading stopped (error \(code))."
        }
    }
}

final class WMBPlusUSBSerialManager: ObservableObject {
    static let unavailableMessage = "USB serial recording is currently available on Mac. iPhone/iPad support requires external accessory/USB host support."

    @Published private(set) var serialPorts: [String] = []
    @Published var selectedPort: String = ""
    @Published private(set) var statusMessage = "Select a WMB+ USB serial port"
    @Published private(set) var isStarting = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var latestSample: ScaleSample?
    @Published private(set) var currentMetrics: ScaleQualityMetrics = .empty
    @Published private(set) var hostReceiveRateHz: Double?
    @Published private(set) var packetCount = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var droppedCount: UInt64 = 0
    @Published private(set) var statusLabels: [String] = []
    @Published private(set) var completedRecording: ScaleRecording?

    #if targetEnvironment(macCatalyst)
    let isSupported = true
    private let transport: USBSerialTransport = POSIXUSBSerialTransport()
    #else
    let isSupported = false
    private let transport: USBSerialTransport = UnsupportedUSBSerialTransport()
    #endif

    private let workQueue = DispatchQueue(label: "app.scalebench.usb-recording", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "app.scalebench.usb-analysis", qos: .utility)
    private var parser = WMBPlusUSBSerialParser()
    private var recording = ScaleRecording.empty()
    private var captureActive = false
    private var streamStarted = false
    private var generation = 0
    private var lastBatteryPercent: Int?
    private var lastUIPublishSeconds = -Double.infinity
    private var lastMetricsRefreshSeconds = -Double.infinity
    private var metricsAnalysisInFlight = false

    init() {
        transport.onLine = { [weak self] line, receivedAt, monotonicSeconds in
            self?.workQueue.async {
                self?.handle(line: line, receivedAt: receivedAt, monotonicSeconds: monotonicSeconds)
            }
        }
        transport.onError = { [weak self] error in
            self?.workQueue.async {
                self?.handleTransportError(error)
            }
        }
        refreshPorts()
    }

    func refreshPorts() {
        guard isSupported else {
            statusMessage = Self.unavailableMessage
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ports = Self.discoverSerialPorts()
            DispatchQueue.main.async {
                guard let self else { return }
                self.serialPorts = ports
                if !ports.contains(self.selectedPort) {
                    self.selectedPort = ports.first ?? ""
                }
                if !self.isRecording && !self.isStarting && !self.isFinalizing {
                    self.statusMessage = ports.isEmpty
                        ? "No USB serial ports found"
                        : "Ready at 115200 baud"
                }
            }
        }
    }

    func startRecording(mode: RecordingMode, scoringProfile: ScoringProfile = .standard) {
        guard isSupported else {
            statusMessage = Self.unavailableMessage
            return
        }
        guard !selectedPort.isEmpty else {
            statusMessage = "Select a USB serial port first"
            return
        }
        guard !isRecording, !isStarting, !isFinalizing else { return }

        let port = selectedPort
        isStarting = true
        completedRecording = nil
        statusMessage = "Opening \(URL(fileURLWithPath: port).lastPathComponent)"
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.transport.open(path: port, baud: WMBPlusUSBSerialRow.baud)
                try self.transport.send(Data("b\n".utf8))

                let startedAt = Date()
                let startMonotonic = CACurrentMediaTime()
                self.generation &+= 1
                self.parser.reset()
                self.recording = ScaleRecording.empty(mode: mode, scoringProfile: scoringProfile)
                self.recording.source = .usbSerial
                self.recording.protocolName = WMBPlusUSBSerialRow.protocolName
                self.recording.serialBaud = WMBPlusUSBSerialRow.baud
                self.recording.startedAt = startedAt
                self.recording.recordingStartMonotonicSeconds = startMonotonic
                self.recording.device = ScaleDeviceIdentity(
                    name: WMBPlusUSBSerialRow.deviceName,
                    identifier: port,
                    kind: .weighMyBruPlus,
                    advertisedServices: []
                )
                self.recording.protocolCapabilities = ProtocolScoringCapabilities(
                    hasChecksum: false,
                    hasSequence: true,
                    sequenceModulus: UInt64(UInt32.max) + 1,
                    hasDeviceClock: true,
                    deviceClockSemantics: .freeRunning,
                    deviceClockModulus: UInt64(UInt32.max) + 1
                )
                self.captureActive = true
                self.streamStarted = true
                self.lastBatteryPercent = nil
                self.lastUIPublishSeconds = -Double.infinity
                self.lastMetricsRefreshSeconds = -Double.infinity
                self.metricsAnalysisInFlight = false
                try self.transport.send(Data("w\n".utf8))
                self.publishStart(port: port)
            } catch {
                self.transport.close()
                self.captureActive = false
                self.streamStarted = false
                self.recording = .empty()
                self.publishFailure(error)
            }
        }
    }

    func stopRecording() {
        guard isRecording || isStarting else { return }
        isStarting = false
        isRecording = false
        isFinalizing = true
        statusMessage = "Stopping USB stream"

        workQueue.async { [weak self] in
            guard let self else { return }
            if self.streamStarted {
                try? self.transport.send(Data("w\n".utf8))
            }
            self.streamStarted = false
            self.transport.close()
            guard self.captureActive else {
                DispatchQueue.main.async {
                    self.isFinalizing = false
                }
                return
            }
            self.captureActive = false
            self.generation &+= 1
            let finalGeneration = self.generation
            self.recording.endedAt = Date()
            self.recording.recordingEndMonotonicSeconds = CACurrentMediaTime()
            let snapshot = self.recording
            self.analysisQueue.async { [weak self] in
                guard let self else { return }
                var finalized = snapshot
                finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)
                self.workQueue.async {
                    guard self.generation == finalGeneration else { return }
                    DispatchQueue.main.async {
                        self.currentMetrics = finalized.metrics
                        self.completedRecording = finalized
                        self.isFinalizing = false
                        self.statusMessage = "USB recording stopped"
                    }
                }
            }
        }
    }

    func reset() {
        if isRecording || isStarting { stopRecording() }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.captureActive = false
            self.parser.reset()
            self.recording = .empty()
            DispatchQueue.main.async {
                self.isStarting = false
                self.isRecording = false
                self.isFinalizing = false
                self.completedRecording = nil
                self.latestSample = nil
                self.currentMetrics = .empty
                self.hostReceiveRateHz = nil
                self.packetCount = 0
                self.sampleCount = 0
                self.droppedCount = 0
                self.statusLabels = []
                self.statusMessage = self.serialPorts.isEmpty
                    ? "No USB serial ports found"
                    : "Ready at 115200 baud"
            }
        }
    }

    func takeCompletedRecording() -> ScaleRecording? {
        defer { completedRecording = nil }
        return completedRecording
    }

    private func handle(line: String, receivedAt: Date, monotonicSeconds: Double) {
        guard captureActive else { return }
        switch parser.parse(
            line: line,
            hostReceivedAt: receivedAt,
            hostMonotonicSeconds: monotonicSeconds
        ) {
        case .ignored:
            return
        case let .rejected(error):
            recording.rawPackets.append(RawScalePacket(
                arrivalTime: receivedAt,
                monotonicSeconds: monotonicSeconds,
                scaleKind: .weighMyBruPlus,
                characteristicUUID: "USB-SERIAL-115200",
                role: .weight,
                bytesHex: Data(line.utf8).hexString,
                rejectionReason: rejectionReason(for: error)
            ))
        case let .sample(row):
            let sensorConnected = row.isValidWeightSample
            let sample = row.sample
            recording.rawPackets.append(RawScalePacket(
                arrivalTime: receivedAt,
                monotonicSeconds: monotonicSeconds,
                scaleKind: .weighMyBruPlus,
                characteristicUUID: "USB-SERIAL-115200",
                role: .weight,
                bytesHex: Data(line.utf8).hexString,
                rejectionReason: sensorConnected ? nil : .unsupportedFrame,
                weightGrams: row.weightGrams,
                sequence: nil,
                deviceTimestampMilliseconds: row.firmwareMillis,
                fields: nil,
                usbSerial: row.metadata
            ))
            if sensorConnected {
                recording.samples.append(sample)
                if let battery = row.batteryPercent, battery != lastBatteryPercent {
                    recording.batteryEvents.append(ScaleBatteryEvent(
                        arrivalTime: receivedAt,
                        monotonicSeconds: monotonicSeconds,
                        scaleKind: .weighMyBruPlus,
                        percent: battery
                    ))
                    lastBatteryPercent = battery
                }
            }
        }

        publishLiveStateIfNeeded(monotonicSeconds: monotonicSeconds)
        refreshMetricsIfNeeded(monotonicSeconds: monotonicSeconds)
    }

    private func publishLiveStateIfNeeded(monotonicSeconds: Double) {
        guard monotonicSeconds - lastUIPublishSeconds >= 0.2 else { return }
        lastUIPublishSeconds = monotonicSeconds
        let sample = recording.samples.last
        let packets = recording.rawPackets.count
        let samples = recording.samples.count
        let dropped = recording.samples.reduce(UInt64(0)) { $0 + UInt64($1.usbSerial?.usbDroppedDelta ?? 0) }
        let labels = sample?.usbSerial?.usbStatusLabels ?? []
        let hostRate = Self.hostReceiveRateHz(for: recording.samples)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.latestSample = sample
            self.packetCount = packets
            self.sampleCount = samples
            self.droppedCount = dropped
            self.statusLabels = labels
            self.hostReceiveRateHz = hostRate
        }
    }

    private static func hostReceiveRateHz(for samples: [ScaleSample]) -> Double? {
        guard let first = samples.first?.monotonicSeconds,
              let last = samples.last?.monotonicSeconds,
              last > first else { return nil }
        return Double(samples.count) / (last - first)
    }

    private func refreshMetricsIfNeeded(monotonicSeconds: Double) {
        guard monotonicSeconds - lastMetricsRefreshSeconds >= 2, !metricsAnalysisInFlight else { return }
        lastMetricsRefreshSeconds = monotonicSeconds
        guard recording.samples.count <= 2_000 else { return }
        metricsAnalysisInFlight = true
        let snapshot = recording
        let currentGeneration = generation
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let metrics = ScaleQualityAnalyzer.analyze(snapshot)
            self.workQueue.async {
                self.metricsAnalysisInFlight = false
                guard self.captureActive, self.generation == currentGeneration else { return }
                DispatchQueue.main.async {
                    self.currentMetrics = metrics
                }
            }
        }
    }

    private func handleTransportError(_ error: Error) {
        guard captureActive else { return }
        streamStarted = false
        transport.close()
        captureActive = false
        generation &+= 1
        let finalGeneration = generation
        recording.endedAt = Date()
        recording.recordingEndMonotonicSeconds = CACurrentMediaTime()
        let snapshot = recording
        analysisQueue.async { [weak self] in
            guard let self else { return }
            var finalized = snapshot
            finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)
            self.workQueue.async {
                guard self.generation == finalGeneration else { return }
                DispatchQueue.main.async {
                    self.isStarting = false
                    self.isRecording = false
                    self.isFinalizing = false
                    self.currentMetrics = finalized.metrics
                    self.completedRecording = finalized
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func publishStart(port: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStarting = false
            self.isRecording = true
            self.isFinalizing = false
            self.latestSample = nil
            self.currentMetrics = .empty
            self.packetCount = 0
            self.sampleCount = 0
            self.droppedCount = 0
            self.statusLabels = []
            self.statusMessage = "Recording from \(URL(fileURLWithPath: port).lastPathComponent)"
        }
    }

    private func publishFailure(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.isStarting = false
            self?.isRecording = false
            self?.isFinalizing = false
            self?.statusMessage = error.localizedDescription
        }
    }

    private func rejectionReason(for error: WMBPlusUSBSerialParseError) -> ParseRejectionReason {
        switch error {
        case .fieldCount:
            .invalidLength
        case .invalidFloat:
            .invalidFloat
        case .invalidStatus, .invalidInteger, .invalidRange:
            .invalidRange
        }
    }

    private static func discoverSerialPorts() -> [String] {
        #if targetEnvironment(macCatalyst)
        let directory = URL(fileURLWithPath: "/dev", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { name in
            guard name.hasPrefix("cu.") || name.hasPrefix("tty.") else { return false }
            let lower = name.lowercased()
            return lower.contains("usb")
                || lower.contains("modem")
                || lower.contains("serial")
                || lower.contains("wch")
                || lower.contains("slab")
                || lower.contains("jlink")
        }
        let grouped = Dictionary(grouping: candidates) { name in
            name.replacingOccurrences(of: "cu.", with: "")
                .replacingOccurrences(of: "tty.", with: "")
        }
        return grouped.values.compactMap { names in
            let preferred = names.first(where: { $0.hasPrefix("cu.") }) ?? names.first
            return preferred.map { directory.appendingPathComponent($0).path }
        }.sorted()
        #else
        return []
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private final class POSIXUSBSerialTransport: USBSerialTransport {
    var onLine: ((String, Date, Double) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "app.scalebench.usb-serial", qos: .userInitiated)
    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var lineBuffer = USBSerialLineBuffer()

    func open(path: String, baud: Int) throws {
        guard baud == WMBPlusUSBSerialRow.baud else {
            throw USBSerialTransportError.configureFailed(code: EINVAL)
        }
        try queue.sync {
            guard fileDescriptor < 0 else { throw USBSerialTransportError.alreadyOpen }
            let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard descriptor >= 0 else {
                throw USBSerialTransportError.openFailed(path: path, code: errno)
            }

            var settings = termios()
            guard tcgetattr(descriptor, &settings) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw USBSerialTransportError.configureFailed(code: code)
            }
            cfmakeraw(&settings)
            settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
            settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
            settings.c_cflag |= tcflag_t(CS8)
            guard cfsetispeed(&settings, speed_t(B115200)) == 0,
                  cfsetospeed(&settings, speed_t(B115200)) == 0,
                  tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw USBSerialTransportError.configureFailed(code: code)
            }
            tcflush(descriptor, TCIOFLUSH)

            fileDescriptor = descriptor
            lineBuffer.reset()
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailableBytes() }
            readSource = source
            source.resume()
        }
    }

    func send(_ data: Data) throws {
        try queue.sync {
            guard fileDescriptor >= 0 else { throw USBSerialTransportError.unavailable }
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(fileDescriptor, base.advanced(by: offset), rawBuffer.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw USBSerialTransportError.writeFailed(code: errno)
                    }
                }
            }
        }
    }

    func close() {
        queue.sync {
            readSource?.setEventHandler {}
            readSource?.cancel()
            readSource = nil
            if fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
                fileDescriptor = -1
            }
            lineBuffer.reset()
        }
    }

    private func readAvailableBytes() {
        guard fileDescriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                let lines = lineBuffer.append(Data(buffer.prefix(count)))
                for line in lines {
                    onLine?(line, Date(), CACurrentMediaTime())
                }
            } else if count == 0 {
                onError?(USBSerialTransportError.disconnected)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                onError?(USBSerialTransportError.readFailed(code: errno))
                return
            }
        }
    }
}
#else
private final class UnsupportedUSBSerialTransport: USBSerialTransport {
    var onLine: ((String, Date, Double) -> Void)?
    var onError: ((Error) -> Void)?

    func open(path _: String, baud _: Int) throws { throw USBSerialTransportError.unavailable }
    func send(_: Data) throws { throw USBSerialTransportError.unavailable }
    func close() {}
}
#endif
