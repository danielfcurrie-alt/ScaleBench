package app.scalebench.android;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import no.nordicsemi.android.support.v18.scanner.BluetoothLeScannerCompat;
import no.nordicsemi.android.support.v18.scanner.ScanCallback;
import no.nordicsemi.android.support.v18.scanner.ScanResult;
import no.nordicsemi.android.support.v18.scanner.ScanSettings;

final class BluetoothScaleManager {
    private static final long TRANSPORT_RECONNECT_DELAY_MILLIS = 750;
    private static final long LIVE_UI_REFRESH_INTERVAL_MILLIS = 200;
    private static final double LIVE_METRICS_REFRESH_INTERVAL_SECONDS = 2.0;

    interface Listener {
        void onStateChanged();
    }

    private final Context context;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService liveMetricsExecutor = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "ScaleBench-LiveMetrics");
        thread.setDaemon(true);
        return thread;
    });
    private final Runnable liveUiRefreshRunnable;
    private final Map<String, DiscoveredScale> discovered = new LinkedHashMap<>();
    private BluetoothAdapter adapter;
    private BluetoothLeScannerCompat scanner;
    private ScaleBleSession session;
    private DiscoveredScale connectedDevice;
    private ScaleKind activeKind = ScaleKind.UNKNOWN;
    private WmbPlusCapabilities capabilities;
    private AcaiaCodec acaiaCodec = new AcaiaCodec();
    private TimemoreDotCodec timemoreDotCodec = new TimemoreDotCodec();
    private ScaleSample latestSample;
    private Integer latestBatteryPercent;
    private boolean scanning;
    private boolean ready;
    private boolean recording;
    private boolean finalizingRecording;
    private boolean recordingAppIsForeground = true;
    private boolean didSendInitialConfiguration;
    private boolean reconnectPending;
    private boolean liveUiRefreshPending;
    private boolean liveMetricsAnalysisInFlight;
    private boolean hasSeenWmbPlusWeightTransport;
    private long recordingGeneration;
    private double lastLiveMetricsRefreshSeconds = Double.NEGATIVE_INFINITY;
    private String status = "Idle";
    private ScaleRecording currentRecording = ScaleRecording.empty(RecordingMode.SHOT);
    private ScaleRecording completedRecording;

    BluetoothScaleManager(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        this.liveUiRefreshRunnable = () -> {
            liveUiRefreshPending = false;
            this.listener.onStateChanged();
        };
        BluetoothManager bluetoothManager = (BluetoothManager) this.context.getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = bluetoothManager == null ? null : bluetoothManager.getAdapter();
    }

    List<DiscoveredScale> discoveredScales() {
        return new ArrayList<>(discovered.values());
    }

    DiscoveredScale connectedDevice() {
        return connectedDevice;
    }

    @SuppressLint("MissingPermission")
    void disconnect() {
        if (recording) stopRecording();
        reconnectPending = false;
        mainHandler.removeCallbacks(transportReconnectRunnable);
        if (session != null) {
            session.close();
            session = null;
        }
        connectedDevice = null;
        ready = false;
        activeKind = ScaleKind.UNKNOWN;
        capabilities = null;
        latestSample = null;
        latestBatteryPercent = null;
        finalizingRecording = false;
        completedRecording = null;
        status = "Disconnected";
        notifyChanged();
    }

    ScaleSample latestSample() {
        return latestSample;
    }

    Integer latestBatteryPercent() {
        return latestBatteryPercent;
    }

    ScaleQualityMetrics currentMetrics() {
        return currentRecording.metrics;
    }

    ScaleRecording currentRecording() {
        return currentRecording;
    }

    String completedRecordingId() {
        return completedRecording == null ? null : completedRecording.id;
    }

    ScaleRecording takeCompletedRecording() {
        ScaleRecording completed = completedRecording;
        completedRecording = null;
        return completed;
    }

    boolean isScanning() {
        return scanning;
    }

    boolean isRecording() {
        return recording;
    }

    boolean isFinalizing() {
        return finalizingRecording;
    }

    boolean isConnected() {
        return ready && connectedDevice != null;
    }

    String status() {
        return status;
    }

    @SuppressLint("MissingPermission")
    void shutdown() {
        if (scanner != null && hasBluetoothPermissions()) scanner.stopScan(scanCallback);
        scanning = false;
        reconnectPending = false;
        recordingGeneration++;
        finalizingRecording = false;
        mainHandler.removeCallbacksAndMessages(null);
        liveMetricsExecutor.shutdownNow();
        if (session != null) {
            session.close();
            session = null;
        }
    }

    @SuppressLint("MissingPermission")
    void startScanning() {
        if (!hasBluetoothPermissions()) {
            status = "Bluetooth permission required";
            notifyChanged();
            return;
        }
        if (adapter == null || !adapter.isEnabled()) {
            status = "Bluetooth is off";
            notifyChanged();
            return;
        }
        scanner = BluetoothLeScannerCompat.getScanner();
        discovered.clear();
        scanning = true;
        status = "Scanning for scales";
        ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setUseHardwareBatchingIfSupported(false)
                .build();
        scanner.startScan(Collections.emptyList(), settings, scanCallback, mainHandler);
        notifyChanged();
    }

    @SuppressLint("MissingPermission")
    void stopScanning() {
        if (scanner != null && hasBluetoothPermissions()) scanner.stopScan(scanCallback);
        scanning = false;
        status = "Scan stopped";
        notifyChanged();
    }

    @SuppressLint("MissingPermission")
    void connect(DiscoveredScale scale) {
        if (!hasBluetoothPermissions() || adapter == null) return;
        stopScanning();
        if (session != null) {
            session.close();
            session = null;
        }
        mainHandler.removeCallbacks(transportReconnectRunnable);
        reconnectPending = false;
        finalizingRecording = false;
        connectedDevice = scale;
        ready = false;
        activeKind = scale.kind;
        capabilities = null;
        hasSeenWmbPlusWeightTransport = false;
        acaiaCodec = new AcaiaCodec();
        timemoreDotCodec = new TimemoreDotCodec();
        didSendInitialConfiguration = false;
        latestSample = null;
        latestBatteryPercent = null;
        BluetoothDevice device = adapter.getRemoteDevice(scale.address);
        status = "Connecting to " + scale.name;
        session = new ScaleBleSession(context, new ScaleBleSession.Listener() {
            @Override
            public void onReady(double monotonicSeconds) {
                ready = true;
                mainHandler.removeCallbacks(transportReconnectRunnable);
                if (recording && reconnectPending) {
                    ScaleRecordingEvent event = new ScaleRecordingEvent();
                    event.type = RecordingEventType.RECONNECT;
                    event.monotonicSeconds = monotonicSeconds;
                    currentRecording.events.add(event);
                }
                boolean wasReconnecting = reconnectPending;
                reconnectPending = false;
                status = recording && wasReconnecting
                        ? "Reconnected; recording " + currentRecording.mode.displayName
                        : "Ready";
                sendInitialConfigurationIfNeeded();
                notifyChanged();
            }

            @Override
            public void onDisconnected(double monotonicSeconds) {
                boolean wasReady = ready;
                ready = false;
                didSendInitialConfiguration = false;
                acaiaCodec = new AcaiaCodec();
                timemoreDotCodec = new TimemoreDotCodec();
                if (recording && wasReady) {
                    ScaleRecordingEvent event = new ScaleRecordingEvent();
                    event.type = RecordingEventType.DISCONNECT;
                    event.monotonicSeconds = monotonicSeconds;
                    currentRecording.events.add(event);
                }
                if (recording && currentRecording.mode == RecordingMode.TRANSPORT_STRESS) {
                    reconnectPending = true;
                    status = "Disconnected; Transport Stress is reconnecting";
                    scheduleTransportReconnect();
                } else if (recording) {
                    stopRecording(monotonicSeconds);
                    status = "Disconnected; recording stopped";
                } else {
                    status = "Disconnected";
                }
                notifyChanged();
            }

            @Override
            public void onUnsupportedDevice() {
                ready = false;
                reconnectPending = false;
                mainHandler.removeCallbacks(transportReconnectRunnable);
                status = "No supported scale services found";
                notifyChanged();
            }

            @Override
            public void onValue(String uuid, byte[] value, long arrivalMillis, double monotonicSeconds) {
                handleValue(uuid, value, arrivalMillis, monotonicSeconds);
            }
        });
        session.connectDevice(device);
        notifyChanged();
    }

    void startRecording(RecordingMode mode) {
        if (!isConnected()) {
            status = "Connect a scale before recording";
            notifyChanged();
            return;
        }
        double recordingStart = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0;
        recordingGeneration++;
        recordingAppIsForeground = true;
        recording = true;
        finalizingRecording = false;
        completedRecording = null;
        currentRecording = ScaleRecording.empty(mode);
        currentRecording.appVersion = BuildConfig.VERSION_NAME;
        currentRecording.appBuild = String.valueOf(BuildConfig.VERSION_CODE);
        currentRecording.recordingStartMonotonicSeconds = recordingStart;
        currentRecording.recordingEndMonotonicSeconds = null;
        currentRecording.capabilities = capabilities;
        currentRecording.protocolCapabilities = baseScoringCapabilities(activeKind);
        currentRecording.link.requestedConnectionPriority = "high";
        currentRecording.link.requestedMtu = 247;
        currentRecording.link.negotiatedMtu = session == null ? null : session.negotiatedMtu();
        if (connectedDevice != null) {
            ScaleDeviceIdentity identity = new ScaleDeviceIdentity();
            identity.name = connectedDevice.name;
            identity.identifier = connectedDevice.address;
            identity.kind = activeKind;
            identity.advertisedServices = connectedDevice.advertisedServices;
            currentRecording.device = identity;
        }
        if (latestBatteryPercent != null && latestBatteryPercent >= 0 && latestBatteryPercent <= 100) {
            receiveBattery(latestBatteryPercent);
        }
        lastLiveMetricsRefreshSeconds = Double.NEGATIVE_INFINITY;
        liveMetricsAnalysisInFlight = false;
        status = "Recording " + mode.displayName;
        notifyChanged();
    }

    void stopRecording() {
        stopRecording(SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0);
    }

    void noteAppEnteredBackground() {
        if (!recording || !recordingAppIsForeground) return;
        recordingAppIsForeground = false;
        ScaleRecordingEvent event = new ScaleRecordingEvent();
        event.type = RecordingEventType.APP_BACKGROUNDED;
        event.monotonicSeconds = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0;
        currentRecording.events.add(event);
        status = "Recording continued, but this result is not eligible for an official score";
        notifyChanged();
    }

    void noteAppBecameForeground() {
        if (!recording || recordingAppIsForeground) {
            recordingAppIsForeground = true;
            return;
        }
        recordingAppIsForeground = true;
        ScaleRecordingEvent event = new ScaleRecordingEvent();
        event.type = RecordingEventType.APP_FOREGROUNDED;
        event.monotonicSeconds = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0;
        currentRecording.events.add(event);
        status = "Recording resumed; app backgrounding invalidated the official result";
        notifyChanged();
    }

    private void stopRecording(double recordingEnd) {
        if (!recording) return;
        recordingGeneration++;
        recording = false;
        finalizingRecording = true;
        reconnectPending = false;
        mainHandler.removeCallbacks(transportReconnectRunnable);
        currentRecording.endedAtMillis = System.currentTimeMillis();
        currentRecording.recordingEndMonotonicSeconds = recordingEnd;
        liveMetricsAnalysisInFlight = false;
        lastLiveMetricsRefreshSeconds = Double.NEGATIVE_INFINITY;
        ScaleRecording snapshot = liveAnalysisSnapshot(currentRecording);
        long generation = recordingGeneration;
        status = "Analyzing recording";
        liveMetricsExecutor.execute(() -> {
            ScaleQualityMetrics metrics = null;
            String errorMessage = null;
            try {
                metrics = ScaleQualityAnalyzer.analyze(snapshot);
            } catch (Exception error) {
                errorMessage = error.getMessage() == null ? "unknown error" : error.getMessage();
            }
            ScaleQualityMetrics completedMetrics = metrics;
            String completedErrorMessage = errorMessage;
            mainHandler.post(() -> {
                if (recordingGeneration != generation || !currentRecording.id.equals(snapshot.id)) {
                    return;
                }
                finalizingRecording = false;
                if (completedMetrics != null) {
                    currentRecording = snapshot;
                    currentRecording.metrics = completedMetrics;
                    completedRecording = currentRecording;
                    status = "Recording stopped";
                } else {
                    status = "Analysis failed: " + completedErrorMessage;
                }
                notifyChanged();
            });
        });
        notifyChanged();
    }

    private void scheduleTransportReconnect() {
        mainHandler.removeCallbacks(transportReconnectRunnable);
        mainHandler.postDelayed(transportReconnectRunnable, TRANSPORT_RECONNECT_DELAY_MILLIS);
    }

    @SuppressLint("MissingPermission")
    private void attemptTransportReconnect() {
        if (!recording
                || currentRecording.mode != RecordingMode.TRANSPORT_STRESS
                || ready
                || connectedDevice == null
                || session == null
                || adapter == null
                || !adapter.isEnabled()
                || !hasBluetoothPermissions()) {
            return;
        }
        status = "Reconnecting to " + connectedDevice.name;
        notifyChanged();
        session.connectDevice(adapter.getRemoteDevice(connectedDevice.address));
    }

    private final Runnable transportReconnectRunnable = this::attemptTransportReconnect;

    @SuppressLint("MissingPermission")
    void sendAtomicTareAndStart() {
        if (session == null || !session.hasWritableCommand() || !hasBluetoothPermissions()) {
            status = "No writable command characteristic";
            notifyChanged();
            return;
        }
        byte[] command = activeKind == ScaleKind.BOOKOO || activeKind == ScaleKind.BOOKOO_MINI || activeKind == ScaleKind.BOOKOO_ULTRA
                ? ScaleParsers.BOOKOO_TARE_AND_START
                : ScaleParsers.WMB_ATOMIC_TARE_AND_START;
        write(command);
        status = "Atomic tare/start sent";
        notifyChanged();
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            handleScanResult(result);
        }

        @Override
        public void onBatchScanResults(List<ScanResult> results) {
            for (ScanResult result : results) handleScanResult(result);
        }

        @Override
        public void onScanFailed(int errorCode) {
            status = "Scan failed: " + errorCode;
            scanning = false;
            notifyChanged();
        }
    };

    @SuppressLint("MissingPermission")
    private void handleScanResult(ScanResult result) {
        if (!hasBluetoothPermissions()) return;
        BluetoothDevice device = result.getDevice();
        String name = device.getName();
        if ((name == null || name.trim().isEmpty()) && result.getScanRecord() != null) {
            name = result.getScanRecord().getDeviceName();
        }
        if (name == null || name.trim().isEmpty()) name = "Unnamed scale";

        List<String> services = new ArrayList<>();
        if (result.getScanRecord() != null && result.getScanRecord().getServiceUuids() != null) {
            for (android.os.ParcelUuid uuid : result.getScanRecord().getServiceUuids()) {
                services.add(ScaleParsers.shortUuid(uuid.getUuid().toString()));
            }
        }
        ScaleKind kind = ScaleParsers.identify(name, services);
        if (kind == ScaleKind.UNKNOWN) return;
        discovered.put(device.getAddress(), new DiscoveredScale(device.getAddress(), name, kind, result.getRssi(), services));
        status = "Found " + discovered.size() + " scale(s)";
        notifyChanged();
    }

    private void handleValue(String uuid, byte[] value, long arrival, double monotonic) {
        if (value == null) return;

        if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_CAPABILITIES_UUID)) {
            recordRaw(value, uuid, PacketRole.CAPABILITIES, null, arrival, monotonic);
            WmbPlusCapabilities parsed = ScaleParsers.parseCapabilities(value);
            if (parsed != null) {
                capabilities = parsed;
                currentRecording.capabilities = parsed;
                if (parsed.supportsExtendedPacket()) activeKind = ScaleKind.WEIGH_MY_BRU_PLUS;
                status = "Read WMB+ capabilities";
            } else {
                status = "Rejected WMB+ capabilities";
            }
            refreshLiveMetricsIfNeeded(monotonic);
            notifyRecordingProgressChanged();
            return;
        }

        if (ScaleParsers.uuidMatches(uuid, ScaleParsers.BATTERY_LEVEL_UUID)) {
            if (value.length > 0) receiveBattery(value[0] & 0xFF);
            recordRaw(value, uuid, PacketRole.BATTERY, null, arrival, monotonic);
            refreshLiveMetricsIfNeeded(monotonic);
            notifyRecordingProgressChanged();
            return;
        }

        ParserResult result;
        if (ScaleParsers.uuidMatches(uuid, ScaleParsers.BOOKOO_NOTIFY_UUID)) {
            result = ScaleParsers.parseBookoo(value, activeKind, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_WEIGHT20_UUID)) {
            result = ScaleParsers.parseWmb20(value, capabilities, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_FLOAT32_UUID)) {
            result = ScaleParsers.parseWmbFloat32(value, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.ACAIA_MODERN_CHAR_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.ACAIA_FULL_MODERN_CHAR_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.ACAIA_LEGACY_NOTIFY_UUID)) {
            for (ParserResult event : acaiaCodec.receive(value, arrival, monotonic)) {
                handleParserResult(event, value, uuid, arrival, monotonic);
            }
            refreshLiveMetricsIfNeeded(monotonic);
            notifyRecordingProgressChanged();
            return;
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.DECENT_NOTIFY_UUID)
                && (activeKind == ScaleKind.DECENT || activeKind == ScaleKind.ESPRESSI)) {
            result = ScaleParsers.parseDecentEspressi(value, activeKind, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.DIFLUID_CHAR_UUID)
                && (activeKind == ScaleKind.DIFLUID || activeKind == ScaleKind.DIFLUID_TI)) {
            result = ScaleParsers.parseDiFluid(value, activeKind, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.EUREKA_NOTIFY_UUID)
                && activeKind == ScaleKind.EUREKA) {
            result = ScaleParsers.parseEureka(value, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.FELICITA_CHAR_UUID)) {
            result = ScaleParsers.parseFelicita(value, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.FUTULA_NOTIFY_UUID)
                && activeKind == ScaleKind.FUTULA) {
            result = ScaleParsers.parseFutula(value, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.SKALE2_NOTIFY_UUID)) {
            result = ScaleParsers.parseSkale2(value, arrival, monotonic);
        } else if (ScaleParsers.uuidMatches(uuid, ScaleParsers.TIMEMORE_NOTIFY_UUID)
                && activeKind == ScaleKind.TIMEMORE_DOT) {
            for (ParserResult event : timemoreDotCodec.receive(value, arrival, monotonic)) {
                handleParserResult(event, value, uuid, arrival, monotonic);
            }
            refreshLiveMetricsIfNeeded(monotonic);
            notifyRecordingProgressChanged();
            return;
        } else {
            recordRaw(value, uuid, PacketRole.UNKNOWN, ParseRejectionReason.UNSUPPORTED_CHARACTERISTIC, arrival, monotonic);
            refreshLiveMetricsIfNeeded(monotonic);
            notifyRecordingProgressChanged();
            return;
        }

        handleParserResult(result, value, uuid, arrival, monotonic);
        refreshLiveMetricsIfNeeded(monotonic);
        notifyRecordingProgressChanged();
    }

    private void handleParserResult(ParserResult result, byte[] value, String uuid, long arrival, double monotonic) {
        if (result.isSample()) {
            if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_WEIGHT20_UUID)) {
                hasSeenWmbPlusWeightTransport = true;
            }
            if (isCompatibilityTransport(result.sample, uuid)) {
                recordRaw(value, uuid, PacketRole.UNKNOWN, null, arrival, monotonic);
                return;
            }
            recordRaw(value, uuid, PacketRole.WEIGHT, null, result.sample, arrival, monotonic);
            receiveSample(result.sample);
        } else if (result.isBattery()) {
            recordRaw(value, uuid, PacketRole.BATTERY, null, arrival, monotonic);
            receiveBattery(result.batteryPercent);
        } else {
            PacketRole role = result.rejectionReason == ParseRejectionReason.UNSUPPORTED_FRAME
                    ? PacketRole.UNKNOWN : PacketRole.WEIGHT;
            recordRaw(value, uuid, role, result.rejectionReason, null, arrival, monotonic);
        }
    }

    private boolean isCompatibilityTransport(ScaleSample sample, String uuid) {
        if (sample == null
                || sample.scaleKind != ScaleKind.WEIGH_MY_BRU
                || !ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_FLOAT32_UUID)) {
            return false;
        }
        if (activeKind == ScaleKind.WEIGH_MY_BRU_PLUS
                || (capabilities != null && capabilities.supportsExtendedPacket())) {
            return true;
        }
        return hasSeenWmbPlusWeightTransport;
    }

    private void receiveSample(ScaleSample sample) {
        latestSample = sample;
        if (sample.batteryPercent != null) latestBatteryPercent = sample.batteryPercent;
        if (!(activeKind == ScaleKind.WEIGH_MY_BRU_PLUS && sample.scaleKind == ScaleKind.WEIGH_MY_BRU)) {
            activeKind = sample.scaleKind;
        }
        if (recording) {
            currentRecording.samples.add(sample);
        }
    }

    private void receiveBattery(int percent) {
        if (percent < 0 || percent > 100) return;
        latestBatteryPercent = percent;
        if (recording) {
            ScaleBatteryEvent event = new ScaleBatteryEvent();
            event.arrivalTimeMillis = System.currentTimeMillis();
            event.monotonicSeconds = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0;
            event.scaleKind = activeKind;
            event.percent = percent;
            currentRecording.batteryEvents.add(event);
        }
    }

    private void refreshLiveMetricsIfNeeded(double monotonicSeconds) {
        if (!recording
                || liveMetricsAnalysisInFlight
                || monotonicSeconds - lastLiveMetricsRefreshSeconds < LIVE_METRICS_REFRESH_INTERVAL_SECONDS) {
            return;
        }
        lastLiveMetricsRefreshSeconds = monotonicSeconds;
        liveMetricsAnalysisInFlight = true;
        ScaleRecording snapshot = liveAnalysisSnapshot(currentRecording);
        long generation = recordingGeneration;
        liveMetricsExecutor.execute(() -> {
            ScaleQualityMetrics metrics = null;
            String errorMessage = null;
            try {
                metrics = ScaleQualityAnalyzer.analyze(snapshot);
            } catch (Exception error) {
                errorMessage = error.getMessage();
            }
            ScaleQualityMetrics completedMetrics = metrics;
            String completedErrorMessage = errorMessage;
            mainHandler.post(() -> {
                liveMetricsAnalysisInFlight = false;
                if (!recording
                        || recordingGeneration != generation
                        || !currentRecording.id.equals(snapshot.id)) {
                    return;
                }
                if (completedMetrics != null) {
                    currentRecording.metrics = completedMetrics;
                    notifyRecordingProgressChanged();
                } else {
                    status = "Live diagnostics skipped: " + (completedErrorMessage == null ? "unknown error" : completedErrorMessage);
                    notifyChanged();
                }
            });
        });
    }

    private static ScaleRecording liveAnalysisSnapshot(ScaleRecording source) {
        ScaleRecording snapshot = ScaleRecording.empty(source.mode);
        snapshot.id = source.id;
        snapshot.device = source.device;
        snapshot.startedAtMillis = source.startedAtMillis;
        snapshot.endedAtMillis = source.endedAtMillis;
        snapshot.recordingStartMonotonicSeconds = source.recordingStartMonotonicSeconds;
        snapshot.recordingEndMonotonicSeconds = source.recordingEndMonotonicSeconds;
        snapshot.rawPackets.addAll(source.rawPackets);
        snapshot.samples.addAll(source.samples);
        snapshot.batteryEvents.addAll(source.batteryEvents);
        snapshot.events.addAll(source.events);
        snapshot.capabilities = source.capabilities;
        snapshot.protocolCapabilities = copyProtocolCapabilities(source.protocolCapabilities);
        snapshot.link = source.link;
        snapshot.scoringProfile = source.scoringProfile;
        return snapshot;
    }

    private static ProtocolScoringCapabilities copyProtocolCapabilities(ProtocolScoringCapabilities source) {
        if (source == null) return null;
        ProtocolScoringCapabilities copy = new ProtocolScoringCapabilities();
        copy.hasChecksum = source.hasChecksum;
        copy.hasSequence = source.hasSequence;
        copy.sequenceModulus = source.sequenceModulus;
        copy.hasDeviceClock = source.hasDeviceClock;
        copy.deviceClockSemantics = source.deviceClockSemantics;
        copy.deviceClockModulus = source.deviceClockModulus;
        return copy;
    }

    private void recordRaw(byte[] value, String uuid, PacketRole role, ParseRejectionReason reason, long arrival, double monotonic) {
        recordRaw(value, uuid, role, reason, null, arrival, monotonic);
    }

    private void recordRaw(
            byte[] value,
            String uuid,
            PacketRole role,
            ParseRejectionReason reason,
            ScaleSample sample,
            long arrival,
            double monotonic
    ) {
        if (!recording) return;
        RawScalePacket packet = new RawScalePacket();
        packet.arrivalTimeMillis = arrival;
        packet.monotonicSeconds = monotonic;
        packet.scaleKind = sample == null ? activeKind : sample.scaleKind;
        packet.characteristicUuid = ScaleParsers.shortUuid(uuid);
        packet.role = role;
        packet.bytesHex = ScaleParsers.hex(value);
        packet.rejectionReason = reason;
        packet.weightGrams = sample == null ? null : sample.weightGrams;
        packet.sequence = sample == null ? null : sample.sequence;
        packet.deviceTimestampMilliseconds = sample == null ? null : sample.deviceTimestampMilliseconds;
        packet.fields.addAll(ScaleParsers.packetFields(packet.scaleKind, packet.characteristicUuid, value));
        currentRecording.rawPackets.add(packet);
        if (sample != null) updateScoringCapabilities(sample, uuid);
    }

    private ProtocolScoringCapabilities baseScoringCapabilities(ScaleKind kind) {
        ProtocolScoringCapabilities result = new ProtocolScoringCapabilities();
        result.hasChecksum = kind == ScaleKind.BOOKOO
                || kind == ScaleKind.BOOKOO_MINI
                || kind == ScaleKind.BOOKOO_ULTRA
                || kind == ScaleKind.WEIGH_MY_BRU_PLUS
                || kind == ScaleKind.ACAIA
                || kind == ScaleKind.DIFLUID
                || kind == ScaleKind.DIFLUID_TI
                || kind == ScaleKind.TIMEMORE_DOT;
        result.hasSequence = false;
        result.sequenceModulus = 256L;
        result.hasDeviceClock = false;
        result.deviceClockSemantics = kind == ScaleKind.DECENT || kind == ScaleKind.ESPRESSI
                ? DeviceClockSemantics.SHOT_TIMER : DeviceClockSemantics.NONE;
        return result;
    }

    private void updateScoringCapabilities(ScaleSample sample, String uuid) {
        ProtocolScoringCapabilities scoring = currentRecording.protocolCapabilities != null
                ? currentRecording.protocolCapabilities : baseScoringCapabilities(sample.scaleKind);
        if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_WEIGHT20_UUID)) scoring.hasChecksum = true;
        scoring.hasSequence |= sample.sequence != null;
        scoring.hasDeviceClock |= sample.deviceTimestampMilliseconds != null;
        if (sample.deviceTimestampMilliseconds != null) {
            if (sample.scaleKind == ScaleKind.DECENT || sample.scaleKind == ScaleKind.ESPRESSI) {
                scoring.deviceClockSemantics = DeviceClockSemantics.SHOT_TIMER;
            } else {
                scoring.deviceClockSemantics = DeviceClockSemantics.FREE_RUNNING;
                if (sample.scaleKind == ScaleKind.BOOKOO
                        || sample.scaleKind == ScaleKind.BOOKOO_MINI
                        || sample.scaleKind == ScaleKind.BOOKOO_ULTRA
                        || sample.scaleKind == ScaleKind.WEIGH_MY_BRU_PLUS) {
                    scoring.deviceClockModulus = 1L << 24;
                } else if (sample.scaleKind == ScaleKind.DIFLUID || sample.scaleKind == ScaleKind.DIFLUID_TI) {
                    scoring.deviceClockModulus = 1L << 32;
                }
            }
        }
        currentRecording.protocolCapabilities = scoring;
    }

    static boolean isWritable(String uuid) {
        return ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_COMMAND_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.BOOKOO_WRITE_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.ACAIA_MODERN_CHAR_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.ACAIA_FULL_MODERN_CHAR_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.ACAIA_LEGACY_WRITE_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.DECENT_WRITE_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.DIFLUID_CHAR_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.EUREKA_WRITE_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.FELICITA_CHAR_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.FUTULA_WRITE_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.SKALE2_WRITE_UUID)
                || ScaleParsers.uuidMatches(uuid, ScaleParsers.TIMEMORE_WRITE_UUID);
    }

    @SuppressLint("MissingPermission")
    private void write(byte[] bytes) {
        if (session == null || !hasBluetoothPermissions()) return;
        session.writeCommand(bytes);
    }

    private void sendInitialConfigurationIfNeeded() {
        if (didSendInitialConfiguration || session == null || !session.hasWritableCommand()) return;
        didSendInitialConfiguration = true;
        switch (activeKind) {
            case ACAIA:
                boolean isPyxis = connectedDevice != null && connectedDevice.name.toUpperCase(Locale.US).startsWith("PYXIS");
                write(ScaleParsers.acaiaIdentifyCommand(isPyxis));
                write(ScaleParsers.ACAIA_NOTIFICATION_REQUEST);
                break;
            case DECENT:
                write(ScaleParsers.DECENT_LEDS_ON);
                break;
            case DIFLUID:
            case DIFLUID_TI:
                write(ScaleParsers.DIFLUID_CONFIG_1);
                mainHandler.postDelayed(() -> write(ScaleParsers.DIFLUID_CONFIG_2), 100);
                mainHandler.postDelayed(() -> write(ScaleParsers.DIFLUID_REQUEST_STATUS), 200);
                break;
            case FUTULA:
                write(ScaleParsers.FUTULA_SET_GRAMS);
                break;
            case SKALE2:
                for (byte[] command : ScaleParsers.SKALE2_INITIAL_COMMANDS) write(command);
                break;
            case TIMEMORE_DOT:
                write(ScaleParsers.TIMEMORE_SET_GRAMS);
                mainHandler.postDelayed(() -> write(ScaleParsers.TIMEMORE_SET_STANDARD_MODE), 200);
                break;
            default:
                break;
        }
    }

    private boolean hasBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= 31) {
            return context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
                    && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        }
        return context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private void notifyRecordingProgressChanged() {
        if (liveUiRefreshPending) return;
        liveUiRefreshPending = true;
        mainHandler.postDelayed(liveUiRefreshRunnable, LIVE_UI_REFRESH_INTERVAL_MILLIS);
    }

    private void notifyChanged() {
        if (liveUiRefreshPending) {
            mainHandler.removeCallbacks(liveUiRefreshRunnable);
            liveUiRefreshPending = false;
        }
        listener.onStateChanged();
    }
}
