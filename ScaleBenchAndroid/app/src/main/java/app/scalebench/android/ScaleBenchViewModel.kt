package app.scalebench.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import java.util.concurrent.Executors

internal class ScaleBenchViewModel(application: Application) : AndroidViewModel(application) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val libraryRecoveryExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ScaleBench-LibraryRecovery").apply { isDaemon = true }
    }

    var renderTick by mutableIntStateOf(0)
        private set

    val savedRecordingStore = SavedRecordingStore(application)
    val bluetooth = BluetoothScaleManager(application) { invalidate() }
    val usbSerial = AndroidUSBSerialManager(application) { invalidate() }

    var deviceUtilityState by mutableStateOf(DeviceUtilityState())
        private set

    var fileWorkMessage by mutableStateOf<String?>(null)
        private set

    var pendingJsonExport: PendingJsonExport? = null

    init {
        libraryRecoveryExecutor.execute {
            val recoveredCount = savedRecordingStore.recoverMissingSummaries()
            if (recoveredCount > 0 || savedRecordingStore.lastErrorMessage() != null) {
                invalidate()
            }
        }
    }

    fun invalidate() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            renderTick++
        } else {
            mainHandler.post { renderTick++ }
        }
    }

    fun updateDeviceUtilityState(state: DeviceUtilityState) {
        deviceUtilityState = state
        invalidate()
    }

    fun updateFileWorkMessage(message: String?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            fileWorkMessage = message
            renderTick++
        } else {
            mainHandler.post {
                fileWorkMessage = message
                renderTick++
            }
        }
    }

    override fun onCleared() {
        libraryRecoveryExecutor.shutdownNow()
        bluetooth.shutdown()
        usbSerial.shutdown()
        mainHandler.removeCallbacksAndMessages(null)
        super.onCleared()
    }
}

internal sealed class PendingJsonExport(open val fileName: String) {
    data class Current(val recording: ScaleRecording, override val fileName: String) : PendingJsonExport(fileName)
    data class Saved(val summary: SavedRecordingSummary, override val fileName: String) : PendingJsonExport(fileName)
    data class UtilityReport(val json: String, override val fileName: String) : PendingJsonExport(fileName)
}
