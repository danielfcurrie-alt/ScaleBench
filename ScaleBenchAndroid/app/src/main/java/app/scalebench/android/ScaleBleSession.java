package app.scalebench.android;

import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattService;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.util.ArrayList;
import java.util.List;

import no.nordicsemi.android.ble.BleManager;
import no.nordicsemi.android.ble.callback.FailCallback;

final class ScaleBleSession extends BleManager {
    interface Listener {
        void onReady();
        void onDisconnected();
        void onUnsupportedDevice();
        void onValue(String uuid, byte[] value, long arrivalMillis, double monotonicSeconds);
    }

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Listener listener;
    private final List<BluetoothGattCharacteristic> notifyingCharacteristics = new ArrayList<>();
    private final List<BluetoothGattCharacteristic> indicatingCharacteristics = new ArrayList<>();
    private final List<BluetoothGattCharacteristic> readOnReadyCharacteristics = new ArrayList<>();
    private BluetoothGattCharacteristic writeCharacteristic;

    ScaleBleSession(Context context, Listener listener) {
        super(context);
        this.listener = listener;
    }

    void connectDevice(BluetoothDevice device) {
        connect(device)
                .retry(3, 100)
                .timeout(15_000)
                .fail((failedDevice, reason) -> post(reason == FailCallback.REASON_DEVICE_NOT_SUPPORTED
                        ? listener::onUnsupportedDevice
                        : listener::onDisconnected))
                .enqueue();
    }

    boolean hasWritableCommand() {
        return writeCharacteristic != null;
    }

    void writeCommand(byte[] bytes) {
        if (writeCharacteristic == null || bytes == null) return;
        writeCharacteristic(writeCharacteristic, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                .timeout(5_000)
                .enqueue();
    }

    @Override
    protected boolean isRequiredServiceSupported(BluetoothGatt gatt) {
        notifyingCharacteristics.clear();
        indicatingCharacteristics.clear();
        readOnReadyCharacteristics.clear();
        writeCharacteristic = null;

        for (BluetoothGattService service : gatt.getServices()) {
            for (BluetoothGattCharacteristic characteristic : service.getCharacteristics()) {
                String uuid = characteristic.getUuid().toString();
                if (BluetoothScaleManager.isWritable(uuid)) writeCharacteristic = characteristic;
                if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_CAPABILITIES_UUID)
                        || ScaleParsers.uuidMatches(uuid, ScaleParsers.BATTERY_LEVEL_UUID)) {
                    readOnReadyCharacteristics.add(characteristic);
                }

                int props = characteristic.getProperties();
                if ((props & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) {
                    notifyingCharacteristics.add(characteristic);
                } else if ((props & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) {
                    indicatingCharacteristics.add(characteristic);
                }
            }
        }

        return writeCharacteristic != null
                || !notifyingCharacteristics.isEmpty()
                || !indicatingCharacteristics.isEmpty()
                || !readOnReadyCharacteristics.isEmpty();
    }

    @Override
    protected void initialize() {
        requestMtu(247).enqueue();

        for (BluetoothGattCharacteristic characteristic : readOnReadyCharacteristics) {
            readCharacteristic(characteristic)
                    .with((device, data) -> dispatchValue(characteristic, data.getValue()))
                    .enqueue();
        }
        for (BluetoothGattCharacteristic characteristic : notifyingCharacteristics) {
            setNotificationCallback(characteristic)
                    .with((device, data) -> dispatchValue(characteristic, data.getValue()));
            enableNotifications(characteristic).enqueue();
        }
        for (BluetoothGattCharacteristic characteristic : indicatingCharacteristics) {
            setIndicationCallback(characteristic)
                    .with((device, data) -> dispatchValue(characteristic, data.getValue()));
            enableIndications(characteristic).enqueue();
        }
    }

    @Override
    protected void onDeviceReady() {
        post(listener::onReady);
    }

    @Override
    protected void onServicesInvalidated() {
        notifyingCharacteristics.clear();
        indicatingCharacteristics.clear();
        readOnReadyCharacteristics.clear();
        writeCharacteristic = null;
        post(listener::onDisconnected);
    }

    private void dispatchValue(BluetoothGattCharacteristic characteristic, byte[] value) {
        if (value == null) return;
        long arrival = System.currentTimeMillis();
        double monotonic = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0;
        post(() -> listener.onValue(characteristic.getUuid().toString(), value, arrival, monotonic));
    }

    private void post(Runnable runnable) {
        mainHandler.post(runnable);
    }
}
