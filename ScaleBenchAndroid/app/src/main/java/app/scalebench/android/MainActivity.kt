package app.scalebench.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
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
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.io.File
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.delay
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private lateinit var bluetooth: BluetoothScaleManager
    private lateinit var savedRecordingStore: SavedRecordingStore
    private var renderCallback: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bluetooth = BluetoothScaleManager(this) {
            runOnUiThread {
                renderCallback?.invoke()
            }
        }
        savedRecordingStore = SavedRecordingStore(this)
        setContent {
            ScaleBenchTheme {
                var renderTick by remember { mutableIntStateOf(0) }
                DisposableEffect(Unit) {
                    renderCallback = { renderTick++ }
                    onDispose { renderCallback = null }
                }
                ScaleBenchApp(
                    bluetooth = bluetooth,
                    savedRecordingStore = savedRecordingStore,
                    renderTick = renderTick,
                    onSave = { saveRecording() },
                    onDeleteSaved = { deleteSavedRecording(it) },
                    onExport = { exportRecording() }
                )
            }
        }
    }

    private fun exportRecording() {
        try {
            if (bluetooth.isRecording) {
                bluetooth.stopRecording()
            }
            val recording = bluetooth.currentRecording()
            recording.endedAtMillis = recording.endedAtMillis ?: System.currentTimeMillis()
            recording.metrics = ScaleQualityAnalyzer.analyze(recording)
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir
            val file = File(dir, "ScaleBench-${System.currentTimeMillis()}.json")
            JsonExporter.writeRecording(recording, file)
            Toast.makeText(this, "Exported ${file.absolutePath}", Toast.LENGTH_LONG).show()
            renderCallback?.invoke()
        } catch (error: Exception) {
            Toast.makeText(this, "Export failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun saveRecording() {
        try {
            if (bluetooth.isRecording) {
                bluetooth.stopRecording()
            }
            val recording = bluetooth.currentRecording()
            recording.endedAtMillis = recording.endedAtMillis ?: System.currentTimeMillis()
            recording.metrics = ScaleQualityAnalyzer.analyze(recording)
            val saved = savedRecordingStore.save(recording, recording.notes ?: "", null)
            Toast.makeText(this, "Saved ${saved.title}", Toast.LENGTH_SHORT).show()
            renderCallback?.invoke()
        } catch (error: Exception) {
            Toast.makeText(this, "Save failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun deleteSavedRecording(summary: SavedRecordingSummary) {
        try {
            savedRecordingStore.delete(summary)
            Toast.makeText(this, "Deleted ${summary.title}", Toast.LENGTH_SHORT).show()
            renderCallback?.invoke()
        } catch (error: Exception) {
            Toast.makeText(this, "Delete failed: ${error.message}", Toast.LENGTH_LONG).show()
        }
    }
}

@Composable
private fun ScaleBenchTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = if (dark) {
            darkColorScheme(
                primary = androidx.compose.ui.graphics.Color(0xFF7FDBD6),
                secondary = androidx.compose.ui.graphics.Color(0xFFE4C16D),
                tertiary = androidx.compose.ui.graphics.Color(0xFFC9C3FF),
                background = androidx.compose.ui.graphics.Color(0xFF091014),
                surface = androidx.compose.ui.graphics.Color(0xFF10191D),
                surfaceVariant = androidx.compose.ui.graphics.Color(0xFF243235)
            )
        } else {
            lightColorScheme(
                primary = androidx.compose.ui.graphics.Color(0xFF236A68),
                secondary = androidx.compose.ui.graphics.Color(0xFF7D5F2A),
                tertiary = androidx.compose.ui.graphics.Color(0xFF5F5C8A),
                surface = androidx.compose.ui.graphics.Color(0xFFFBFCFC),
                surfaceVariant = androidx.compose.ui.graphics.Color(0xFFE2E8E7)
            )
        },
        content = content
    )
}

@Composable
private fun ScaleBenchApp(
    bluetooth: BluetoothScaleManager,
    savedRecordingStore: SavedRecordingStore,
    renderTick: Int,
    onSave: () -> Unit,
    onDeleteSaved: (SavedRecordingSummary) -> Unit,
    onExport: () -> Unit
) {
    renderTick.hashCode()
    val context = LocalContext.current
    val discoveredScales = bluetooth.discoveredScales()
    val savedRecordings = savedRecordingStore.recordings()
    var selectedMode by remember { mutableStateOf(RecordingMode.SHOT) }
    var selectedScaleAddress by remember { mutableStateOf<String?>(bluetooth.connectedDevice()?.address) }
    var showRecordingTimer by remember { mutableStateOf(false) }
    var showRecordingResults by remember { mutableStateOf(false) }
    var selectedSavedDetails by remember { mutableStateOf<SavedRecordingDetails?>(null) }
    val selectedOrConnectedScale = selectedScaleAddress ?: bluetooth.connectedDevice()?.address
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) {
            bluetooth.startScanning()
        }
    }

    Scaffold(
        topBar = {
            @OptIn(ExperimentalMaterial3Api::class)
            TopAppBar(
                title = { Text("ScaleBench", fontWeight = FontWeight.SemiBold) }
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
                    onScan = {
                        if (hasBluetoothPermissions(context)) {
                            bluetooth.startScanning()
                        } else {
                            permissionLauncher.launch(bluetoothPermissions())
                        }
                    },
                    onStopScan = bluetooth::stopScanning
                )
            }

            item {
                ScalesSection(
                    scales = discoveredScales,
                    connectedAddress = selectedOrConnectedScale,
                    isScanning = bluetooth.isScanning,
                    onConnect = { scale ->
                        selectedScaleAddress = scale.address
                        bluetooth.connect(scale)
                    }
                )
            }

            item {
                RecordingSection(
                    bluetooth = bluetooth,
                    canRecord = selectedOrConnectedScale != null,
                    selectedMode = selectedMode,
                    onModeChanged = { selectedMode = it },
                    onRecord = {
                        if (!bluetooth.isRecording) {
                            bluetooth.startRecording(selectedMode)
                        }
                        showRecordingTimer = true
                    },
                    onTare = bluetooth::sendAtomicTareAndStart,
                    onSave = onSave,
                    onExport = onExport
                )
            }

            if (selectedOrConnectedScale != null) {
                item {
                    LiveSection(bluetooth = bluetooth)
                }
            }

            if (bluetooth.currentRecording().samples.size >= 2 || bluetooth.currentRecording().rawPackets.size >= 2) {
                item {
                    VisualizerSection(recording = bluetooth.currentRecording())
                }
            }

            item {
                SavedRecordingsSection(
                    recordings = savedRecordings,
                    onDeleteSaved = onDeleteSaved,
                    onOpenSaved = { saved ->
                        selectedSavedDetails = readSavedRecordingDetails(savedRecordingStore, saved)
                    }
                )
            }

            item {
                ScorecardSection(recording = bluetooth.currentRecording(), metrics = bluetooth.currentMetrics())
            }
        }

        if (showRecordingTimer && bluetooth.isRecording) {
            RecordingTimerDialog(
                bluetooth = bluetooth,
                onStop = {
                    bluetooth.stopRecording()
                    showRecordingTimer = false
                    showRecordingResults = true
                }
            )
        }

        if (showRecordingResults && !bluetooth.isRecording) {
            RecordingResultsDialog(
                recording = bluetooth.currentRecording(),
                metrics = bluetooth.currentMetrics(),
                onDismiss = { showRecordingResults = false },
                onSave = onSave,
                onExport = onExport
            )
        }

        if (selectedSavedDetails != null) {
            SavedRecordingDetailsDialog(
                details = selectedSavedDetails!!,
                onDismiss = { selectedSavedDetails = null }
            )
        }
    }
}

@Composable
private fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
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
private fun BluetoothSection(
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
                Text(if (bluetooth.connectedDevice() == null) "Bluetooth scale" else bluetooth.connectedDevice().name)
                Text(
                    bluetooth.status(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(12.dp))
            Button(onClick = { if (bluetooth.isScanning) onStopScan() else onScan() }) {
                Text(if (bluetooth.isScanning) "Stop" else "Scan")
            }
        }
    }
}

@Composable
private fun ScalesSection(
    scales: List<DiscoveredScale>,
    connectedAddress: String?,
    isScanning: Boolean,
    onConnect: (DiscoveredScale) -> Unit
) {
    SectionCard("Scales") {
        if (scales.isEmpty()) {
            Text("No scales yet", fontWeight = FontWeight.SemiBold)
            Text(
                if (isScanning) "Scanning. Power on a supported Bluetooth scale." else "Start scanning and power on a supported Bluetooth scale.",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
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
private fun RecordingSection(
    bluetooth: BluetoothScaleManager,
    canRecord: Boolean,
    selectedMode: RecordingMode,
    onModeChanged: (RecordingMode) -> Unit,
    onRecord: () -> Unit,
    onTare: () -> Unit,
    onSave: () -> Unit,
    onExport: () -> Unit
) {
    val hasRecordingData = bluetooth.currentRecording().samples.isNotEmpty()
            || bluetooth.currentRecording().rawPackets.isNotEmpty()
    SectionCard("Recording") {
        Text("How to use ScaleBench", fontWeight = FontWeight.SemiBold)
        Text(
            "Connect a scale, choose what you are testing, start recording, then stop and save/export.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

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

        Text(modeHelp(selectedMode), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            if (!canRecord) {
                "Connect a scale first to enable recording."
            } else if (bluetooth.isRecording) {
                "Recording is active. Open the timer to stop and review."
            } else {
                "Ready. Start Recording opens the timer screen."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
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
            OutlinedButton(onClick = onSave, enabled = !bluetooth.isRecording && hasRecordingData) {
                Text("Save Recording")
            }
            OutlinedButton(onClick = onExport, enabled = hasRecordingData) {
                Text("Export JSON")
            }
        }
    }
}

@Composable
private fun RecordingTimerDialog(
    bluetooth: BluetoothScaleManager,
    onStop: () -> Unit
) {
    var timerTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(bluetooth.isRecording) {
        while (bluetooth.isRecording) {
            delay(1000)
            timerTick++
        }
    }
    timerTick.hashCode()

    val recording = bluetooth.currentRecording()
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
                Text(recording.mode.displayName, color = MaterialTheme.colorScheme.onSurfaceVariant)
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                SwiftMetricRow("Samples", recording.samples.size.toString())
                SwiftMetricRow("Packets", recording.rawPackets.size.toString())
                SwiftMetricRow("Weight", sample?.weightGrams?.let { String.format(Locale.US, "%.2f g", it) } ?: "--")
                SwiftMetricRow("Flow", sample?.flowGramsPerSecond?.let { String.format(Locale.US, "%.2f g/s", it) } ?: "--")
                SwiftMetricRow("Battery", sample?.batteryPercent?.let { "$it%" } ?: bluetooth.latestBatteryPercent()?.let { "$it%" } ?: "--")
            }
        },
        confirmButton = {
            Button(onClick = onStop) {
                Text("Stop and View Results")
            }
        }
    )
}

@Composable
private fun RecordingResultsDialog(
    recording: ScaleRecording,
    metrics: ScaleQualityMetrics,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
    onExport: () -> Unit
) {
    val hasRecordingData = recording.samples.isNotEmpty() || recording.rawPackets.isNotEmpty()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Recording Results") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(recording.defaultTitle(), fontWeight = FontWeight.SemiBold)
                if (!hasRecordingData) {
                    Text(
                        "No packets were captured. If the scale is connected, start recording again and leave this open while weight updates arrive.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                SwiftMetricRow("Overall", metrics.overallScore?.let { "$it/100" } ?: "--")
                SwiftMetricRow("Transport", metrics.transportScore?.let { "$it/100" } ?: "--")
                SwiftMetricRow("Stability", metrics.stabilityScore?.let { "$it/100" } ?: "--")
                SwiftMetricRow("Samples", recording.samples.size.toString())
                SwiftMetricRow("Raw packets", recording.rawPackets.size.toString())
                SwiftMetricRow("Effective rate", metrics.effectiveSampleRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
                SwiftMetricRow("Interval p95", metrics.packetIntervalP95Milliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
                SwiftMetricRow("Max gap", metrics.packetIntervalMaxMilliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
                SwiftMetricRow("Long gaps", metrics.longGapCount.toString())
                SwiftMetricRow("Missing seq", metrics.missingSequenceCount.toString())
                SwiftMetricRow("Rejected", metrics.rejectedPacketCount.toString())
                SwiftMetricRow("Idle noise", metrics.idleNoisePeakToPeakGrams?.let { String.format(Locale.US, "%.2f g p-p", it) } ?: "--")
                SwiftMetricRow("Drift", metrics.driftGramsPerMinute?.let { String.format(Locale.US, "%.3f g/min", it) } ?: "--")
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                ScoreDeductionsRows(scoreDeductions(recording, metrics), "No weighted score deductions for this recording.")
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = {
                            onSave()
                            onDismiss()
                        },
                        enabled = hasRecordingData
                    ) {
                        Text("Save Recording")
                    }
                    OutlinedButton(onClick = onExport, enabled = hasRecordingData) {
                        Text("Export JSON")
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

@Composable
private fun LiveSection(bluetooth: BluetoothScaleManager) {
    val sample = bluetooth.latestSample()
    SectionCard("Live") {
        SwiftMetricRow("Weight", sample?.weightGrams?.let { String.format(Locale.US, "%.2f g", it) } ?: "--")
        SwiftMetricRow("Flow", sample?.flowGramsPerSecond?.let { String.format(Locale.US, "%.2f g/s", it) } ?: "--")
        SwiftMetricRow("Battery", sample?.batteryPercent?.let { "$it%" } ?: bluetooth.latestBatteryPercent()?.let { "$it%" } ?: "--")
        SwiftMetricRow("Protocol", sample?.scaleKind?.displayName ?: bluetooth.connectedDevice()?.kind?.displayName ?: "Unknown")
        SwiftMetricRow("Packets", bluetooth.currentRecording().rawPackets.size.toString())
        SwiftMetricRow("Samples", bluetooth.currentRecording().samples.size.toString())
    }
}

@Composable
private fun VisualizerSection(recording: ScaleRecording) {
    SectionCard("Visualizer") {
        Text("Weight stream", fontWeight = FontWeight.SemiBold)
        WeightStreamChart(recording = recording)
        Text("Packet cadence", fontWeight = FontWeight.SemiBold)
        PacketCadenceChart(recording = recording)
    }
}

@Composable
private fun WeightStreamChart(recording: ScaleRecording) {
    val points = recording.samples.map { ChartPoint(it.monotonicSeconds, it.weightGrams) }
    ChartWeightStream(points = points, thresholdMs = recording.scoringProfile.minimumLongGapMilliseconds)
}

@Composable
private fun ChartWeightStream(points: List<ChartPoint>, thresholdMs: Double) {
    if (points.size < 2) {
        EmptyChart("Record at least two samples to show weight.")
        return
    }

    val primary = MaterialTheme.colorScheme.primary
    val warning = MaterialTheme.colorScheme.error
    val grid = MaterialTheme.colorScheme.surfaceVariant
    val text = MaterialTheme.colorScheme.onSurfaceVariant
    val minT = points.first().seconds
    val maxT = points.last().seconds
    val minWeight = points.minOf { it.value }
    val maxWeight = points.maxOf { it.value }
    val yPad = max(0.05, (maxWeight - minWeight) * 0.08)
    val minY = minWeight - yPad
    val maxY = maxWeight + yPad

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(180.dp)
    ) {
        drawRect(color = grid.copy(alpha = 0.35f), size = size)
        val chartLeft = 10f
        val chartTop = 10f
        val chartWidth = size.width - 20f
        val chartHeight = size.height - 20f

        fun x(seconds: Double): Float {
            val span = max(0.001, maxT - minT)
            return chartLeft + (((seconds - minT) / span).toFloat() * chartWidth)
        }

        fun y(weight: Double): Float {
            val span = max(0.001, maxY - minY)
            return chartTop + chartHeight - (((weight - minY) / span).toFloat() * chartHeight)
        }

        points.zipWithNext().forEach { (a, b) ->
            val intervalMs = (b.seconds - a.seconds) * 1000.0
            if (intervalMs >= thresholdMs) {
                val start = x(a.seconds)
                val end = x(b.seconds)
                drawRect(
                    color = warning.copy(alpha = 0.18f),
                    topLeft = Offset(start, chartTop),
                    size = Size(max(2f, end - start), chartHeight)
                )
            }
        }

        val path = Path()
        points.forEachIndexed { index, point ->
            val px = x(point.seconds)
            val py = y(point.value)
            if (index == 0) path.moveTo(px, py) else path.lineTo(px, py)
        }
        drawPath(path, color = primary, style = Stroke(width = 4f))
        drawLine(color = text.copy(alpha = 0.45f), start = Offset(chartLeft, chartTop + chartHeight), end = Offset(chartLeft + chartWidth, chartTop + chartHeight), strokeWidth = 1f)
    }
}

@Composable
private fun PacketCadenceChart(recording: ScaleRecording) {
    val intervals = recording.rawPackets.zipWithNext().map { (a, b) ->
        ((b.monotonicSeconds - a.monotonicSeconds) * 1000.0).coerceAtLeast(0.0)
    }
    val rejectedIndexes = recording.rawPackets.mapIndexedNotNull { index, packet ->
        if (packet.rejectionReason != null) index else null
    }.toSet()
    ChartPacketCadence(
        intervals = intervals,
        rejectedIndexes = rejectedIndexes,
        packetCount = recording.rawPackets.size,
        thresholdMs = recording.scoringProfile.minimumLongGapMilliseconds
    )
}

@Composable
private fun ChartPacketCadence(
    intervals: List<Double>,
    rejectedIndexes: Set<Int>,
    packetCount: Int,
    thresholdMs: Double
) {
    if (intervals.isEmpty()) {
        EmptyChart("Record at least two packets to show cadence.")
        return
    }

    val primary = MaterialTheme.colorScheme.tertiary
    val warning = MaterialTheme.colorScheme.error
    val grid = MaterialTheme.colorScheme.surfaceVariant
    val text = MaterialTheme.colorScheme.onSurfaceVariant
    val maxInterval = max(thresholdMs * 1.25, intervals.maxOrNull() ?: thresholdMs)

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(150.dp)
    ) {
        drawRect(color = grid.copy(alpha = 0.35f), size = size)
        val chartLeft = 10f
        val chartTop = 10f
        val chartWidth = size.width - 20f
        val chartHeight = size.height - 20f
        val barWidth = max(2f, chartWidth / intervals.size.toFloat())

        intervals.forEachIndexed { index, interval ->
            val x = chartLeft + index * barWidth
            val height = ((interval / maxInterval).toFloat() * chartHeight).coerceIn(1f, chartHeight)
            drawRect(
                color = if (interval >= thresholdMs) warning else primary,
                topLeft = Offset(x, chartTop + chartHeight - height),
                size = Size(max(1f, barWidth - 1f), height)
            )
        }

        rejectedIndexes.forEach { index ->
            if (packetCount > 1) {
                val x = chartLeft + (index.toFloat() / max(1, packetCount - 1).toFloat()) * chartWidth
                drawLine(color = warning, start = Offset(x, chartTop), end = Offset(x, chartTop + chartHeight), strokeWidth = 2f)
            }
        }

        val thresholdY = chartTop + chartHeight - ((thresholdMs / maxInterval).toFloat() * chartHeight)
        drawLine(color = text.copy(alpha = 0.5f), start = Offset(chartLeft, thresholdY), end = Offset(chartLeft + chartWidth, thresholdY), strokeWidth = 1f)
    }
}

private data class ChartPoint(val seconds: Double, val value: Double)

@Composable
private fun EmptyChart(message: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(110.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ScorecardSection(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    SectionCard("Scorecard") {
        SwiftMetricRow("Scoring", recording.scoringProfile.name)
        SwiftMetricRow("Benchmark", "Standard v1")
        SwiftMetricRow("Overall", metrics.overallScore?.let { "$it/100" } ?: "--")
        SwiftMetricRow("Transport", metrics.transportScore?.let { "$it/100" } ?: "--")
        SwiftMetricRow("Stability", metrics.stabilityScore?.let { "$it/100" } ?: "--")
        SwiftMetricRow("Effective rate", metrics.effectiveSampleRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
        SwiftMetricRow("Interval p95", metrics.packetIntervalP95Milliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
        SwiftMetricRow("Max gap", metrics.packetIntervalMaxMilliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
        SwiftMetricRow("Long gaps", metrics.longGapCount.toString())
        SwiftMetricRow("Missing seq", metrics.missingSequenceCount.toString())
        SwiftMetricRow("Rejected", metrics.rejectedPacketCount.toString())
        SwiftMetricRow("Idle noise", metrics.idleNoisePeakToPeakGrams?.let { String.format(Locale.US, "%.2f g p-p", it) } ?: "--")
        SwiftMetricRow("Drift", metrics.driftGramsPerMinute?.let { String.format(Locale.US, "%.3f g/min", it) } ?: "--")
        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
        ScoreDeductionsRows(scoreDeductions(recording, metrics), "No weighted score deductions.")
    }
}

@Composable
private fun ScoreDeductionsRows(deductions: List<ScoreDeduction>, emptyText: String) {
    Text("Why points were deducted", fontWeight = FontWeight.SemiBold)
    if (deductions.isEmpty()) {
        Text(emptyText, color = MaterialTheme.colorScheme.onSurfaceVariant)
    } else {
        Text(
            "Score starts at 100. These are weighted deductions.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        deductions.forEach { deduction ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(deduction.title, fontWeight = FontWeight.SemiBold)
                    Text(String.format(Locale.US, "-%.1f pts", deduction.points), color = MaterialTheme.colorScheme.error)
                }
                Text(
                    "Subscore ${deduction.subscore}/100 · ${deduction.detail}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun SavedRecordingsSection(
    recordings: List<SavedRecordingSummary>,
    onDeleteSaved: (SavedRecordingSummary) -> Unit,
    onOpenSaved: (SavedRecordingSummary) -> Unit = {}
) {
    SectionCard("Saved recordings") {
        if (recordings.isEmpty()) {
            Text("No saved recordings", fontWeight = FontWeight.SemiBold)
            Text(
                "Saved recordings keep raw packets, score snapshot, and mode.",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            recordings.forEachIndexed { index, saved ->
                SavedRecordingInlineRow(
                    summary = saved,
                    onOpen = { onOpenSaved(saved) },
                    onDelete = { onDeleteSaved(saved) }
                )
                if (index < recordings.lastIndex) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            }
        }
    }
}

@Composable
private fun ScaleListRow(scale: DiscoveredScale, isConnected: Boolean, onConnect: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(scale.name, fontWeight = FontWeight.SemiBold)
            Text(
                "${scale.kind.displayName} · RSSI ${scale.rssi}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(Modifier.width(12.dp))
        if (isConnected) {
            Text("Connected", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
        } else {
            TextButton(onClick = onConnect) {
                Text("Connect")
            }
        }
    }
}

@Composable
private fun SwiftMetricRow(title: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(16.dp))
        Text(value, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun SavedRecordingInlineRow(summary: SavedRecordingSummary, onOpen: () -> Unit, onDelete: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(summary.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "${summary.protocolKind.displayName} · ${summary.mode.displayName}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                "${summary.sampleCount} samples · ${summary.rawPacketCount} packets",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(horizontalAlignment = Alignment.End) {
            Text(summary.score?.toString() ?: "--", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            TextButton(onClick = onOpen) {
                Text("Open")
            }
            TextButton(onClick = onDelete) {
                Text("Delete")
            }
        }
    }
}

@Composable
private fun SavedRecordingDetailsDialog(details: SavedRecordingDetails, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(details.title) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${details.protocol} · ${details.mode}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SwiftMetricRow("Started", details.started)
                        SwiftMetricRow("Duration", details.duration)
                        SwiftMetricRow("Samples", details.sampleCount.toString())
                        SwiftMetricRow("Raw packets", details.rawPacketCount.toString())
                        SwiftMetricRow("Battery events", details.batteryEventCount.toString())
                    }
                }
                item {
                    HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                }
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Scorecard", fontWeight = FontWeight.SemiBold)
                        SwiftMetricRow("Overall", details.overallScore)
                        SwiftMetricRow("Transport", details.transportScore)
                        SwiftMetricRow("Stability", details.stabilityScore)
                        SwiftMetricRow("Metadata", details.metadataScore)
                        SwiftMetricRow("Effective rate", details.effectiveRate)
                        SwiftMetricRow("Interval p50", details.intervalP50)
                        SwiftMetricRow("Interval p95", details.intervalP95)
                        SwiftMetricRow("Max gap", details.maxGap)
                        SwiftMetricRow("Long gaps", details.longGaps)
                        SwiftMetricRow("Missing seq", details.missingSeq)
                        SwiftMetricRow("Rejected", details.rejected)
                        SwiftMetricRow("Idle noise", details.idleNoise)
                        SwiftMetricRow("Idle std dev", details.idleStdDev)
                        SwiftMetricRow("Drift", details.drift)
                        ScoreDeductionsRows(details.deductions, "No weighted score deductions for this saved recording.")
                    }
                }
                item {
                    HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                }
                if (details.samplePoints.size >= 2 || details.packetIntervals.isNotEmpty()) {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Visualizer", fontWeight = FontWeight.SemiBold)
                            Text("Weight stream", fontWeight = FontWeight.SemiBold)
                            ChartWeightStream(points = details.samplePoints, thresholdMs = details.longGapThresholdMs)
                            Text("Packet cadence", fontWeight = FontWeight.SemiBold)
                            ChartPacketCadence(
                                intervals = details.packetIntervals,
                                rejectedIndexes = details.rejectedPacketIndexes,
                                packetCount = details.rawPacketCount,
                                thresholdMs = details.longGapThresholdMs
                            )
                        }
                    }
                    item {
                        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                    }
                }
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Samples", fontWeight = FontWeight.SemiBold)
                        SwiftMetricRow("First weight", details.firstWeight)
                        SwiftMetricRow("Last weight", details.lastWeight)
                        SwiftMetricRow("Min battery", details.batteryMin)
                        SwiftMetricRow("Max battery", details.batteryMax)
                    }
                }
                if (details.rawPreview.isNotEmpty()) {
                    item {
                        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                    }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Raw packet preview", fontWeight = FontWeight.SemiBold)
                            details.rawPreview.forEach { packet ->
                                Text(packet, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
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

private data class SavedRecordingDetails(
    val title: String,
    val protocol: String,
    val mode: String,
    val started: String,
    val duration: String,
    val sampleCount: Int,
    val rawPacketCount: Int,
    val batteryEventCount: Int,
    val overallScore: String,
    val transportScore: String,
    val stabilityScore: String,
    val metadataScore: String,
    val effectiveRate: String,
    val intervalP50: String,
    val intervalP95: String,
    val maxGap: String,
    val longGaps: String,
    val missingSeq: String,
    val rejected: String,
    val idleNoise: String,
    val idleStdDev: String,
    val drift: String,
    val firstWeight: String,
    val lastWeight: String,
    val batteryMin: String,
    val batteryMax: String,
    val longGapThresholdMs: Double,
    val samplePoints: List<ChartPoint>,
    val packetIntervals: List<Double>,
    val rejectedPacketIndexes: Set<Int>,
    val deductions: List<ScoreDeduction>,
    val rawPreview: List<String>
)

private fun readSavedRecordingDetails(store: SavedRecordingStore, summary: SavedRecordingSummary): SavedRecordingDetails {
    return try {
        val objectJson = store.recordingObject(summary)
        val metrics = objectJson.optJSONObject("metrics") ?: JSONObject()
        val samples = objectJson.optJSONArray("samples")
        val packets = objectJson.optJSONArray("rawPackets")
        val batteryEvents = objectJson.optJSONArray("batteryEvents")
        val firstSample = samples?.optJSONObject(0)
        val lastSample = samples?.optJSONObject((samples.length() - 1).coerceAtLeast(0))
        val started = objectJson.optLong("startedAtMillis", 0L)
        val ended = objectJson.optLong("endedAtMillis", started)
        SavedRecordingDetails(
            title = summary.title,
            protocol = summary.protocolKind.displayName,
            mode = summary.mode.displayName,
            started = if (started > 0) java.text.DateFormat.getDateTimeInstance().format(java.util.Date(started)) else "--",
            duration = if (ended >= started) formatDuration(ended - started) else "--",
            sampleCount = samples?.length() ?: summary.sampleCount,
            rawPacketCount = packets?.length() ?: summary.rawPacketCount,
            batteryEventCount = batteryEvents?.length() ?: 0,
            overallScore = score(metrics, "overallScore"),
            transportScore = score(metrics, "transportScore"),
            stabilityScore = score(metrics, "stabilityScore"),
            metadataScore = score(metrics, "metadataScore"),
            effectiveRate = number(metrics, "effectiveSampleRateHz", "%.1f Hz"),
            intervalP50 = number(metrics, "packetIntervalP50Milliseconds", "%.0f ms"),
            intervalP95 = number(metrics, "packetIntervalP95Milliseconds", "%.0f ms"),
            maxGap = number(metrics, "packetIntervalMaxMilliseconds", "%.0f ms"),
            longGaps = metrics.optInt("longGapCount", 0).toString(),
            missingSeq = metrics.optInt("missingSequenceCount", 0).toString(),
            rejected = metrics.optInt("rejectedPacketCount", 0).toString(),
            idleNoise = number(metrics, "idleNoisePeakToPeakGrams", "%.2f g p-p"),
            idleStdDev = number(metrics, "idleNoiseStandardDeviationGrams", "%.3f g"),
            drift = number(metrics, "driftGramsPerMinute", "%.3f g/min"),
            firstWeight = weight(firstSample),
            lastWeight = weight(lastSample),
            batteryMin = number(metrics, "batteryMinPercent", "%.0f%%"),
            batteryMax = number(metrics, "batteryMaxPercent", "%.0f%%"),
            longGapThresholdMs = objectJson.optJSONObject("scoringProfile")
                ?.optDouble("minimumLongGapMilliseconds", 300.0) ?: 300.0,
            samplePoints = samplePoints(samples),
            packetIntervals = packetIntervals(packets),
            rejectedPacketIndexes = rejectedPacketIndexes(packets),
            deductions = scoreDeductionsFromJson(summary.mode, metrics, samples, batteryEvents),
            rawPreview = rawPreview(packets)
        )
    } catch (error: Exception) {
        SavedRecordingDetails(
            title = summary.title,
            protocol = summary.protocolKind.displayName,
            mode = summary.mode.displayName,
            started = "--",
            duration = "--",
            sampleCount = summary.sampleCount,
            rawPacketCount = summary.rawPacketCount,
            batteryEventCount = 0,
            overallScore = summary.score?.let { "$it/100" } ?: "--",
            transportScore = "--",
            stabilityScore = "--",
            metadataScore = "--",
            effectiveRate = "--",
            intervalP50 = "--",
            intervalP95 = "--",
            maxGap = "--",
            longGaps = "--",
            missingSeq = "--",
            rejected = "--",
            idleNoise = "--",
            idleStdDev = "--",
            drift = "--",
            firstWeight = "--",
            lastWeight = "--",
            batteryMin = "--",
            batteryMax = "--",
            longGapThresholdMs = 300.0,
            samplePoints = emptyList(),
            packetIntervals = emptyList(),
            rejectedPacketIndexes = emptySet(),
            deductions = emptyList(),
            rawPreview = listOf("Could not open saved JSON: ${error.message ?: "unknown error"}")
        )
    }
}

private data class ScoreDeduction(
    val title: String,
    val points: Double,
    val subscore: Int,
    val detail: String
)

private fun scoreDeductions(recording: ScaleRecording, metrics: ScaleQualityMetrics): List<ScoreDeduction> {
    val profile = recording.scoringProfile.normalized()
    val rows = mutableListOf<ScoreDeduction>()
    metrics.transportScore?.let { score ->
        val points = (100 - score) * profile.transportWeight
        if (points > 0.05) rows += ScoreDeduction("Transport", points, score, transportDeductionDetail(metrics))
    }
    metrics.stabilityScore?.let { score ->
        val points = (100 - score) * profile.stabilityWeight
        if (points > 0.05) rows += ScoreDeduction("Stability", points, score, stabilityDeductionDetail(recording.mode, metrics))
    }
    metrics.metadataScore?.let { score ->
        val points = (100 - score) * profile.metadataWeight
        if (points > 0.05) rows += ScoreDeduction("Metadata", points, score, metadataDeductionDetail(recording.samples, recording.batteryEvents.isNotEmpty()))
    }
    return rows
}

private fun scoreDeductionsFromJson(
    mode: RecordingMode,
    metrics: JSONObject,
    samples: org.json.JSONArray?,
    batteryEvents: org.json.JSONArray?
): List<ScoreDeduction> {
    val profile = ScoringProfile.standard().normalized()
    val rows = mutableListOf<ScoreDeduction>()
    if (!metrics.isNull("transportScore")) {
        val score = metrics.optInt("transportScore")
        val points = (100 - score) * profile.transportWeight
        if (points > 0.05) rows += ScoreDeduction("Transport", points, score, transportDeductionDetail(metrics))
    }
    if (!metrics.isNull("stabilityScore")) {
        val score = metrics.optInt("stabilityScore")
        val points = (100 - score) * profile.stabilityWeight
        if (points > 0.05) rows += ScoreDeduction("Stability", points, score, stabilityDeductionDetail(mode, metrics))
    }
    if (!metrics.isNull("metadataScore")) {
        val score = metrics.optInt("metadataScore")
        val points = (100 - score) * profile.metadataWeight
        if (points > 0.05) rows += ScoreDeduction("Metadata", points, score, metadataDeductionDetail(samples, batteryEvents))
    }
    return rows
}

private fun transportDeductionDetail(metrics: ScaleQualityMetrics): String {
    val parts = mutableListOf<String>()
    if (metrics.longGapCount > 0) parts += "${metrics.longGapCount} long gap${plural(metrics.longGapCount)}"
    if (metrics.missingSequenceCount > 0) parts += "${metrics.missingSequenceCount} missing sequence step${plural(metrics.missingSequenceCount)}"
    if (metrics.duplicateOrOutOfOrderTimestampCount > 0) parts += "${metrics.duplicateOrOutOfOrderTimestampCount} timestamp issue${plural(metrics.duplicateOrOutOfOrderTimestampCount)}"
    if (metrics.rejectedPacketCount > 0) parts += "${metrics.rejectedPacketCount} rejected packet${plural(metrics.rejectedPacketCount)}"
    return parts.ifEmpty { listOf("Transport subscore below 100.") }.joinToString(", ")
}

private fun transportDeductionDetail(metrics: JSONObject): String {
    val parts = mutableListOf<String>()
    val gaps = metrics.optInt("longGapCount", 0)
    val missing = metrics.optInt("missingSequenceCount", 0)
    val timestamp = metrics.optInt("duplicateOrOutOfOrderTimestampCount", 0)
    val rejected = metrics.optInt("rejectedPacketCount", 0)
    if (gaps > 0) parts += "$gaps long gap${plural(gaps)}"
    if (missing > 0) parts += "$missing missing sequence step${plural(missing)}"
    if (timestamp > 0) parts += "$timestamp timestamp issue${plural(timestamp)}"
    if (rejected > 0) parts += "$rejected rejected packet${plural(rejected)}"
    return parts.ifEmpty { listOf("Transport subscore below 100.") }.joinToString(", ")
}

private fun stabilityDeductionDetail(mode: RecordingMode, metrics: ScaleQualityMetrics): String {
    if (mode != RecordingMode.IDLE_STABILITY) {
        return if (metrics.firmwareBumpCount > 0) "${metrics.firmwareBumpCount} firmware bump flag${plural(metrics.firmwareBumpCount)}" else "Dynamic stability subscore below 100."
    }
    val parts = mutableListOf<String>()
    metrics.idleNoisePeakToPeakGrams?.let { parts += String.format(Locale.US, "idle noise %.3f g p-p", it) }
    metrics.driftGramsPerMinute?.let { parts += String.format(Locale.US, "drift %.3f g/min", it) }
    return parts.ifEmpty { listOf("Idle stability subscore below 100.") }.joinToString(", ")
}

private fun stabilityDeductionDetail(mode: RecordingMode, metrics: JSONObject): String {
    if (mode != RecordingMode.IDLE_STABILITY) {
        val bumps = metrics.optInt("firmwareBumpCount", 0)
        return if (bumps > 0) "$bumps firmware bump flag${plural(bumps)}" else "Dynamic stability subscore below 100."
    }
    val parts = mutableListOf<String>()
    if (!metrics.isNull("idleNoisePeakToPeakGrams")) parts += String.format(Locale.US, "idle noise %.3f g p-p", metrics.optDouble("idleNoisePeakToPeakGrams"))
    if (!metrics.isNull("driftGramsPerMinute")) parts += String.format(Locale.US, "drift %.3f g/min", metrics.optDouble("driftGramsPerMinute"))
    return parts.ifEmpty { listOf("Idle stability subscore below 100.") }.joinToString(", ")
}

private fun metadataDeductionDetail(samples: List<ScaleSample>, hasBatteryEvents: Boolean): String {
    val missing = mutableListOf<String>()
    if (samples.none { it.deviceTimestampMilliseconds != null }) missing += "device timestamps"
    if (!hasBatteryEvents && samples.none { it.batteryPercent != null }) missing += "battery"
    if (samples.none { it.flowGramsPerSecond != null }) missing += "flow"
    if (samples.none { it.firmwareQualityScore != null }) missing += "firmware quality"
    return if (missing.isEmpty()) "Metadata subscore below 100." else "Missing optional telemetry: ${missing.joinToString(", ")}."
}

private fun metadataDeductionDetail(samples: org.json.JSONArray?, batteryEvents: org.json.JSONArray?): String {
    val missing = mutableListOf<String>()
    val sampleObjects = (0 until (samples?.length() ?: 0)).mapNotNull { samples?.optJSONObject(it) }
    if (sampleObjects.none { it.has("deviceTimestampMilliseconds") && !it.isNull("deviceTimestampMilliseconds") }) missing += "device timestamps"
    val hasBattery = (batteryEvents?.length() ?: 0) > 0 || sampleObjects.any { it.has("batteryPercent") && !it.isNull("batteryPercent") }
    if (!hasBattery) missing += "battery"
    if (sampleObjects.none { it.has("flowGramsPerSecond") && !it.isNull("flowGramsPerSecond") }) missing += "flow"
    if (sampleObjects.none { it.has("firmwareQualityScore") && !it.isNull("firmwareQualityScore") }) missing += "firmware quality"
    return if (missing.isEmpty()) "Metadata subscore below 100." else "Missing optional telemetry: ${missing.joinToString(", ")}."
}

private fun plural(count: Int): String = if (count == 1) "" else "s"

private fun samplePoints(samples: org.json.JSONArray?): List<ChartPoint> {
    if (samples == null) return emptyList()
    return (0 until samples.length()).mapNotNull { index ->
        samples.optJSONObject(index)?.let { sample ->
            ChartPoint(sample.optDouble("monotonicSeconds"), sample.optDouble("weightGrams"))
        }
    }
}

private fun packetIntervals(packets: org.json.JSONArray?): List<Double> {
    if (packets == null || packets.length() < 2) return emptyList()
    val seconds = (0 until packets.length()).mapNotNull { index ->
        packets.optJSONObject(index)?.optDouble("monotonicSeconds")
    }
    return seconds.zipWithNext().map { (a, b) -> ((b - a) * 1000.0).coerceAtLeast(0.0) }
}

private fun rejectedPacketIndexes(packets: org.json.JSONArray?): Set<Int> {
    if (packets == null) return emptySet()
    return (0 until packets.length()).mapNotNull { index ->
        val packet = packets.optJSONObject(index)
        if (packet != null && packet.has("rejectionReason")) index else null
    }.toSet()
}

private fun score(metrics: JSONObject, key: String): String {
    return if (metrics.isNull(key)) "--" else "${metrics.optInt(key)}/100"
}

private fun number(metrics: JSONObject, key: String, format: String): String {
    return if (metrics.isNull(key)) "--" else String.format(Locale.US, format, metrics.optDouble(key))
}

private fun weight(sample: JSONObject?): String {
    return sample?.let { String.format(Locale.US, "%.2f g", it.optDouble("weightGrams")) } ?: "--"
}

private fun rawPreview(packets: org.json.JSONArray?): List<String> {
    if (packets == null) return emptyList()
    val count = minOf(packets.length(), 5)
    return (0 until count).mapNotNull { index ->
        packets.optJSONObject(index)?.let { packet ->
            val role = packet.optString("role", "UNKNOWN")
            val uuid = packet.optString("characteristicUUID", "--")
            val bytes = packet.optString("bytesHex", "")
            "$role · $uuid · ${bytes.take(48)}"
        }
    }
}

private fun modeHelp(mode: RecordingMode): String {
    return when (mode) {
        RecordingMode.IDLE_STABILITY -> "Measure idle noise and drift while the scale is still."
        RecordingMode.SHOT -> "Use for espresso shots or pours where beverage weight rises normally."
        RecordingMode.TARE_LATENCY -> "Measure how quickly the scale responds around tare events."
        RecordingMode.TRANSPORT_STRESS -> "Stress test packet cadence, gaps, and rejected packets."
        RecordingMode.BATTERY_STABILITY -> "Log battery reporting over a longer session."
    }
}

private fun formatDuration(milliseconds: Long): String {
    val totalSeconds = milliseconds / 1000
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return String.format(Locale.US, "%d:%02d", minutes, seconds)
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun ControlsCard(
    bluetooth: BluetoothScaleManager,
    discoveredScales: List<DiscoveredScale>,
    selectedMode: RecordingMode,
    onModeChanged: (RecordingMode) -> Unit,
    onScan: () -> Unit,
    onStopScan: () -> Unit,
    onRecord: () -> Unit,
    onTare: () -> Unit,
    onSave: () -> Unit,
    onExport: () -> Unit
) {
    Card(
        shape = RoundedCornerShape(8.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Live weight", style = MaterialTheme.typography.labelLarge)
                    val sample = bluetooth.latestSample()
                    Text(
                        sample?.weightGrams?.let { String.format(Locale.US, "%.2f g", it) } ?: "--",
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        bluetooth.connectedDevice()?.name ?: "No scale connected",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text(bluetooth.latestSample()?.scaleKind?.displayName ?: "Waiting")
                    Text(
                        bluetooth.latestBatteryPercent()?.let { "Battery $it%" } ?: "Battery --",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Scale", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(
                            if (bluetooth.connectedDevice() != null) "Connected" else bluetooth.status(),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    Button(onClick = { if (bluetooth.isScanning) onStopScan() else onScan() }) {
                        Text(if (bluetooth.isScanning) "Stop Scan" else "Scan")
                    }
                }

                if (bluetooth.connectedDevice() == null) {
                    if (discoveredScales.isEmpty()) {
                        Text(
                            if (bluetooth.isScanning) "Looking for supported scales" else "No scale selected",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    } else {
                        discoveredScales.forEach { scale ->
                            ScaleChoiceRow(scale = scale, onConnect = { bluetooth.connect(scale) })
                        }
                    }
                }
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)

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

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilledTonalButton(onClick = onRecord, enabled = bluetooth.connectedDevice() != null || bluetooth.isRecording) {
                    Text(if (bluetooth.isRecording) "Stop Recording" else "Record")
                }
                OutlinedButton(onClick = onTare, enabled = bluetooth.connectedDevice() != null) {
                    Text("Tare + Start")
                }
                val hasRecordingData = bluetooth.currentRecording().samples.isNotEmpty()
                        || bluetooth.currentRecording().rawPackets.isNotEmpty()
                OutlinedButton(onClick = onSave, enabled = hasRecordingData) {
                    Text("Save")
                }
                OutlinedButton(onClick = onExport, enabled = hasRecordingData) {
                    Text("Export JSON")
                }
            }
        }
    }
}

@Composable
private fun ScaleChoiceRow(scale: DiscoveredScale, onConnect: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(scale.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "${scale.kind.displayName}  RSSI ${scale.rssi}",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Spacer(Modifier.width(12.dp))
        Button(onClick = onConnect) {
            Text("Connect")
        }
    }
}

@Composable
private fun ReadingCard(bluetooth: BluetoothScaleManager) {
    OutlinedCard(shape = RoundedCornerShape(8.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text("Live weight", style = MaterialTheme.typography.labelLarge)
                val sample = bluetooth.latestSample()
                Text(
                    sample?.weightGrams?.let { String.format(Locale.US, "%.2f g", it) } ?: "--",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(bluetooth.latestSample()?.scaleKind?.displayName ?: "No sample")
                Text(
                    bluetooth.latestBatteryPercent()?.let { "Battery $it%" } ?: "Battery --",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MetricsCard(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    Card(shape = RoundedCornerShape(8.dp)) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text("Score", style = MaterialTheme.typography.labelLarge)
                    Text(
                        metrics.overallScore?.toString() ?: "--",
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.Bold
                    )
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text("${recording.samples.size} samples")
                    Text("${recording.rawPackets.size} raw packets")
                }
            }

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                MetricChip("Rate", metrics.effectiveSampleRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--")
                MetricChip("P95", metrics.packetIntervalP95Milliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
                MetricChip("Gaps", metrics.longGapCount.toString())
                MetricChip("Rejected", metrics.rejectedPacketCount.toString())
            }
        }
    }
}

@Composable
private fun MetricChip(label: String, value: String) {
    AssistChip(onClick = {}, label = { Text("$label $value") })
}

@Composable
private fun EmptyScalesCard(isScanning: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            if (isScanning) "Scanning for supported scales..." else "No supported scales found yet",
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ScaleRow(scale: DiscoveredScale, onConnect: () -> Unit) {
    OutlinedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        onClick = onConnect
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(scale.name, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(2.dp))
                Text(
                    scale.kind.displayName,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(12.dp))
            Text("RSSI ${scale.rssi}", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SavedRecordingsHeader(count: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            "Saved recordings",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            count.toString(),
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun EmptySavedRecordingsCard() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp),
        contentAlignment = Alignment.Center
    ) {
        Text("No saved recordings yet", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SavedRecordingRow(summary: SavedRecordingSummary, onDelete: () -> Unit) {
    OutlinedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(summary.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(3.dp))
                Text(
                    "${summary.protocolKind.displayName}  ${summary.mode.displayName}",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    "${summary.sampleCount} samples  ${summary.rawPacketCount} packets",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(summary.score?.toString() ?: "--", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                TextButton(onClick = onDelete) {
                    Text("Delete")
                }
            }
        }
    }
}

private fun bluetoothPermissions(): Array<String> {
    return if (Build.VERSION.SDK_INT >= 31) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }
}

private fun hasBluetoothPermissions(context: Context): Boolean {
    return bluetoothPermissions().all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
}
