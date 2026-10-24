package app.scalebench.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.delay
import org.json.JSONObject
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper

class MainActivity : ComponentActivity() {
    private val appState: ScaleBenchViewModel by viewModels()
    private val bluetooth: BluetoothScaleManager get() = appState.bluetooth
    private val savedRecordingStore: SavedRecordingStore get() = appState.savedRecordingStore
    private val fileWorkExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ScaleBench-FileWork").apply { isDaemon = true }
    }
    private lateinit var createJsonDocument: ActivityResultLauncher<String>
    private lateinit var importJsonDocument: ActivityResultLauncher<Array<String>>
    private lateinit var openFirmwareDocument: ActivityResultLauncher<Array<String>>
    private var pendingJsonExport: PendingJsonExport?
        get() = appState.pendingJsonExport
        set(value) {
            appState.pendingJsonExport = value
        }
    private var deviceUtilityState: DeviceUtilityState
        get() = appState.deviceUtilityState
        set(value) {
            appState.updateDeviceUtilityState(value)
        }

    private val dfuProgressListener = object : DfuProgressListenerAdapter() {
        override fun onDeviceConnecting(deviceAddress: String) {
            updateDeviceUtilityStatus("Connecting to DFU target", progress = null)
        }

        override fun onDfuProcessStarting(deviceAddress: String) {
            updateDeviceUtilityStatus("Starting firmware update", progress = 0)
        }

        override fun onEnablingDfuMode(deviceAddress: String) {
            updateDeviceUtilityStatus("Switching device into DFU mode", progress = null)
        }

        override fun onProgressChanged(
            deviceAddress: String,
            percent: Int,
            speed: Float,
            avgSpeed: Float,
            currentPart: Int,
            partsTotal: Int
        ) {
            updateDeviceUtilityStatus("Updating firmware ($currentPart/$partsTotal)", progress = percent)
        }

        override fun onDfuCompleted(deviceAddress: String) {
            updateDeviceUtilityStatus("Firmware update completed", progress = 100)
        }

        override fun onDfuAborted(deviceAddress: String) {
            updateDeviceUtilityStatus("Firmware update aborted", progress = null)
        }

        override fun onError(deviceAddress: String, error: Int, errorType: Int, message: String?) {
            updateDeviceUtilityStatus("Firmware update failed: ${message ?: error}", progress = null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        createJsonDocument = registerForActivityResult(
            ActivityResultContracts.CreateDocument("application/json")
        ) { uri ->
            if (uri == null) {
                pendingJsonExport = null
            } else {
                writePendingJsonExport(uri)
            }
        }
        importJsonDocument = registerForActivityResult(
            ActivityResultContracts.OpenDocument()
        ) { uri ->
            if (uri != null) {
                importRecording(uri)
            }
        }
        openFirmwareDocument = registerForActivityResult(
            ActivityResultContracts.OpenDocument()
        ) { uri ->
            if (uri != null) {
                try {
                    contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: SecurityException) {
                    // The temporary grant is still usable for this session.
                }
                deviceUtilityState = deviceUtilityState.copy(
                    selectedFirmwareUri = uri,
                    selectedFirmwareName = displayName(uri),
                    status = "Firmware package selected",
                    progress = null,
                    log = deviceUtilityState.log + "Selected ${displayName(uri)}"
                )
            }
        }
        DfuServiceListenerHelper.registerProgressListener(this, dfuProgressListener)
        setContent {
            ScaleBenchTheme {
                val renderTick = appState.renderTick
                val keepScreenAwake = bluetooth.isRecording() || appState.usbSerial.isRecording
                DisposableEffect(keepScreenAwake) {
                    if (keepScreenAwake) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    onDispose {
                        if (keepScreenAwake) {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                }
                ScaleBenchApp(
                    bluetooth = bluetooth,
                    usbSerial = appState.usbSerial,
                    savedRecordingStore = savedRecordingStore,
                    renderTick = renderTick,
                    onSave = ::saveRecording,
                    onLoadExamples = ::loadExampleRecordings,
                    onImportRecording = ::chooseRecordingImport,
                    onDeleteSaved = { deleteSavedRecording(it) },
                    onExport = ::exportRecording,
                    onExportRecording = ::exportRecording,
                    onExportSaved = ::exportSavedRecording,
                    onShareScorecard = ::shareCurrentScorecard,
                    onShareRecordingScorecard = ::shareScorecard,
                    onShareSavedScorecard = ::shareSavedScorecard,
                    deviceUtilityState = appState.deviceUtilityState,
                    onChooseFirmware = ::chooseFirmwarePackage,
                    onStartClassicDfu = ::startClassicDfu,
                    onRefreshCabledEsp = ::refreshCabledEspDevices,
                    onSelectCabledEsp = ::selectCabledUsbDevice,
                    onBackupCabledEsp = ::startEsp32CableBackup,
                    onFlashCabledEsp = ::startEsp32CableFlash,
                    onExportDeviceReport = ::exportDeviceUtilityReport
                )
            }
        }
    }

    override fun onDestroy() {
        DfuServiceListenerHelper.unregisterProgressListener(this, dfuProgressListener)
        fileWorkExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        bluetooth.noteAppBecameForeground()
    }

    override fun onStop() {
        if (!isChangingConfigurations) {
            bluetooth.noteAppEnteredBackground()
        }
        super.onStop()
    }

    private fun exportRecording(notes: String) {
        try {
            val recording = finalizeCurrentRecording(notes)
            exportRecording(recording)
        } catch (error: Exception) {
            Toast.makeText(this, "Could not prepare JSON: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun exportRecording(recording: ScaleRecording) {
        val fileName = jsonFileName(recording.defaultTitle(), System.currentTimeMillis())
        pendingJsonExport = PendingJsonExport.Current(recording, fileName)
        createJsonDocument.launch(fileName)
        appState.invalidate()
    }

    private fun exportSavedRecording(summary: SavedRecordingSummary) {
        val fileName = jsonFileName(summary.title, summary.savedAtMillis)
        pendingJsonExport = PendingJsonExport.Saved(summary, fileName)
        createJsonDocument.launch(fileName)
    }

    private fun shareCurrentScorecard(notes: String) {
        try {
            val recording = finalizeCurrentRecording(notes)
            shareScorecard(recording)
        } catch (error: Exception) {
            Toast.makeText(this, "Share failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun shareSavedScorecard(summary: SavedRecordingSummary) {
        fileWorkExecutor.execute {
            try {
                shareScorecardPrepared(savedRecordingStore.recordingForAnalysis(summary))
            } catch (error: Exception) {
                runOnUiThread {
                    Toast.makeText(this, "Share failed: ${error.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun shareScorecard(recording: ScaleRecording) {
        fileWorkExecutor.execute {
            try {
                shareScorecardPrepared(recording)
            } catch (error: Exception) {
                runOnUiThread {
                    Toast.makeText(this, "Share failed: ${error.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun shareScorecardPrepared(recording: ScaleRecording) {
        val file = AndroidScorecardShare.writeScorecard(this, recording)
        val uri = FileProvider.getUriForFile(this, "${BuildConfig.APPLICATION_ID}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TEXT, "${recording.defaultTitle()} · ${standardScoreDisplay(recording.mode, recording.metrics)}")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runOnUiThread {
            startActivity(Intent.createChooser(intent, "Share ScaleBench scorecard"))
        }
    }

    private fun writePendingJsonExport(uri: Uri) {
        val export = pendingJsonExport ?: return
        pendingJsonExport = null
        fileWorkExecutor.execute {
            try {
                val output = contentResolver.openOutputStream(uri, "w")
                    ?: throw IllegalStateException("The selected location could not be opened")
                output.use {
                    when (export) {
                        is PendingJsonExport.Current -> JsonExporter.writeRecording(export.recording, it)
                        is PendingJsonExport.Saved -> savedRecordingStore.writeRecording(export.summary, it)
                        is PendingJsonExport.UtilityReport -> it.write(export.json.toByteArray(Charsets.UTF_8))
                    }
                }
                runOnUiThread {
                    Toast.makeText(this, "Saved ${export.fileName}", Toast.LENGTH_LONG).show()
                }
            } catch (error: Exception) {
                runOnUiThread {
                    Toast.makeText(this, "Save failed: ${error.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun saveRecording(notes: String): RecordingSaveResult {
        return try {
            val recording = finalizeCurrentRecording(notes)
            if (recording.samples.isEmpty() && recording.rawPackets.isEmpty()) {
                RecordingSaveResult(
                    saved = false,
                    retryable = false,
                    message = "No saved shot was created because no packets were captured."
                )
            } else {
                val saved = savedRecordingStore.save(recording, notes, null, false)
                Toast.makeText(this, "Saved ${saved.title}", Toast.LENGTH_SHORT).show()
                appState.invalidate()
                RecordingSaveResult(
                    saved = true,
                    retryable = false,
                    message = "Saved automatically. Detailed charts and packet analysis are ready in Saved shots."
                )
            }
        } catch (error: Exception) {
            val detail = error.message ?: "The recording file could not be written."
            Toast.makeText(this, "Save failed: $detail", Toast.LENGTH_LONG).show()
            RecordingSaveResult(
                saved = false,
                retryable = true,
                message = "Automatic save failed: $detail"
            )
        }
    }

    private fun loadExampleRecordings() {
        try {
            val loaded = savedRecordingStore.loadExampleRecordings()
            val message = if (loaded == 0) {
                "Example recordings already loaded"
            } else {
                "Loaded $loaded example recording${if (loaded == 1) "" else "s"}"
            }
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
            appState.invalidate()
        } catch (error: Exception) {
            Toast.makeText(this, "Examples failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun chooseRecordingImport() {
        importJsonDocument.launch(arrayOf("application/json", "text/json", "*/*"))
    }

    private fun importRecording(uri: Uri) {
        val fallbackTitle = displayName(uri)
        fileWorkExecutor.execute {
            try {
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("The selected file could not be opened")
                val json = input.bufferedReader(Charsets.UTF_8).use { it.readText() }
                val saved = savedRecordingStore.importRecording(json, fallbackTitle)
                runOnUiThread {
                    Toast.makeText(this, "Imported ${saved.title}", Toast.LENGTH_LONG).show()
                    appState.invalidate()
                }
            } catch (error: Exception) {
                runOnUiThread {
                    Toast.makeText(this, "Import failed: ${error.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun deleteSavedRecording(summary: SavedRecordingSummary) {
        try {
            savedRecordingStore.delete(summary)
            Toast.makeText(this, "Deleted ${summary.title}", Toast.LENGTH_SHORT).show()
            appState.invalidate()
        } catch (error: Exception) {
            Toast.makeText(this, "Delete failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun finalizeCurrentRecording(notes: String): ScaleRecording {
        if (bluetooth.isRecording) {
            bluetooth.stopRecording()
        }
        val recording = bluetooth.currentRecording()
        recording.endedAtMillis = recording.endedAtMillis ?: System.currentTimeMillis()
        recording.notes = notes
        return recording
    }

    private fun jsonFileName(title: String, timestampMillis: Long): String {
        val safeTitle = title
            .replace(Regex("[^A-Za-z0-9._-]+"), "-")
            .trim('-')
            .take(72)
            .ifBlank { "ScaleBench" }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(timestampMillis))
        return "$safeTitle-$stamp.json"
    }

    private fun chooseFirmwarePackage() {
        openFirmwareDocument.launch(arrayOf("application/zip", "application/octet-stream", "*/*"))
    }

    private fun refreshCabledEspDevices() {
        val manager = getSystemService(USB_SERVICE) as UsbManager
        val devices = manager.deviceList.values
            .map { it.toCabledUsbDevice(manager.hasPermission(it)) }
            .sortedWith(compareBy<CabledUsbDevice> { it.vendorId }.thenBy { it.productId }.thenBy { it.deviceName })
        deviceUtilityState = deviceUtilityState.copy(
            cabledUsbDevices = devices,
            selectedUsbDeviceName = deviceUtilityState.selectedUsbDeviceName?.takeIf { selected ->
                devices.any { it.deviceName == selected }
            } ?: devices.firstOrNull()?.deviceName,
            log = (deviceUtilityState.log + "Found ${devices.size} USB device(s)").takeLast(8)
        )
    }

    private fun selectCabledUsbDevice(deviceName: String) {
        deviceUtilityState = deviceUtilityState.copy(selectedUsbDeviceName = deviceName)
    }

    private fun startEsp32CableBackup() {
        updateDeviceUtilityStatus(
            "Android ESP32 cable backup needs native esp-serial-flasher bridge; USB detection is ready.",
            progress = null
        )
        Toast.makeText(this, "Android ESP32 cable backend is not wired yet", Toast.LENGTH_LONG).show()
    }

    private fun startEsp32CableFlash() {
        updateDeviceUtilityStatus(
            "Android ESP32 cable flash needs native esp-serial-flasher bridge; backup-before-flash remains enforced.",
            progress = null
        )
        Toast.makeText(this, "Android ESP32 cable backend is not wired yet", Toast.LENGTH_LONG).show()
    }

    private fun startClassicDfu() {
        val device = bluetooth.connectedDevice()?.takeIf { bluetooth.isConnected }
        val firmwareUri = deviceUtilityState.selectedFirmwareUri
        if (device == null) {
            Toast.makeText(this, "Connect a device first", Toast.LENGTH_LONG).show()
            return
        }
        if (firmwareUri == null) {
            Toast.makeText(this, "Choose a firmware ZIP first", Toast.LENGTH_LONG).show()
            return
        }
        try {
            bluetooth.disconnect()
            val starter = DfuServiceInitiator(device.address)
                .setDeviceName(device.name)
                .setKeepBond(false)
                .setForceDfu(false)
                .setNumberOfRetries(1)
                .setZip(firmwareUri)
            updateDeviceUtilityStatus("Starting Nordic DFU service", progress = null)
            starter.start(this, DfuUpdateService::class.java)
        } catch (error: Exception) {
            updateDeviceUtilityStatus("Could not start DFU: ${error.message}", progress = null)
            Toast.makeText(this, "DFU start failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun exportDeviceUtilityReport() {
        val report = deviceUtilityReportJson()
        val deviceName = bluetooth.connectedDevice()?.name?.takeIf { bluetooth.isConnected } ?: "device"
        val fileName = jsonFileName("ScaleBench-DU-$deviceName", System.currentTimeMillis())
        pendingJsonExport = PendingJsonExport.UtilityReport(report, fileName)
        createJsonDocument.launch(fileName)
    }

    private fun deviceUtilityReportJson(): String {
        val device = bluetooth.connectedDevice()?.takeIf { bluetooth.isConnected }
        val objectJson = JSONObject()
        objectJson.put("schemaVersion", 1)
        objectJson.put("kind", "ScaleBenchDeviceUtilityReport")
        objectJson.put("createdAtMillis", System.currentTimeMillis())
        objectJson.put("appName", "ScaleBench Android")
        objectJson.put("appVersion", BuildConfig.VERSION_NAME)
        objectJson.put("appBuild", BuildConfig.VERSION_CODE)
        objectJson.put("platform", "android")
        val deviceJson = JSONObject()
        if (device != null) {
            deviceJson.put("name", device.name)
            deviceJson.put("identifier", device.address)
            deviceJson.put("protocol", device.kind.displayName)
            deviceJson.put("rssi", device.rssi)
            deviceJson.put("advertisedServices", org.json.JSONArray(device.advertisedServices))
        }
        objectJson.put("device", deviceJson)
        val telemetry = JSONObject()
        bluetooth.latestSample()?.let { sample ->
            telemetry.put("weightGrams", sample.weightGrams)
            sample.flowGramsPerSecond?.let { telemetry.put("flowGramsPerSecond", it) }
            sample.batteryPercent?.let { telemetry.put("batteryPercent", it) }
        }
        bluetooth.latestBatteryPercent()?.let { telemetry.put("latestBatteryPercent", it) }
        objectJson.put("latestTelemetry", telemetry)
        objectJson.put("utility", JSONObject()
            .put("dfuCapability", deviceUtilityCapabilityLabel(device?.advertisedServices ?: emptyList()))
            .put("selectedFirmwareName", deviceUtilityState.selectedFirmwareName ?: JSONObject.NULL)
            .put("firmwareBackupSupported", false)
            .put("backupNote", "Full firmware image backup requires firmware or bootloader readback support.")
            .put("cabledEsp32", JSONObject()
                .put("backend", "usb-host-detection")
                .put("nativeBackupFlashEnabled", false)
                .put("selectedUsbDeviceName", deviceUtilityState.selectedUsbDeviceName ?: JSONObject.NULL)
                .put("usbDevices", org.json.JSONArray(deviceUtilityState.cabledUsbDevices.map { it.toJson() }))
                .put("note", "Android USB detection is wired. Backup/flash needs a native esp-serial-flasher bridge.")
            )
        )
        return objectJson.toString(2)
    }

    private fun updateDeviceUtilityStatus(message: String, progress: Int?) {
        runOnUiThread {
            deviceUtilityState = deviceUtilityState.copy(
                status = message,
                progress = progress,
                log = (deviceUtilityState.log + message).takeLast(8)
            )
        }
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, null, null, null, null)
            val nameIndex = cursor?.getColumnIndex(OpenableColumns.DISPLAY_NAME) ?: -1
            if (cursor != null && cursor.moveToFirst() && nameIndex >= 0) {
                cursor.getString(nameIndex)
            } else {
                uri.lastPathSegment ?: "firmware.zip"
            }
        } finally {
            cursor?.close()
        }
    }

}

data class DeviceUtilityState(
    val selectedFirmwareUri: Uri? = null,
    val selectedFirmwareName: String? = null,
    val cabledUsbDevices: List<CabledUsbDevice> = emptyList(),
    val selectedUsbDeviceName: String? = null,
    val status: String = "Idle",
    val progress: Int? = null,
    val log: List<String> = emptyList()
)

data class CabledUsbDevice(
    val deviceName: String,
    val manufacturerName: String?,
    val productName: String?,
    val vendorId: Int,
    val productId: Int,
    val hasPermission: Boolean
) {
    val displayName: String
        get() = listOfNotNull(productName, manufacturerName).firstOrNull() ?: deviceName

    fun toJson(): JSONObject = JSONObject()
        .put("deviceName", deviceName)
        .put("displayName", displayName)
        .put("manufacturerName", manufacturerName ?: JSONObject.NULL)
        .put("productName", productName ?: JSONObject.NULL)
        .put("vendorId", vendorId)
        .put("productId", productId)
        .put("hasPermission", hasPermission)
}

fun UsbDevice.toCabledUsbDevice(hasPermission: Boolean): CabledUsbDevice = CabledUsbDevice(
    deviceName = deviceName,
    manufacturerName = try {
        manufacturerName
    } catch (_: SecurityException) {
        null
    },
    productName = try {
        productName
    } catch (_: SecurityException) {
        null
    },
    vendorId = vendorId,
    productId = productId,
    hasPermission = hasPermission
)

fun bluetoothPermissions(): Array<String> {
    return if (Build.VERSION.SDK_INT >= 31) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }
}

fun hasBluetoothPermissions(context: Context): Boolean {
    return bluetoothPermissions().all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
}
