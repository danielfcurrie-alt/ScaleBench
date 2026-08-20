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
import android.os.SystemClock
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
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
import androidx.compose.ui.window.DialogProperties
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper

@Composable
internal fun ScaleBenchTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (dark) {
        darkColorScheme(
            primary = Color(0xFF7FDBD6),
            onPrimary = Color(0xFF003735),
            primaryContainer = Color(0xFF164F4E),
            onPrimaryContainer = Color(0xFFB1F1ED),
            secondary = Color(0xFFE4C16D),
            onSecondary = Color(0xFF3D2F00),
            secondaryContainer = Color(0xFF54450F),
            onSecondaryContainer = Color(0xFFFFE291),
            tertiary = Color(0xFFC9C3FF),
            onTertiary = Color(0xFF302B60),
            tertiaryContainer = Color(0xFF484273),
            onTertiaryContainer = Color(0xFFE4DFFF),
            background = Color(0xFF091014),
            onBackground = Color(0xFFE6F0F1),
            surface = Color(0xFF10191D),
            onSurface = Color(0xFFE6F0F1),
            surfaceVariant = Color(0xFF243235),
            onSurfaceVariant = Color(0xFFB9C9CB),
            outline = Color(0xFF839396),
            outlineVariant = Color(0xFF3E4C4F),
            error = Color(0xFFFFB4AB),
            onError = Color(0xFF690005),
            errorContainer = Color(0xFF93000A),
            onErrorContainer = Color(0xFFFFDAD6)
        )
    } else {
        lightColorScheme(
            primary = Color(0xFF236A68),
            onPrimary = Color.White,
            primaryContainer = Color(0xFFA6EFEB),
            onPrimaryContainer = Color(0xFF00201F),
            secondary = Color(0xFF7D5F2A),
            onSecondary = Color.White,
            secondaryContainer = Color(0xFFFFE08D),
            onSecondaryContainer = Color(0xFF251A00),
            tertiary = Color(0xFF5F5C8A),
            onTertiary = Color.White,
            tertiaryContainer = Color(0xFFE5DFFF),
            onTertiaryContainer = Color(0xFF1B1943),
            background = Color(0xFFF7FAFA),
            onBackground = Color(0xFF171D1E),
            surface = Color(0xFFFBFCFC),
            onSurface = Color(0xFF171D1E),
            surfaceVariant = Color(0xFFE2E8E7),
            onSurfaceVariant = Color(0xFF3F494A),
            outline = Color(0xFF6F797A),
            outlineVariant = Color(0xFFBECAC9),
            error = Color(0xFFBA1A1A),
            onError = Color.White,
            errorContainer = Color(0xFFFFDAD6),
            onErrorContainer = Color(0xFF410002)
        )
    }
    MaterialTheme(
        colorScheme = colors,
        content = content
    )
}

@Composable
internal fun ScaleBenchApp(
    bluetooth: BluetoothScaleManager,
    usbSerial: AndroidUSBSerialManager,
    savedRecordingStore: SavedRecordingStore,
    renderTick: Int,
    fileWorkMessage: String?,
    onSave: (String) -> RecordingSaveResult,
    onLoadExamples: () -> Unit,
    onImportRecording: () -> Unit,
    onDeleteSaved: (SavedRecordingSummary) -> Unit,
    onExport: (String) -> Unit,
    onExportRecording: (ScaleRecording) -> Unit,
    onExportSaved: (SavedRecordingSummary) -> Unit,
    onShareScorecard: (String) -> Unit,
    onShareRecordingScorecard: (ScaleRecording) -> Unit,
    onShareSavedScorecard: (SavedRecordingSummary) -> Unit,
    deviceUtilityState: DeviceUtilityState,
    onChooseFirmware: () -> Unit,
    onStartClassicDfu: () -> Unit,
    onRefreshCabledEsp: () -> Unit,
    onSelectCabledEsp: (String) -> Unit,
    onBackupCabledEsp: () -> Unit,
    onFlashCabledEsp: () -> Unit,
    onExportDeviceReport: () -> Unit
) {
    renderTick.hashCode()
    val context = LocalContext.current
    val discoveredScales = bluetooth.discoveredScales()
    val savedRecordings = savedRecordingStore.recordings()
    var selectedModeName by rememberSaveable { mutableStateOf(RecordingMode.SHOT.name) }
    val selectedMode = RecordingMode.valueOf(selectedModeName)
    var recordingNotes by rememberSaveable { mutableStateOf(bluetooth.currentRecordingSnapshot().notes ?: "") }
    var showRecordingResults by rememberSaveable { mutableStateOf(false) }
    var handledCompletionKey by rememberSaveable { mutableStateOf<String?>(null) }
    var recordingSaveMessage by rememberSaveable { mutableStateOf("") }
    var recordingSaveSucceeded by rememberSaveable { mutableStateOf(false) }
    var recordingSaveRetryable by rememberSaveable { mutableStateOf(false) }
    var showHelp by rememberSaveable { mutableStateOf(false) }
    var completedResultRecording by remember { mutableStateOf<ScaleRecording?>(null) }
    var selectedSavedSummary by remember { mutableStateOf<SavedRecordingSummary?>(null) }
    var selectedSavedDetails by remember { mutableStateOf<SavedRecordingDetails?>(null) }
    val saveScope = rememberCoroutineScope()
    val isConnected = bluetooth.isConnected
    val connectedScaleAddress = bluetooth.connectedDevice()?.address?.takeIf { isConnected }
    val currentRecordingSnapshot = bluetooth.currentRecordingSnapshot()
    val usbCompletionKey = usbSerial.completedRecording?.id
    val bluetoothCompletionKey = bluetooth.completedRecordingId()

    suspend fun saveCompletedRecording(recording: ScaleRecording): RecordingSaveResult =
        withContext(Dispatchers.IO) {
            try {
                if (recording.samples.isEmpty() && recording.rawPackets.isEmpty()) {
                    RecordingSaveResult(
                        saved = false,
                        retryable = false,
                        message = "No saved shot was created because no packets were captured."
                    )
                } else {
                    savedRecordingStore.save(recording, recordingNotes, null, false)
                    RecordingSaveResult(
                        saved = true,
                        retryable = false,
                        message = "Saved automatically. Detailed charts and packet analysis are ready in Saved shots."
                    )
                }
            } catch (error: Exception) {
                RecordingSaveResult(
                    saved = false,
                    retryable = true,
                    message = "Automatic save failed: ${error.message ?: "The recording file could not be written."}"
                )
            }
        }

    LaunchedEffect(bluetoothCompletionKey) {
        if (bluetoothCompletionKey != null && bluetoothCompletionKey != handledCompletionKey) {
            handledCompletionKey = bluetoothCompletionKey
            val completed = bluetooth.takeCompletedRecording() ?: return@LaunchedEffect
            completedResultRecording = completed
            recordingSaveMessage = "Saving automatically. Detailed charts and packet analysis will be ready in Saved shots."
            recordingSaveSucceeded = true
            recordingSaveRetryable = false
            showRecordingResults = true
            val result = saveCompletedRecording(completed)
            recordingSaveMessage = result.message
            recordingSaveSucceeded = result.saved
            recordingSaveRetryable = result.retryable
        }
    }
    LaunchedEffect(usbCompletionKey) {
        val completed = usbSerial.takeCompletedRecording()
        if (completed != null) {
            completedResultRecording = completed
            recordingSaveMessage = "Saving automatically. Detailed charts and packet analysis will be ready in Saved shots."
            recordingSaveSucceeded = true
            recordingSaveRetryable = false
            showRecordingResults = true
            val result = saveCompletedRecording(completed)
            recordingSaveMessage = result.message
            recordingSaveSucceeded = result.saved
            recordingSaveRetryable = result.retryable
        }
    }
    LaunchedEffect(selectedSavedSummary?.id) {
        val summary = selectedSavedSummary
        selectedSavedDetails = null
        if (summary != null) {
            val details = withContext(Dispatchers.Default) {
                readSavedRecordingDetails(savedRecordingStore, summary)
            }
            if (selectedSavedSummary?.id == summary.id) {
                selectedSavedDetails = details
            }
        }
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) {
            bluetooth.startScanning()
        }
    }
    val startScan = {
        if (hasBluetoothPermissions(context)) {
            bluetooth.startScanning()
        } else {
            permissionLauncher.launch(bluetoothPermissions())
        }
    }

    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            @OptIn(ExperimentalMaterial3Api::class)
            TopAppBar(
                title = {
                    Column {
                        Text("ScaleBench", fontWeight = FontWeight.SemiBold)
                        Text(
                            nextStepTitle(
                                isConnected = isConnected,
                                hasRecordingData = currentRecordingSnapshot.samples.isNotEmpty()
                                        || currentRecordingSnapshot.rawPackets.isNotEmpty(),
                                savedCount = savedRecordings.size
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                actions = {
                    TextButton(onClick = { showHelp = true }) {
                        Text("Help")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                BluetoothSection(
                    bluetooth = bluetooth,
                    onScan = startScan,
                    onStopScan = bluetooth::stopScanning
                )
            }

            item {
                ScalesSection(
                    scales = discoveredScales,
                    connectedAddress = connectedScaleAddress,
                    isScanning = bluetooth.isScanning,
                    onConnect = { scale ->
                        bluetooth.connect(scale)
                    }
                )
            }

            item {
                WiredUSBSection(
                    usbSerial = usbSerial,
                    selectedMode = selectedMode,
                    recordingNotes = recordingNotes
                )
            }

            item {
                RecordingSection(
                    bluetooth = bluetooth,
                    canRecord = isConnected && !bluetooth.isFinalizing && !usbSerial.isRecording,
                    selectedMode = selectedMode,
                    onModeChanged = { selectedModeName = it.name },
                    recordingNotes = recordingNotes,
                    onRecordingNotesChanged = {
                        recordingNotes = it
                        bluetooth.updateCurrentRecordingNotes(it)
                    },
                    onRecord = {
                        if (!bluetooth.isRecording) {
                            bluetooth.startRecording(selectedMode)
                            bluetooth.updateCurrentRecordingNotes(recordingNotes)
                        }
                    },
                    onTare = bluetooth::sendAtomicTareAndStart,
                    onExport = { onExport(recordingNotes) }
                )
            }

            if (isConnected) {
                item {
                    LiveSection(bluetooth = bluetooth)
                }
            }

            if (!bluetooth.isRecording &&
                !showRecordingResults &&
                selectedSavedSummary == null &&
                (currentRecordingSnapshot.samples.size >= 2 || currentRecordingSnapshot.rawPackets.size >= 2)
            ) {
                item {
                    ScorecardSection(recording = currentRecordingSnapshot, metrics = bluetooth.currentMetrics())
                }
                item {
                    VisualizerSection(
                        recording = currentRecordingSnapshot,
                        metrics = bluetooth.currentMetrics()
                    )
                }
            }

            item {
                SavedRecordingsSection(
                    recordings = savedRecordings,
                    libraryWarning = savedRecordingStore.lastErrorMessage(),
                    onLoadExamples = onLoadExamples,
                    onImportRecording = onImportRecording,
                    onDeleteSaved = onDeleteSaved,
                    onOpenSaved = { saved ->
                        selectedSavedSummary = saved
                    }
                )
            }

            item {
                DeviceUtilitySection(
                    bluetooth = bluetooth,
                    state = deviceUtilityState,
                    onChooseFirmware = onChooseFirmware,
                    onStartClassicDfu = onStartClassicDfu,
                    onRefreshCabledEsp = onRefreshCabledEsp,
                    onSelectCabledEsp = onSelectCabledEsp,
                    onBackupCabledEsp = onBackupCabledEsp,
                    onFlashCabledEsp = onFlashCabledEsp,
                    onExportDeviceReport = onExportDeviceReport
                )
            }
        }

        if (bluetooth.isRecording || bluetooth.isFinalizing) {
            RecordingTimerDialog(
                bluetooth = bluetooth,
                onStop = {
                    bluetooth.stopRecording()
                }
            )
        }

        if (usbSerial.isRecording || usbSerial.isFinalizing) {
            USBRecordingTimerDialog(
                usbSerial = usbSerial,
                onStop = {
                    usbSerial.stopRecording()
                }
            )
        }

        if (showRecordingResults && !bluetooth.isRecording && !bluetooth.isFinalizing && !usbSerial.isRecording && !usbSerial.isFinalizing) {
            val resultRecording = completedResultRecording ?: bluetooth.currentRecordingSnapshot()
            RecordingResultsDialog(
                recording = resultRecording,
                metrics = resultRecording.metrics,
                saveMessage = recordingSaveMessage,
                saveSucceeded = recordingSaveSucceeded,
                canRetrySave = recordingSaveRetryable,
                onDismiss = {
                    showRecordingResults = false
                    completedResultRecording = null
                },
                onRetrySave = {
                    recordingSaveMessage = "Saving automatically. Detailed charts and packet analysis will be ready in Saved shots."
                    recordingSaveSucceeded = true
                    recordingSaveRetryable = false
                    saveScope.launch {
                        val result = saveCompletedRecording(resultRecording)
                        recordingSaveMessage = result.message
                        recordingSaveSucceeded = result.saved
                        recordingSaveRetryable = result.retryable
                    }
                },
                onExport = {
                    if (resultRecording.source == RecordingSource.USB_SERIAL) {
                        onExportRecording(resultRecording)
                    } else {
                        onExport(recordingNotes)
                    }
                },
                onShareScorecard = {
                    if (resultRecording.source == RecordingSource.USB_SERIAL) {
                        onShareRecordingScorecard(resultRecording)
                    } else {
                        onShareScorecard(recordingNotes)
                    }
                }
            )
        }

        val savedDetails = selectedSavedDetails
        if (savedDetails != null) {
            SavedRecordingDetailsDialog(
                details = savedDetails,
                onExport = { onExportSaved(savedDetails.summary) },
                onShareScorecard = { onShareSavedScorecard(savedDetails.summary) },
                onDelete = {
                    val summary = savedDetails.summary
                    selectedSavedSummary = null
                    selectedSavedDetails = null
                    onDeleteSaved(summary)
                },
                onDismiss = {
                    selectedSavedSummary = null
                    selectedSavedDetails = null
                }
            )
        } else if (selectedSavedSummary != null) {
            AlertDialog(
                onDismissRequest = { selectedSavedSummary = null },
                title = { Text(selectedSavedSummary?.title ?: "Recording") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        Text(
                            "Preparing charts and packet inspector...",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                confirmButton = {
                    TextButton(onClick = { selectedSavedSummary = null }) {
                        Text("Cancel")
                    }
                }
            )
        }

        if (showHelp) {
            ScaleBenchHelpDialog(onDismiss = { showHelp = false })
        }

        if (fileWorkMessage != null) {
            FileWorkDialog(message = fileWorkMessage)
        }
    }
}

@Composable
private fun FileWorkDialog(message: String) {
    AlertDialog(
        onDismissRequest = {},
        title = { Text(message) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(
                    "Large recordings can take a moment.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        confirmButton = {}
    )
}

@Composable
internal fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(8.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                content = content
            )
        }
    }
}

@Composable
internal fun OnboardingCard(
    isConnected: Boolean,
    isScanning: Boolean,
    hasRecordingData: Boolean,
    savedCount: Int,
    onScan: () -> Unit,
    onLoadExamples: () -> Unit,
    onHelp: () -> Unit
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(nextStepTitle(isConnected, hasRecordingData, savedCount), fontWeight = FontWeight.SemiBold)
            Text(
                nextStepDetail(isConnected, isScanning, hasRecordingData, savedCount),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (!isConnected) {
                    Button(onClick = onScan) {
                        Text(if (isScanning) "Scanning..." else "Scan")
                    }
                }
                if (savedCount == 0) {
                    OutlinedButton(onClick = onLoadExamples) {
                        Text("Load examples")
                    }
                }
                TextButton(onClick = onHelp) {
                    Text("Test guide")
                }
            }
        }
    }
}

internal fun nextStepTitle(isConnected: Boolean, hasRecordingData: Boolean, savedCount: Int): String {
    return when {
        !isConnected -> "Start by connecting a scale"
        !hasRecordingData -> "Ready for a Shot / Pour test"
        savedCount == 0 -> "Review results, then open the saved shot"
        else -> "Open a saved recording or run another test"
    }
}

internal fun nextStepDetail(
    isConnected: Boolean,
    isScanning: Boolean,
    hasRecordingData: Boolean,
    savedCount: Int
): String {
    return when {
        !isConnected && isScanning -> "Keep the scale awake and nearby. Supported scales will appear in the Scales section."
        !isConnected -> "Tap Scan, connect a supported BLE scale, then run Shot / Pour for at least 20 seconds."
        !hasRecordingData -> "Tare and settle before Start Recording. Stop before removing the cup so the boundaries stay clean."
        savedCount == 0 -> "The result screen explains deductions and charts packet gaps. ScaleBench saves real recordings automatically."
        else -> "Saved recordings recalculate with the current analyzer and include charts, score evidence, raw packets, and JSON export."
    }
}

@Composable
internal fun ScaleBenchHelpDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val content = remember { SharedHelpContent.load(context) }
    val scope = rememberCoroutineScope()
    var releaseCheck by remember { mutableStateOf<ReleaseCheckState>(ReleaseCheckState.Idle) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(content.title) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                content.sections.forEach { section ->
                    item {
                        HelpCard(section.title) {
                            section.items.forEach { helpItem ->
                                SharedHelpItemView(helpItem)
                            }
                        }
                    }
                }
            }
        },
        dismissButton = {
            TextButton(
                onClick = {
                    val available = releaseCheck as? ReleaseCheckState.Available
                    if (available != null) {
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(available.releaseUrl)))
                        }
                        return@TextButton
                    }

                    releaseCheck = ReleaseCheckState.Checking
                    scope.launch {
                        releaseCheck = checkLatestGitHubRelease(context)
                    }
                },
                enabled = releaseCheck !is ReleaseCheckState.Checking
            ) {
                Text(releaseCheck.buttonTitle)
            }
        },
        confirmButton = {
            Column(horizontalAlignment = Alignment.End) {
                releaseCheck.message?.let { message ->
                    Text(
                        message,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (releaseCheck is ReleaseCheckState.Failed) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        modifier = Modifier.padding(bottom = 6.dp)
                    )
                }
                TextButton(onClick = onDismiss) {
                    Text("Done")
                }
            }
        }
    )
}

private sealed class ReleaseCheckState {
    data object Idle : ReleaseCheckState()
    data object Checking : ReleaseCheckState()
    data class UpToDate(val current: String) : ReleaseCheckState()
    data class Available(val current: String, val latest: String, val releaseUrl: String) : ReleaseCheckState()
    data class Failed(val reason: String) : ReleaseCheckState()

    val buttonTitle: String
        get() = when (this) {
            Idle, is UpToDate, is Failed -> "Check for New Release"
            Checking -> "Checking..."
            is Available -> "Open Latest Release"
        }

    val message: String?
        get() = when (this) {
            Idle, Checking -> null
            is UpToDate -> "You are up to date on ScaleBench $current."
            is Available -> "ScaleBench $latest is available. You are running $current."
            is Failed -> reason
        }
}

private suspend fun checkLatestGitHubRelease(context: Context): ReleaseCheckState = withContext(Dispatchers.IO) {
    val current = currentVersionName(context)
    runCatching {
        val connection = (URL("https://api.github.com/repos/danielfcurrie-alt/ScaleBench/releases/latest").openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 10_000
            requestMethod = "GET"
            setRequestProperty("User-Agent", "ScaleBench")
        }
        connection.use {
            if (responseCode !in 200..299) {
                return@withContext ReleaseCheckState.Failed("Could not check GitHub Releases right now.")
            }
            val json = inputStream.bufferedReader().use { reader -> reader.readText() }
            val release = JSONObject(json)
            val tag = release.optString("tag_name").trim().trimStart('v', 'V')
            val url = release.optString("html_url", "https://github.com/danielfcurrie-alt/ScaleBench/releases/latest")
            if (isNewerVersion(tag, current)) {
                ReleaseCheckState.Available(current, tag, url)
            } else {
                ReleaseCheckState.UpToDate(current)
            }
        }
    }.getOrElse {
        ReleaseCheckState.Failed("Could not check GitHub Releases right now.")
    }
}

@Suppress("DEPRECATION")
private fun currentVersionName(context: Context): String {
    return runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
    }.getOrDefault("0")
}

private fun isNewerVersion(latest: String, current: String): Boolean {
    val left = latest.split(".").map { it.toIntOrNull() ?: 0 }
    val right = current.split(".").map { it.toIntOrNull() ?: 0 }
    val count = max(left.size, right.size)
    for (index in 0 until count) {
        val l = left.getOrElse(index) { 0 }
        val r = right.getOrElse(index) { 0 }
        if (l != r) return l > r
    }
    return false
}

private inline fun <T : HttpURLConnection, R> T.use(block: T.() -> R): R {
    return try {
        block()
    } finally {
        disconnect()
    }
}

@Composable
internal fun SharedHelpItemView(item: SharedHelpItem) {
    val context = LocalContext.current
    when (item.type) {
        SharedHelpItemType.STEP -> HelpStep(item.number ?: "", listOfNotNull(item.title, item.text).joinToString(": "))
        SharedHelpItemType.ROW -> HelpProcedureRow(
            title = item.title.orEmpty(),
            detail = item.value ?: item.text.orEmpty()
        )
        SharedHelpItemType.BULLET -> Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("•", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(item.text.orEmpty(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        SharedHelpItemType.TEXT -> Text(
            item.text.orEmpty(),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        SharedHelpItemType.LINK -> {
            val url = item.value ?: item.text.orEmpty()
            TextButton(
                onClick = {
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    }
                },
                contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp)
            ) {
                Text(item.title ?: url)
            }
        }
    }
}

@Composable
private fun HelpProcedureRow(title: String, detail: String) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Text(
            title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            detail,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
internal fun HelpCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(title, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

@Composable
internal fun HelpStep(number: String, text: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Surface(
            shape = RoundedCornerShape(8.dp),
            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)
        ) {
            Text(
                number,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.primary
            )
        }
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}


@Composable
internal fun BluetoothSection(
    bluetooth: BluetoothScaleManager,
    onScan: () -> Unit,
    onStopScan: () -> Unit
) {
    SectionCard("Bluetooth") {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(if (bluetooth.connectedDevice() == null) "Bluetooth scale" else bluetooth.connectedDevice().name, fontWeight = FontWeight.SemiBold)
                Text(
                    bluetooth.status(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(12.dp))
            Button(
                onClick = { if (bluetooth.isScanning) onStopScan() else onScan() }
            ) {
                Text(if (bluetooth.isScanning) "Stop" else "Scan")
            }
        }
    }
}

@Composable
internal fun WiredUSBSection(
    usbSerial: AndroidUSBSerialManager,
    selectedMode: RecordingMode,
    recordingNotes: String
) {
    SectionCard("Wired") {
        val selected = usbSerial.devices.firstOrNull { it.deviceName == usbSerial.selectedDeviceName }
        val statusIsShownAsSubtitle = selected == null
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("USB scales", fontWeight = FontWeight.SemiBold)
                Text(
                    selected?.let { "${it.label} · ${it.details}" } ?: usbSerial.status,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(12.dp))
            OutlinedButton(
                onClick = usbSerial::refreshDevices,
                enabled = !usbSerial.isRecording
            ) {
                Text("Refresh")
            }
        }

        if (usbSerial.devices.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                usbSerial.devices.forEach { device ->
                    val selectedDevice = device.deviceName == usbSerial.selectedDeviceName
                    val access = if (device.hasPermission) "access granted" else "needs access"
                    val serial = if (device.hasSerialEndpoints) "serial" else "unknown"
                    val label = "${device.label} · $serial · $access"
                    if (selectedDevice) {
                        Button(onClick = { usbSerial.selectDevice(device.deviceName) }) {
                            Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    } else {
                        OutlinedButton(onClick = { usbSerial.selectDevice(device.deviceName) }) {
                            Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }

        if (!statusIsShownAsSubtitle) {
            Text(
                usbSerial.status,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            OutlinedButton(
                onClick = usbSerial::requestPermission,
                enabled = !usbSerial.isRecording && usbSerial.selectedDeviceName.isNotBlank()
            ) {
                Text("Grant USB")
            }
            Button(
                onClick = {
                    if (usbSerial.isRecording) {
                        usbSerial.stopRecording()
                    } else {
                        usbSerial.startRecording(selectedMode, recordingNotes)
                    }
                },
                enabled = usbSerial.selectedDeviceName.isNotBlank()
            ) {
                Text(if (usbSerial.isRecording) "Stop USB" else "Start USB")
            }
        }

        if (usbSerial.isRecording || usbSerial.latestSample != null) {
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            SwiftMetricRow("Live weight", usbSerial.latestSample?.let { String.format(Locale.US, "%.3f g", it.weightGrams) } ?: "--")
            SwiftMetricRow("Device cadence", usbSerial.latestSample?.usbSerial?.let { String.format(Locale.US, "%.2f Hz", it.hx711Hz) } ?: "--")
            SwiftMetricRow("Received rate", usbSerial.hostReceiveRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
            SwiftMetricRow("Samples", usbSerial.currentRecordingSnapshot().samples.size.toString())
            SwiftMetricRow("USB dropped", usbSerial.droppedCount.toString())
            SwiftMetricRow("Battery", usbSerial.latestSample?.batteryPercent?.let { "$it%" } ?: "Unavailable")
        }
    }
}

@Composable
internal fun DeviceUtilitySection(
    bluetooth: BluetoothScaleManager,
    state: DeviceUtilityState,
    onChooseFirmware: () -> Unit,
    onStartClassicDfu: () -> Unit,
    onRefreshCabledEsp: () -> Unit,
    onSelectCabledEsp: (String) -> Unit,
    onBackupCabledEsp: () -> Unit,
    onFlashCabledEsp: () -> Unit,
    onExportDeviceReport: () -> Unit
) {
    val device = bluetooth.connectedDevice()?.takeIf { bluetooth.isConnected }
    SectionCard("Device Utility") {
        if (device == null) {
            Text("Connect a BLE scale or plug in a USB ESP32 scale to inspect firmware update and backup options.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            SwiftMetricRow("Connected", device.name)
            SwiftMetricRow("Protocol", device.kind.displayName)
            SwiftMetricRow("DFU capability", deviceUtilityCapabilityLabel(device.advertisedServices))
            if (device.advertisedServices.isNotEmpty()) {
                Text(
                    device.advertisedServices.joinToString("\n"),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Firmware update", fontWeight = FontWeight.SemiBold)
            Text(
                "Classic Nordic DFU supports nRF5 Secure/Legacy DFU ZIP packages. SMP/McuManager is detected but not wired in this build.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onChooseFirmware) {
                    Text("Choose ZIP")
                }
                Button(
                    onClick = onStartClassicDfu,
                    enabled = state.selectedFirmwareUri != null && !bluetooth.isRecording
                ) {
                    Text("Start DFU")
                }
            }
            state.selectedFirmwareName?.let { SwiftMetricRow("Package", it) }
            SwiftMetricRow("Status", state.status)
            state.progress?.let { progress ->
                LinearProgressIndicator(
                    progress = { progress / 100f },
                    modifier = Modifier.fillMaxWidth()
                )
            }
            state.log.takeLast(4).forEach { line ->
                Text(line, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("ESP32 cable", fontWeight = FontWeight.SemiBold)
            Text(
                "Android can detect USB devices now. Actual ESP32 backup/flash needs a native esp-serial-flasher bridge; the buttons are blocked until that backend lands.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedButton(onClick = onRefreshCabledEsp) {
                    Text("Refresh USB")
                }
                Button(onClick = onBackupCabledEsp, enabled = false) {
                    Text("Backup ESP32")
                }
                Button(
                    onClick = onFlashCabledEsp,
                    enabled = false
                ) {
                    Text("Flash ESP32")
                }
            }
            if (state.cabledUsbDevices.isEmpty()) {
                Text("No USB devices detected yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                state.cabledUsbDevices.forEach { usb ->
                    OutlinedButton(
                        onClick = { onSelectCabledEsp(usb.deviceName) },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                if (state.selectedUsbDeviceName == usb.deviceName) "${usb.displayName} selected" else usb.displayName,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                "VID ${usb.vendorId.toString(16)} PID ${usb.productId.toString(16)} · permission ${if (usb.hasPermission) "yes" else "no"}",
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                    }
                }
            }
        }

        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Backup", fontWeight = FontWeight.SemiBold)
            Text(
                "Full firmware image backup usually requires firmware readback support. ScaleBench can export device metadata and latest telemetry now.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedButton(onClick = onExportDeviceReport) {
                Text("Export Device Report")
            }
        }
    }
}

@Composable
internal fun ScalesSection(
    scales: List<DiscoveredScale>,
    connectedAddress: String?,
    isScanning: Boolean,
    onConnect: (DiscoveredScale) -> Unit
) {
    SectionCard("Scales") {
        if (scales.isEmpty()) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(if (isScanning) "Looking for scales" else "No scales yet", fontWeight = FontWeight.SemiBold)
                    Text(
                        if (isScanning) "Keep the scale awake and close to this phone." else "Tap Scan above, then connect when your scale appears.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        } else {
            scales.forEachIndexed { index, scale ->
                ScaleListRow(
                    scale = scale,
                    isConnected = connectedAddress == scale.address,
                    onConnect = { onConnect(scale) }
                )
                if (index < scales.lastIndex) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RecordingSection(
    bluetooth: BluetoothScaleManager,
    canRecord: Boolean,
    selectedMode: RecordingMode,
    onModeChanged: (RecordingMode) -> Unit,
    recordingNotes: String,
    onRecordingNotesChanged: (String) -> Unit,
    onRecord: () -> Unit,
    onTare: () -> Unit,
    onExport: () -> Unit
) {
    val recording = bluetooth.currentRecordingSnapshot()
    val hasRecordingData = recording.samples.isNotEmpty()
            || recording.rawPackets.isNotEmpty()
    val metrics = bluetooth.currentMetrics()
    SectionCard("Recording") {
        var menuExpanded by remember { mutableStateOf(false) }
        ExposedDropdownMenuBox(
            expanded = menuExpanded,
            onExpandedChange = { menuExpanded = it }
        ) {
            TextField(
                modifier = Modifier
                    .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, true)
                    .fillMaxWidth(),
                value = selectedMode.displayName,
                onValueChange = {},
                readOnly = true,
                label = { Text("Mode") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menuExpanded) }
            )
            ExposedDropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false }
            ) {
                RecordingMode.values().forEach { mode ->
                    DropdownMenuItem(
                        text = { Text(mode.displayName) },
                        onClick = {
                            onModeChanged(mode)
                            menuExpanded = false
                        }
                    )
                }
            }
        }

        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(8.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        ) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(recordingStatusLabel(bluetooth, canRecord, hasRecordingData), fontWeight = FontWeight.SemiBold)
                Text(modeHelp(selectedMode), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        if (hasRecordingData) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.28f)
            ) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text("Live diagnostics", fontWeight = FontWeight.SemiBold)
                    RecordingDiagnosticsRows(metrics)
                }
            }
        }

        OutlinedTextField(
            value = recordingNotes,
            onValueChange = onRecordingNotesChanged,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Notes") },
            minLines = 2,
            maxLines = 4
        )

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Button(
                onClick = onRecord,
                enabled = canRecord || bluetooth.isRecording
            ) {
                Text(if (bluetooth.isRecording) "View Timer" else "Start Recording")
            }
            OutlinedButton(onClick = onTare, enabled = bluetooth.connectedDevice() != null) {
                Text("Tare + Start")
            }
            OutlinedButton(onClick = onExport, enabled = !bluetooth.isRecording && hasRecordingData) {
                Text("Save JSON.gz...")
            }
        }
    }
}

@Composable
internal fun RecordingTimerDialog(
    bluetooth: BluetoothScaleManager,
    onStop: () -> Unit
) {
    var timerTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(bluetooth.isRecording, bluetooth.isFinalizing) {
        while (bluetooth.isRecording && !bluetooth.isFinalizing) {
            delay(1000)
            timerTick++
        }
    }
    timerTick.hashCode()

    val recording = bluetooth.currentRecordingSnapshot()
    val metrics = bluetooth.currentMetrics()
    val sample = bluetooth.latestSample()
    val elapsedMillis = (System.currentTimeMillis() - recording.startedAtMillis).coerceAtLeast(0)
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Recording") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    formatDuration(elapsedMillis),
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    if (bluetooth.isFinalizing) bluetooth.status() else recording.mode.displayName,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (bluetooth.isFinalizing) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    Text(
                        "Analyzing and saving the recording...",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                SwiftMetricRow("Samples", recording.samples.size.toString())
                SwiftMetricRow("Packets", recording.rawPackets.size.toString())
                SwiftMetricRow("Weight", sample?.weightGrams?.let { String.format(Locale.US, "%.2f g", it) } ?: "--")
                SwiftMetricRow("Flow", sample?.flowGramsPerSecond?.let { String.format(Locale.US, "%.2f g/s", it) } ?: "--")
                SwiftMetricRow("Battery", sample?.batteryPercent?.let { "$it%" } ?: bluetooth.latestBatteryPercent()?.let { "$it%" } ?: "--")
                RecordingDiagnosticsRows(metrics)
            }
        },
        confirmButton = {
            Button(onClick = onStop, enabled = !bluetooth.isFinalizing) {
                Text(if (bluetooth.isFinalizing) "Finishing..." else "Stop and View Results")
            }
        }
    )
}

@Composable
internal fun USBRecordingTimerDialog(
    usbSerial: AndroidUSBSerialManager,
    onStop: () -> Unit
) {
    var timerTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(usbSerial.isRecording, usbSerial.isFinalizing) {
        while (usbSerial.isRecording && !usbSerial.isFinalizing) {
            delay(1000)
            timerTick++
        }
    }
    timerTick.hashCode()

    val recording = usbSerial.currentRecordingSnapshot()
    val sample = usbSerial.latestSample
    val elapsedMillis = (System.currentTimeMillis() - recording.startedAtMillis).coerceAtLeast(0)
    AlertDialog(
        onDismissRequest = {},
        title = { Text("USB Recording") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    formatDuration(elapsedMillis),
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.Bold
                )
                Text(usbSerial.status, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (usbSerial.isFinalizing) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    Text(
                        "Analyzing and saving the recording...",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                SwiftMetricRow("Samples", recording.samples.size.toString())
                SwiftMetricRow("Packets", recording.rawPackets.size.toString())
                SwiftMetricRow("Weight", sample?.weightGrams?.let { String.format(Locale.US, "%.3f g", it) } ?: "--")
                SwiftMetricRow("Flow", sample?.flowGramsPerSecond?.let { String.format(Locale.US, "%.2f g/s", it) } ?: "--")
                SwiftMetricRow("Device cadence", sample?.usbSerial?.let { String.format(Locale.US, "%.2f Hz", it.hx711Hz) } ?: "--")
                SwiftMetricRow("Received rate", usbSerial.hostReceiveRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
                SwiftMetricRow("USB dropped", usbSerial.droppedCount.toString())
                SwiftMetricRow("Battery", sample?.batteryPercent?.let { "$it%" } ?: "Unavailable")
            }
        },
        confirmButton = {
            Button(onClick = onStop, enabled = !usbSerial.isFinalizing) {
                Text(if (usbSerial.isFinalizing) "Finishing..." else "Stop and View Results")
            }
        }
    )
}

@Composable
internal fun RecordingResultsDialog(
    recording: ScaleRecording,
    metrics: ScaleQualityMetrics,
    saveMessage: String,
    saveSucceeded: Boolean,
    canRetrySave: Boolean,
    onDismiss: () -> Unit,
    onRetrySave: () -> Unit,
    onExport: () -> Unit,
    onShareScorecard: () -> Unit
) {
    val hasRecordingData = recording.samples.isNotEmpty() || recording.rawPackets.isNotEmpty()
    val canShareScorecard = hasRecordingData && canShareOfficialScorecard(recording.mode, metrics)
    var showVisualizer by rememberSaveable(recording.id) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.fillMaxWidth(0.96f),
        properties = DialogProperties(usePlatformDefaultWidth = false),
        title = { Text("Recording Results") },
        text = {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 720.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(recording.defaultTitle(), fontWeight = FontWeight.SemiBold)
                        if (!hasRecordingData) {
                            Text(
                                "No packets were captured. If the scale is connected, start recording again and leave this open while weight updates arrive.",
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        ScoreHero(
                            title = standardScoreTitle(recording.mode),
                            value = standardScoreDisplay(recording.mode, metrics),
                            isValid = metrics.validity?.isValid
                        )
                        StandardScoreRows(recording.mode, metrics, showScore = false)
                        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                        Text("Recording summary", fontWeight = FontWeight.SemiBold)
                        SwiftMetricRow("Samples", recording.samples.size.toString())
                        SwiftMetricRow("Raw packets", recording.rawPackets.size.toString())
	                        if (recording.source == RecordingSource.USB_SERIAL) {
	                            SwiftMetricRow("Device cadence", usbDeviceCadence(recording))
	                            SwiftMetricRow("Received rate", usbHostReceiveRate(recording))
	                        } else {
                            SwiftMetricRow("Effective rate", metrics.effectiveSampleRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
                        }
                        SwiftMetricRow("Interval p95", metrics.packetIntervalP95Milliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
                        SwiftMetricRow("Max gap", metrics.packetIntervalMaxMilliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
                        SwiftMetricRow("Long gaps", metrics.longGapCount.toString())
                        SwiftMetricRow("Missing seq", metrics.missingSequenceCount.toString())
                        SwiftMetricRow("Rejected", metrics.rejectedPacketCount.toString())
                        SwiftMetricRow("Idle noise", metrics.idleNoisePeakToPeakGrams?.let { String.format(Locale.US, "%.2f g p-p", it) } ?: "--")
                        SwiftMetricRow("Drift", metrics.driftGramsPerMinute?.let { String.format(Locale.US, "%.3f g/min", it) } ?: "--")
                        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                        ScoreBreakdownRows(recording, metrics)
                    }
                }
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            saveMessage.ifBlank {
                                if (hasRecordingData) {
                                    "Automatic save has not completed."
                                } else {
                                    "No saved shot was created because no packets were captured."
                                }
                            },
                            color = if (saveSucceeded || !hasRecordingData) {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            } else {
                                MaterialTheme.colorScheme.error
                            },
                            style = MaterialTheme.typography.bodyMedium
                        )
                        if (canRetrySave) {
                            OutlinedButton(onClick = onRetrySave) {
                                Text("Retry Save")
                            }
                        }
                    }
                }
                if (hasRecordingData && showVisualizer) {
                    item {
                        RecordingVisualizer(recording = recording, metrics = metrics)
                    }
                } else if (hasRecordingData) {
                    item {
                        OutlinedButton(
                            onClick = { showVisualizer = true },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Show Charts and Packet Inspector")
                        }
                    }
                }
                item {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Button(onClick = onShareScorecard, enabled = canShareScorecard) {
                            Text("Share Scorecard")
                        }
                        OutlinedButton(onClick = onExport, enabled = hasRecordingData) {
                            Text("Save JSON.gz...")
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Done")
            }
        }
    )
}

internal fun usbDeviceCadence(recording: ScaleRecording): String {
    val cadences = recording.samples.mapNotNull { it.usbSerial?.hx711Hz }.filter { it.isFinite() && it > 0 }
    if (cadences.isEmpty()) return "--"
    val average = cadences.sum() / cadences.size
    return String.format(Locale.US, "%.2f Hz", average)
}

internal fun usbHostReceiveRate(recording: ScaleRecording): String {
    if (recording.samples.size < 2) return "--"
    val span = recording.samples.last().monotonicSeconds - recording.samples.first().monotonicSeconds
    if (span <= 0 || !span.isFinite()) return "--"
    return String.format(Locale.US, "%.1f Hz", recording.samples.size / span)
}

@Composable
internal fun LiveSection(bluetooth: BluetoothScaleManager) {
    val sample = bluetooth.latestSample()
    val recording = bluetooth.currentRecordingSnapshot()
    SectionCard("Live") {
        SwiftMetricRow("Weight", sample?.weightGrams?.let { String.format(Locale.US, "%.2f g", it) } ?: "--")
        SwiftMetricRow("Flow", sample?.flowGramsPerSecond?.let { String.format(Locale.US, "%.2f g/s", it) } ?: "--")
        SwiftMetricRow("Battery", sample?.batteryPercent?.let { "$it%" } ?: bluetooth.latestBatteryPercent()?.let { "$it%" } ?: "--")
        SwiftMetricRow("Protocol", sample?.scaleKind?.displayName ?: bluetooth.connectedDevice()?.kind?.displayName ?: "Unknown")
        SwiftMetricRow("Packets", recording.rawPackets.size.toString())
        SwiftMetricRow("Samples", recording.samples.size.toString())
        RecordingDiagnosticsRows(bluetooth.currentMetrics())
    }
}

@Composable
internal fun RecordingDiagnosticsRows(metrics: ScaleQualityMetrics) {
    SwiftMetricRow("Effective rate", metrics.effectiveSampleRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
    SwiftMetricRow("Resolution", resolutionDisplay(metrics))
    SwiftMetricRow("Bad packets", badPacketCount(metrics).toString())
    SwiftMetricRow("Long gaps", metrics.longGapCount.toString())
}
