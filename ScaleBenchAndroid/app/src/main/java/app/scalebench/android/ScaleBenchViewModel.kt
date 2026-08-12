package app.scalebench.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel

internal class ScaleBenchViewModel(application: Application) : AndroidViewModel(application) {
    private val mainHandler = Handler(Looper.getMainLooper())

    val savedRecordingStore = SavedRecordingStore(application)
    val bluetooth = BluetoothScaleManager(application) { invalidate() }

    var renderTick by mutableIntStateOf(0)
        private set

    var deviceUtilityState by mutableStateOf(DeviceUtilityState())
        private set

    var pendingJsonExport: PendingJsonExport? = null

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

    override fun onCleared() {
        bluetooth.shutdown()
        mainHandler.removeCallbacksAndMessages(null)
        super.onCleared()
    }
}

internal sealed class PendingJsonExport(open val fileName: String) {
    data class Current(val recording: ScaleRecording, override val fileName: String) : PendingJsonExport(fileName)
    data class Saved(val summary: SavedRecordingSummary, override val fileName: String) : PendingJsonExport(fileName)
    data class UtilityReport(val json: String, override val fileName: String) : PendingJsonExport(fileName)
}
