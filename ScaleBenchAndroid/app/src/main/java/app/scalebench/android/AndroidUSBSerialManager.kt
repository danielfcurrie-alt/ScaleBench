package app.scalebench.android

import android.app.Application
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.concurrent.thread

internal class AndroidUSBSerialManager(
    private val application: Application,
    private val onChanged: () -> Unit
) {
    private val liveMetricsExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ScaleBench-USB-LiveMetrics").apply { isDaemon = true }
    }
    private val usbManager = application.getSystemService(Context.USB_SERVICE) as UsbManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val parser = WMBPlusUSBSerialParser()
    private var readThread: Thread? = null
    private var connection: UsbDeviceConnection? = null
    private var claimedInterfaces: List<UsbInterface> = emptyList()
    private var outEndpoint: UsbEndpoint? = null
    private var running = false
    private var streamStarted = false
    private var permissionReceiverRegistered = false
    private var liveMetricsAnalysisInFlight = false
    private var recordingGeneration = 0L
    private var lastLiveMetricsRefreshSeconds = Double.NEGATIVE_INFINITY
    private var lastLiveUiRefreshSeconds = Double.NEGATIVE_INFINITY
    private val pendingLineLock = Any()
    private val pendingLines = mutableListOf<PendingUSBLine>()
    private var pendingDrainScheduled = false

    private val actionPermission = "${application.packageName}.USB_SERIAL_PERMISSION"
    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED ||
                intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED
            ) {
                status = "Refreshing USB devices"
                notifyChanged()
                mainHandler.postDelayed({ refreshDevices() }, 300)
                return
            }
            if (intent.action != actionPermission) return
            val device = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                selectedDeviceName = device?.deviceName ?: selectedDeviceName
                status = "USB permission granted"
            } else {
                status = "USB permission denied"
            }
            notifyChanged()
        }
    }

    var devices: List<USBSerialDeviceSummary> = emptyList()
        private set
    var selectedDeviceName: String = ""
        private set
    var status: String = "Plug in a USB scale"
        private set
    var isRecording: Boolean = false
        private set
    var isFinalizing: Boolean = false
        private set
    var latestSample: ScaleSample? = null
        private set
    var currentRecording: ScaleRecording = ScaleRecording.empty(RecordingMode.SHOT)
        private set
    var currentMetrics: ScaleQualityMetrics = ScaleQualityMetrics.empty()
        private set
    var completedRecording: ScaleRecording? = null
        private set
    var droppedCount: Long = 0
        private set
    var hostReceiveRateHz: Double? = null
        private set

    init {
        val filter = IntentFilter(actionPermission).apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                application.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                application.registerReceiver(permissionReceiver, filter)
            }
            permissionReceiverRegistered = true
        } catch (error: Exception) {
            status = "USB permission listener unavailable: ${error.message ?: "unknown error"}"
        }
        refreshDevices()
    }

    fun shutdown() {
        stopRecording()
        liveMetricsExecutor.shutdownNow()
        if (permissionReceiverRegistered) {
            runCatching { application.unregisterReceiver(permissionReceiver) }
            permissionReceiverRegistered = false
        }
    }

    fun refreshDevices() {
        devices = try {
            usbManager.deviceList.values
                .map { device ->
                    runCatching {
                        val serialEndpoints = findSerialEndpoints(device)
                        USBSerialDeviceSummary(
                            deviceName = device.deviceName,
                            label = usbDeviceLabel(device),
                            hasPermission = usbManager.hasPermission(device),
                            hasSerialEndpoints = serialEndpoints != null,
                            details = usbDeviceDetails(device, serialEndpoints)
                        )
                    }.getOrElse {
                        USBSerialDeviceSummary(
                            deviceName = device.deviceName,
                            label = String.format(Locale.US, "USB %04X:%04X", device.vendorId, device.productId),
                            hasPermission = false,
                            hasSerialEndpoints = false,
                            details = "Could not inspect USB interfaces"
                        )
                    }
                }
                .sortedBy { it.label }
        } catch (error: Exception) {
            status = "USB scan unavailable: ${error.message ?: "unknown error"}"
            emptyList()
        }
        if (selectedDeviceName.isBlank() || devices.none { it.deviceName == selectedDeviceName }) {
            selectedDeviceName = devices.firstOrNull()?.deviceName.orEmpty()
        }
        if (!status.startsWith("USB permission listener unavailable") &&
            !status.startsWith("USB scan unavailable")
        ) {
            status = if (devices.isEmpty()) {
                "No USB devices found"
            } else if (devices.any { it.hasSerialEndpoints }) {
                "Ready for USB serial at 115200 baud"
            } else {
                "USB device found, but no serial endpoints were detected"
            }
        }
        notifyChanged()
    }

    fun selectDevice(deviceName: String) {
        selectedDeviceName = deviceName
        notifyChanged()
    }

    fun requestPermission() {
        val device = selectedDevice() ?: run {
            status = "Select a USB serial scale first"
            notifyChanged()
            return
        }
        if (usbManager.hasPermission(device)) {
            status = "USB permission already granted"
            notifyChanged()
            return
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val intent = PendingIntent.getBroadcast(application, 0, Intent(actionPermission), flags)
        usbManager.requestPermission(device, intent)
        status = "Waiting for USB permission"
        notifyChanged()
    }

    fun startRecording(mode: RecordingMode, notes: String) {
        if (isRecording) return
        val device = selectedDevice() ?: run {
            status = "Select a USB serial scale first"
            notifyChanged()
            return
        }
        if (!usbManager.hasPermission(device)) {
            requestPermission()
            return
        }
        val endpoints = findSerialEndpoints(device) ?: run {
            status = "Selected USB device does not expose serial endpoints"
            notifyChanged()
            return
        }
        val opened = usbManager.openDevice(device) ?: run {
            status = "Could not open USB device"
            notifyChanged()
            return
        }

        try {
            for (usbInterface in endpoints.interfacesToClaim) {
                if (!opened.claimInterface(usbInterface, true)) {
                    throw IllegalStateException("Could not claim USB interface")
                }
            }
            configureCdc(opened, endpoints.controlInterface)
            connection = opened
            claimedInterfaces = endpoints.interfacesToClaim
            outEndpoint = endpoints.outEndpoint
            running = true
            streamStarted = true
            parser.reset()
            latestSample = null
            droppedCount = 0
            hostReceiveRateHz = null
            completedRecording = null
            recordingGeneration++
            liveMetricsAnalysisInFlight = false
            synchronized(pendingLineLock) {
                pendingLines.clear()
                pendingDrainScheduled = false
            }
            isFinalizing = false
            lastLiveMetricsRefreshSeconds = Double.NEGATIVE_INFINITY
            lastLiveUiRefreshSeconds = Double.NEGATIVE_INFINITY
            currentRecording = ScaleRecording.empty(mode)
            currentRecording.appVersion = BuildConfig.VERSION_NAME
            currentRecording.appBuild = BuildConfig.VERSION_CODE.toString()
            currentRecording.source = RecordingSource.USB_SERIAL
            currentRecording.protocolName = WMBPlusUSBSerialParser.PROTOCOL_NAME
            currentRecording.serialBaud = WMBPlusUSBSerialParser.BAUD
            currentRecording.notes = notes
            currentRecording.recordingStartMonotonicSeconds = nowSeconds()
            currentRecording.device = ScaleDeviceIdentity().apply {
                name = WMBPlusUSBSerialParser.DEVICE_NAME
                identifier = device.deviceName
                kind = ScaleKind.WEIGH_MY_BRU_PLUS
                advertisedServices = emptyList()
            }
            currentRecording.protocolCapabilities = ProtocolScoringCapabilities().apply {
                hasChecksum = false
                hasSequence = true
                sequenceModulus = 1L shl 32
                hasDeviceClock = true
                deviceClockSemantics = DeviceClockSemantics.FREE_RUNNING
                deviceClockModulus = 1L shl 32
            }
            currentMetrics = ScaleQualityMetrics.empty()
            isRecording = true
            status = "Recording WMB+ USB Serial; waiting for rows"
            send("b\n")
            send("w\n")
            startReadLoop(opened, endpoints.inEndpoint)
            notifyChanged()
        } catch (error: Exception) {
            opened.close()
            status = "USB start failed: ${error.message}"
            notifyChanged()
        }
    }

    fun stopRecording() {
        if (!isRecording && !running) return
        if (streamStarted) runCatching { send("w\n") }
        streamStarted = false
        running = false
        readThread?.interrupt()
        readThread = null
        drainPendingLines()
        val opened = connection
        for (usbInterface in claimedInterfaces) {
            runCatching { opened?.releaseInterface(usbInterface) }
        }
        opened?.close()
        connection = null
        claimedInterfaces = emptyList()
        outEndpoint = null
        if (isRecording) {
            recordingGeneration++
            currentRecording.endedAtMillis = System.currentTimeMillis()
            currentRecording.recordingEndMonotonicSeconds = nowSeconds()
            val snapshot = liveAnalysisSnapshot(currentRecording)
            val generation = recordingGeneration
            isFinalizing = true
            status = "Finalizing USB recording"
            liveMetricsExecutor.execute {
                val result = runCatching { ScaleQualityAnalyzer.analyze(snapshot) }
                mainHandler.post {
                    if (recordingGeneration != generation) return@post
                    isFinalizing = false
                    val metrics = result.getOrNull()
                    if (metrics != null) {
                        currentRecording.metrics = metrics
                        currentMetrics = metrics
                        completedRecording = currentRecording
                        status = "USB recording stopped"
                    } else {
                        status = "USB analysis failed: ${result.exceptionOrNull()?.message ?: "unknown error"}"
                    }
                    notifyChanged()
                }
            }
        }
        isRecording = false
        notifyChanged()
    }

    fun takeCompletedRecording(): ScaleRecording? {
        val snapshot = completedRecording
        completedRecording = null
        return snapshot
    }

    private fun startReadLoop(opened: UsbDeviceConnection, inEndpoint: UsbEndpoint) {
        readThread = thread(name = "ScaleBench-USB-Serial", isDaemon = true) {
            val buffer = ByteArray(4096)
            val lineBuffer = StringBuilder()
            while (running && !Thread.currentThread().isInterrupted) {
                val count = opened.bulkTransfer(inEndpoint, buffer, buffer.size, 250)
                if (count <= 0) continue
                val chunk = String(buffer, 0, count, StandardCharsets.UTF_8)
                for (char in chunk) {
                    if (char == '\n' || char == '\r') {
                        if (lineBuffer.isNotEmpty()) {
                            handleLine(lineBuffer.toString())
                            lineBuffer.clear()
                        }
                    } else {
                        lineBuffer.append(char)
                        if (lineBuffer.length > 4096) lineBuffer.clear()
                    }
                }
            }
        }
    }

    private fun handleLine(line: String) {
        val receivedAt = System.currentTimeMillis()
        val monotonic = nowSeconds()
        val result = parser.parse(line, receivedAt, monotonic)
        if (result.ignored) return
        synchronized(pendingLineLock) {
            pendingLines.add(PendingUSBLine(line, result, receivedAt, monotonic))
            if (!pendingDrainScheduled) {
                pendingDrainScheduled = true
                mainHandler.postDelayed({ drainPendingLines() }, USB_DRAIN_INTERVAL_MILLIS)
            }
        }
    }

    private fun drainPendingLines() {
        val batch = synchronized(pendingLineLock) {
            if (pendingLines.isEmpty()) {
                pendingDrainScheduled = false
                return
            }
            val lines = pendingLines.toList()
            pendingLines.clear()
            pendingDrainScheduled = false
            lines
        }
        if (!isRecording) return
        var lastMonotonic = batch.last().monotonicSeconds
        var statusMessage: String? = null
        for (entry in batch) {
            val result = entry.result
            if (result.sample != null && result.packet != null) {
                latestSample = result.sample
                droppedCount += result.sample.usbSerial?.usbDroppedDelta ?: 0
                currentRecording.rawPackets.add(result.packet)
                if (result.sample.statusFlags?.hx711Connected == true) {
                    currentRecording.samples.add(result.sample)
                    hostReceiveRateHz = hostReceiveRate(currentRecording.samples)
                } else {
                    result.packet.rejectionReason = ParseRejectionReason.UNSUPPORTED_FRAME
                }
                refreshLiveMetricsIfNeeded(entry.monotonicSeconds)
                statusMessage = "Recording WMB+ USB Serial"
            } else {
                val packet = RawScalePacket().apply {
                    arrivalTimeMillis = entry.receivedAtMillis
                    monotonicSeconds = entry.monotonicSeconds
                    scaleKind = ScaleKind.WEIGH_MY_BRU_PLUS
                    characteristicUuid = WMBPlusUSBSerialParser.PROTOCOL_NAME
                    role = PacketRole.WEIGHT
                    bytesHex = ScaleParsers.hex(entry.line.toByteArray(StandardCharsets.UTF_8))
                    rejectionReason = ParseRejectionReason.INVALID_RANGE
                }
                currentRecording.rawPackets.add(packet)
                statusMessage = "Ignored USB row: ${result.rejectionReason}"
            }
            lastMonotonic = entry.monotonicSeconds
        }
        if (statusMessage != null) {
            status = statusMessage
        }
        if (shouldPublishLiveUi(lastMonotonic)) {
            notifyChanged()
        }
    }

    private fun shouldPublishLiveUi(monotonicSeconds: Double): Boolean {
        if (monotonicSeconds - lastLiveUiRefreshSeconds < LIVE_UI_REFRESH_INTERVAL_SECONDS) return false
        lastLiveUiRefreshSeconds = monotonicSeconds
        return true
    }

    private fun refreshLiveMetricsIfNeeded(monotonicSeconds: Double) {
        if (!isRecording ||
            liveMetricsAnalysisInFlight ||
            monotonicSeconds - lastLiveMetricsRefreshSeconds < LIVE_METRICS_REFRESH_INTERVAL_SECONDS
        ) {
            return
        }
        lastLiveMetricsRefreshSeconds = monotonicSeconds
        if (currentRecording.samples.size > MAX_SAMPLES_FOR_FULL_LIVE_METRICS) return
        liveMetricsAnalysisInFlight = true
        val snapshot = liveAnalysisSnapshot(currentRecording)
        val generation = recordingGeneration
        liveMetricsExecutor.execute {
            val result = runCatching { ScaleQualityAnalyzer.analyze(snapshot) }
            mainHandler.post {
                liveMetricsAnalysisInFlight = false
                if (!isRecording ||
                    recordingGeneration != generation ||
                    currentRecording.id != snapshot.id
                ) {
                    return@post
                }
                val metrics = result.getOrNull()
                if (metrics != null) {
                    currentRecording.metrics = metrics
                    currentMetrics = metrics
                    notifyChanged()
                } else {
                    status = "Live diagnostics skipped: ${result.exceptionOrNull()?.message ?: "unknown error"}"
                    notifyChanged()
                }
            }
        }
    }

    private fun hostReceiveRate(samples: List<ScaleSample>): Double? {
        if (samples.size < 2) return null
        val span = samples.last().monotonicSeconds - samples.first().monotonicSeconds
        return if (span > 0) samples.size / span else null
    }

    private fun send(text: String) {
        val opened = connection ?: return
        val endpoint = outEndpoint ?: return
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        opened.bulkTransfer(endpoint, bytes, bytes.size, 1_000)
    }

    private fun selectedDevice(): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { it.deviceName == selectedDeviceName }

    private fun notifyChanged() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            onChanged()
        } else {
            mainHandler.post { onChanged() }
        }
    }

    private fun nowSeconds(): Double = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0

    companion object {
        private const val LIVE_UI_REFRESH_INTERVAL_SECONDS = 0.2
        private const val LIVE_METRICS_REFRESH_INTERVAL_SECONDS = 2.0
        private const val MAX_SAMPLES_FOR_FULL_LIVE_METRICS = 2_000
        private const val USB_DRAIN_INTERVAL_MILLIS = 50L

        private fun liveAnalysisSnapshot(source: ScaleRecording): ScaleRecording {
            val snapshot = ScaleRecording.empty(source.mode)
            snapshot.id = source.id
            snapshot.appVersion = source.appVersion
            snapshot.appBuild = source.appBuild
            snapshot.platform = source.platform
            snapshot.source = source.source
            snapshot.protocolName = source.protocolName
            snapshot.serialBaud = source.serialBaud
            snapshot.title = source.title
            snapshot.device = source.device
            snapshot.startedAtMillis = source.startedAtMillis
            snapshot.endedAtMillis = source.endedAtMillis
            snapshot.recordingStartMonotonicSeconds = source.recordingStartMonotonicSeconds
            snapshot.recordingEndMonotonicSeconds = source.recordingEndMonotonicSeconds
            snapshot.notes = source.notes
            snapshot.rawPackets.addAll(source.rawPackets)
            snapshot.samples.addAll(source.samples)
            snapshot.batteryEvents.addAll(source.batteryEvents)
            snapshot.events.addAll(source.events)
            snapshot.capabilities = source.capabilities
            snapshot.protocolCapabilities = copyProtocolCapabilities(source.protocolCapabilities)
            snapshot.link = source.link
            snapshot.scoringProfile = source.scoringProfile
            return snapshot
        }

        private fun copyProtocolCapabilities(source: ProtocolScoringCapabilities?): ProtocolScoringCapabilities? {
            if (source == null) return null
            return ProtocolScoringCapabilities().apply {
                hasChecksum = source.hasChecksum
                hasSequence = source.hasSequence
                sequenceModulus = source.sequenceModulus
                hasDeviceClock = source.hasDeviceClock
                deviceClockSemantics = source.deviceClockSemantics
                deviceClockModulus = source.deviceClockModulus
            }
        }

        private fun usbDeviceLabel(device: UsbDevice): String {
            val name = runCatching {
                listOfNotNull(device.productName, device.manufacturerName).firstOrNull()
            }.getOrNull()
            return name ?: String.format(Locale.US, "USB %04X:%04X", device.vendorId, device.productId)
        }

        private fun usbDeviceDetails(device: UsbDevice, endpoints: SerialEndpoints?): String {
            val serialStatus = if (endpoints == null) "no serial endpoints" else "serial endpoints detected"
            return String.format(
                Locale.US,
                "%04X:%04X · %d interface%s · %s",
                device.vendorId,
                device.productId,
                device.interfaceCount,
                if (device.interfaceCount == 1) "" else "s",
                serialStatus
            )
        }

        private fun findSerialEndpoints(device: UsbDevice): SerialEndpoints? {
            var controlInterface: UsbInterface? = null
            val claims = mutableListOf<UsbInterface>()
            var inEndpoint: UsbEndpoint? = null
            var outEndpoint: UsbEndpoint? = null

            for (index in 0 until device.interfaceCount) {
                val usbInterface = device.getInterface(index)
                if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_COMM) {
                    controlInterface = usbInterface
                    claims += usbInterface
                }
                for (endpointIndex in 0 until usbInterface.endpointCount) {
                    val endpoint = usbInterface.getEndpoint(endpointIndex)
                    if (endpoint.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                    if (endpoint.direction == UsbConstants.USB_DIR_IN && inEndpoint == null) {
                        inEndpoint = endpoint
                        if (!claims.contains(usbInterface)) claims += usbInterface
                    } else if (endpoint.direction == UsbConstants.USB_DIR_OUT && outEndpoint == null) {
                        outEndpoint = endpoint
                        if (!claims.contains(usbInterface)) claims += usbInterface
                    }
                }
            }

            val inEp = inEndpoint ?: return null
            val outEp = outEndpoint ?: return null
            return SerialEndpoints(controlInterface, claims.distinct(), inEp, outEp)
        }

        private fun configureCdc(connection: UsbDeviceConnection, controlInterface: UsbInterface?) {
            val interfaceId = controlInterface?.id ?: 0
            val lineCoding = byteArrayOf(
                0x00, 0xC2.toByte(), 0x01, 0x00,
                0x00, 0x00, 0x08
            )
            connection.controlTransfer(0x21, 0x20, 0, interfaceId, lineCoding, lineCoding.size, 1_000)
            connection.controlTransfer(0x21, 0x22, 0x03, interfaceId, null, 0, 1_000)
        }
    }
}

internal data class USBSerialDeviceSummary(
    val deviceName: String,
    val label: String,
    val hasPermission: Boolean,
    val hasSerialEndpoints: Boolean,
    val details: String
)

private data class SerialEndpoints(
    val controlInterface: UsbInterface?,
    val interfacesToClaim: List<UsbInterface>,
    val inEndpoint: UsbEndpoint,
    val outEndpoint: UsbEndpoint
)

private data class PendingUSBLine(
    val line: String,
    val result: WMBPlusUSBSerialParser.ParseResult,
    val receivedAtMillis: Long,
    val monotonicSeconds: Double
)
