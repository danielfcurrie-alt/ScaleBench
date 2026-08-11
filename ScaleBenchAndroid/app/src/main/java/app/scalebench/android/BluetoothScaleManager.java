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

import no.nordicsemi.android.support.v18.scanner.BluetoothLeScannerCompat;
import no.nordicsemi.android.support.v18.scanner.ScanCallback;
import no.nordicsemi.android.support.v18.scanner.ScanResult;
import no.nordicsemi.android.support.v18.scanner.ScanSettings;

final class BluetoothScaleManager {
    interface Listener {
        void onStateChanged();
    }

    private final Context context;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
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
    private boolean recording;
    private boolean didSendInitialConfiguration;
    private String status = "Idle";
    private ScaleRecording currentRecording = ScaleRecording.empty(RecordingMode.IDLE_STABILITY);

    BluetoothScaleManager(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        BluetoothManager bluetoothManager = (BluetoothManager) this.context.getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = bluetoothManager == null ? null : bluetoothManager.getAdapter();
    }

    List<DiscoveredScale> discoveredScales() {
        return new ArrayList<>(discovered.values());
    }

    DiscoveredScale connectedDevice() {
        return connectedDevice;
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

    boolean isScanning() {
        return scanning;
    }

    boolean isRecording() {
        return recording;
    }

    String status() {
        return status;
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
        connectedDevice = scale;
        activeKind = scale.kind;
        capabilities = null;
        acaiaCodec = new AcaiaCodec();
        timemoreDotCodec = new TimemoreDotCodec();
        didSendInitialConfiguration = false;
        latestSample = null;
        latestBatteryPercent = null;
        BluetoothDevice device = adapter.getRemoteDevice(scale.address);
        status = "Connecting to " + scale.name;
        session = new ScaleBleSession(context, new ScaleBleSession.Listener() {
            @Override
            public void onReady() {
                status = "Ready";
                sendInitialConfigurationIfNeeded();
                notifyChanged();
            }

            @Override
            public void onDisconnected() {
                status = "Disconnected";
                notifyChanged();
            }

            @Override
            public void onUnsupportedDevice() {
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
        recording = true;
        currentRecording = ScaleRecording.empty(mode);
        currentRecording.capabilities = capabilities;
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
        status = "Recording " + mode.displayName;
        notifyChanged();
    }

    void stopRecording() {
        recording = false;
        currentRecording.endedAtMillis = System.currentTimeMillis();
        currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording);
        status = "Recording stopped";
        notifyChanged();
    }

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
            notifyChanged();
            return;
        }

        if (ScaleParsers.uuidMatches(uuid, ScaleParsers.BATTERY_LEVEL_UUID)) {
            if (value.length > 0) receiveBattery(value[0] & 0xFF);
            recordRaw(value, uuid, PacketRole.BATTERY, null, arrival, monotonic);
            notifyChanged();
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
            notifyChanged();
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
            notifyChanged();
            return;
        } else {
            recordRaw(value, uuid, PacketRole.UNKNOWN, ParseRejectionReason.UNSUPPORTED_CHARACTERISTIC, arrival, monotonic);
            notifyChanged();
            return;
        }

        handleParserResult(result, value, uuid, arrival, monotonic);
        notifyChanged();
    }

    private void handleParserResult(ParserResult result, byte[] value, String uuid, long arrival, double monotonic) {
        if (result.isSample()) {
            recordRaw(value, uuid, PacketRole.WEIGHT, null, arrival, monotonic);
            receiveSample(result.sample);
        } else if (result.isBattery()) {
            recordRaw(value, uuid, PacketRole.BATTERY, null, arrival, monotonic);
            receiveBattery(result.batteryPercent);
        } else {
            recordRaw(value, uuid, PacketRole.WEIGHT, result.rejectionReason, arrival, monotonic);
        }
    }

    private void receiveSample(ScaleSample sample) {
        latestSample = sample;
        if (sample.batteryPercent != null) latestBatteryPercent = sample.batteryPercent;
        if (!(activeKind == ScaleKind.WEIGH_MY_BRU_PLUS && sample.scaleKind == ScaleKind.WEIGH_MY_BRU)) {
            activeKind = sample.scaleKind;
        }
        if (recording) {
            currentRecording.samples.add(sample);
            currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording);
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
            currentRecording.metrics = ScaleQualityAnalyzer.analyze(currentRecording);
        }
    }

    private void recordRaw(byte[] value, String uuid, PacketRole role, ParseRejectionReason reason, long arrival, double monotonic) {
        if (!recording) return;
        RawScalePacket packet = new RawScalePacket();
        packet.arrivalTimeMillis = arrival;
        packet.monotonicSeconds = monotonic;
        packet.scaleKind = activeKind;
        packet.characteristicUuid = ScaleParsers.shortUuid(uuid);
        packet.role = role;
        packet.bytesHex = ScaleParsers.hex(value);
        packet.rejectionReason = reason;
        currentRecording.rawPackets.add(packet);
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

    private void notifyChanged() {
        listener.onStateChanged();
    }
}
