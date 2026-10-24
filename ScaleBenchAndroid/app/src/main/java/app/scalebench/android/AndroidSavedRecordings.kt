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
import androidx.compose.ui.window.DialogProperties
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.delay
import org.json.JSONObject
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper

internal enum class RecordingLibraryMode(val label: String) {
    DATE("Date"),
    SCORE("Score"),
    PROTOCOL("Protocol"),
    MODE("Mode")
}

internal data class RecordingLibraryGroup(
    val id: String,
    val title: String,
    val recordings: List<SavedRecordingSummary>
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SavedRecordingsSection(
    recordings: List<SavedRecordingSummary>,
    libraryWarning: String?,
    onLoadExamples: () -> Unit,
    onImportRecording: () -> Unit,
    onDeleteSaved: (SavedRecordingSummary) -> Unit,
    onOpenSaved: (SavedRecordingSummary) -> Unit = {}
) {
    var pendingDelete by remember { mutableStateOf<SavedRecordingSummary?>(null) }
    var libraryMode by remember { mutableStateOf(RecordingLibraryMode.DATE) }
    val comparison = AndroidProtocolComparison.from(recordings)
    SectionCard("Recordings") {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("${recordings.size} saved", fontWeight = FontWeight.SemiBold)
                Text(
                    "Tap a recording to inspect score, charts, packets, and export.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(Modifier.width(12.dp))
            if (recordings.isNotEmpty()) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(onClick = onImportRecording) {
                        Text("Import JSON")
                    }
                    OutlinedButton(onClick = onLoadExamples) {
                        Text("Add examples")
                    }
                }
            }
        }

        if (!libraryWarning.isNullOrBlank()) {
            Text(
                "Library warning: $libraryWarning",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error
            )
        }

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            RecordingLibraryMode.values().forEach { mode ->
                if (mode == libraryMode) {
                    FilledTonalButton(onClick = { libraryMode = mode }) {
                        Text(mode.label)
                    }
                } else {
                    OutlinedButton(onClick = { libraryMode = mode }) {
                        Text(mode.label)
                    }
                }
            }
        }

        if (recordings.isEmpty()) {
            EmptySavedRecordingsState(
                onLoadExamples = onLoadExamples,
                onImportRecording = onImportRecording
            )
        } else {
            RecordingLibrarySummary(mode = libraryMode, comparison = comparison)
            when (libraryMode) {
                RecordingLibraryMode.DATE, RecordingLibraryMode.SCORE -> {
                    sortedSavedRecordings(recordings, libraryMode).forEachIndexed { index, saved ->
                        SavedRecordingCard(
                            summary = saved,
                            onOpen = { onOpenSaved(saved) },
                            onDelete = { pendingDelete = saved }
                        )
                        if (index < recordings.lastIndex) Spacer(Modifier.height(4.dp))
                    }
                }
                RecordingLibraryMode.PROTOCOL, RecordingLibraryMode.MODE -> {
                    recordingGroups(recordings, libraryMode).forEach { group ->
                        RecordingGroupHeader(title = group.title, count = group.recordings.size)
                        group.recordings.forEachIndexed { index, saved ->
                            SavedRecordingCard(
                                summary = saved,
                                onOpen = { onOpenSaved(saved) },
                                onDelete = { pendingDelete = saved }
                            )
                            if (index < group.recordings.lastIndex) Spacer(Modifier.height(4.dp))
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { saved ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete recording?") },
            text = {
                Text(
                    saved.title,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text("Cancel")
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDelete = null
                        onDeleteSaved(saved)
                    }
                ) {
                    Text("Delete")
                }
            }
        )
    }
}

@Composable
internal fun RecordingLibrarySummary(mode: RecordingLibraryMode, comparison: AndroidProtocolComparison) {
    when (mode) {
        RecordingLibraryMode.DATE -> Text(
            "Newest recordings first.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        RecordingLibraryMode.SCORE -> Text(
            "Sorted by official comparable score first. Open a recording to see delivered packets, usable readings, and packet checks.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        RecordingLibraryMode.MODE -> Text(
            "Grouped by test mode so Shot / Pour, Idle, and Step Response recordings stay together.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        RecordingLibraryMode.PROTOCOL -> {
            if (comparison.rows.size < 2) {
                Text(
                    "Save or load two recordings to compare protocols side by side.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                comparison.bestOverall?.let { best ->
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
                    ) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            Text("Best full-detail", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                            Text(
                                "${best.protocolKind.displayName} · ${best.score?.let { "$it/100" } ?: "--"}",
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun RecordingGroupHeader(title: String, count: Int) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontWeight = FontWeight.SemiBold)
        Text(
            count.toString(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

internal fun sortedSavedRecordings(
    recordings: List<SavedRecordingSummary>,
    mode: RecordingLibraryMode
): List<SavedRecordingSummary> = when (mode) {
    RecordingLibraryMode.DATE -> recordings.sortedByDescending { it.savedAtMillis }
    RecordingLibraryMode.SCORE -> recordings.sortedWith(
        compareByDescending<SavedRecordingSummary> { it.score ?: -1 }
            .thenBy { it.purityIsUpperBound }
            .thenByDescending { it.savedAtMillis }
    )
    RecordingLibraryMode.PROTOCOL -> recordings.sortedWith(
        compareBy<SavedRecordingSummary> { it.protocolKind.displayName }
            .thenByDescending { it.score ?: -1 }
            .thenByDescending { it.savedAtMillis }
    )
    RecordingLibraryMode.MODE -> recordings.sortedWith(
        compareBy<SavedRecordingSummary> { it.mode.displayName }
            .thenByDescending { it.savedAtMillis }
    )
}

internal fun recordingGroups(
    recordings: List<SavedRecordingSummary>,
    mode: RecordingLibraryMode
): List<RecordingLibraryGroup> {
    return sortedSavedRecordings(recordings, mode)
        .groupBy { saved ->
            when (mode) {
                RecordingLibraryMode.PROTOCOL -> saved.protocolKind.displayName
                RecordingLibraryMode.MODE -> saved.mode.displayName
                RecordingLibraryMode.DATE, RecordingLibraryMode.SCORE -> "All recordings"
            }
        }
        .map { (title, groupRecordings) ->
            RecordingLibraryGroup(
                id = title,
                title = title,
                recordings = groupRecordings
            )
        }
}

@Composable
internal fun ScaleListRow(scale: DiscoveredScale, isConnected: Boolean, onConnect: () -> Unit) {
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
internal fun SwiftMetricRow(title: String, value: String) {
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

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun EmptySavedRecordingsState(onLoadExamples: () -> Unit, onImportRecording: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("No saved recordings yet", fontWeight = FontWeight.SemiBold)
            Text(
                "Save a test result, import JSON, or load examples to explore charts, score deductions, and raw packets.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(onClick = onImportRecording) {
                    Text("Import JSON")
                }
                OutlinedButton(onClick = onLoadExamples) {
                    Text("Load examples")
                }
            }
        }
    }
}

@Composable
internal fun SavedRecordingCard(summary: SavedRecordingSummary, onOpen: () -> Unit, onDelete: () -> Unit) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen),
        shape = RoundedCornerShape(8.dp)
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(summary.title, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${summary.protocolKind.displayName} · ${summary.mode.displayName}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Spacer(Modifier.width(12.dp))
                SavedScorePill(summary = summary)
            }

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                SavedMetaChip("Samples", summary.sampleCount.toString())
                SavedMetaChip("Packets", summary.rawPacketCount.toString())
                SavedMetaChip("Checks", summary.verificationCoveragePercent?.let { "${Math.round(it * 5.0 / 100.0).toInt()}/5" } ?: "--")
                SavedMetaChip(platformDisplayName(summary.platform))
            }

            val note = summary.notes.orEmpty().trim()
            if (note.isNotEmpty()) {
                Text(
                    note,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onOpen) {
                    Text("Open")
                }
                TextButton(onClick = onDelete) {
                    Text("Delete")
                }
            }
        }
    }
}

@Composable
internal fun SavedMetaChip(label: String, value: String? = null) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    ) {
        Text(
            listOfNotNull(label, value).joinToString(" "),
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
internal fun SavedScorePill(summary: SavedRecordingSummary) {
    val text = summary.score?.let { "$it" } ?: "--"
    val color = if (summary.score == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = color.copy(alpha = 0.12f)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = color)
            Text("score", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun SavedRecordingDetailsDialog(
    details: SavedRecordingDetails,
    onExport: () -> Unit,
    onShareScorecard: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit
) {
    var confirmDelete by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.fillMaxWidth(0.96f),
        properties = DialogProperties(usePlatformDefaultWidth = false),
        title = { Text(details.title) },
        text = {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 720.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                item {
                    SavedDetailPanel("Overview") {
                        Text("${details.protocol} · ${details.mode}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SwiftMetricRow("Started", details.started)
                        SwiftMetricRow("Duration", details.duration)
                        SwiftMetricRow("Samples", details.sampleCount.toString())
                        SwiftMetricRow("Raw packets", details.rawPacketCount.toString())
                        SwiftMetricRow("Battery events", details.batteryEventCount.toString())
                        if (details.notes.isNotBlank()) {
                            Text("Notes", fontWeight = FontWeight.SemiBold)
                            Text(details.notes, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                item {
                    SavedDetailPanel("Scorecard") {
                        ScoreHero(
                            title = details.scoreTitle,
                            value = details.score,
                            isValid = when (details.validity) {
                                "Valid" -> true
                                "Not valid" -> false
                                else -> null
                            }
                        )
                        SwiftMetricRow("Benchmark", "ScaleBench Standard v1")
                        SwiftMetricRow("Validity", details.validity)
                        if (details.coverage != "--") SwiftMetricRow("Delivered", details.coverage)
                        if (details.purity != "--") SwiftMetricRow(details.purityTitle, details.purity)
                        if (details.verification != "--") SwiftMetricRow("Packet checks", details.verification)
                        if (details.validityReasons.isNotBlank()) {
                            Text(details.validityReasons, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        ScoreExplanationBlock(details.scoreExplanationLines)
                        SwiftMetricRow(details.effectiveRateTitle, details.effectiveRate)
                        SwiftMetricRow("Interval p50", details.intervalP50)
                        SwiftMetricRow("Interval p95", details.intervalP95)
                        SwiftMetricRow("Max gap", details.maxGap)
                        SwiftMetricRow("Long gaps", details.longGaps)
                        SwiftMetricRow("Missing seq", details.missingSeq)
                        SwiftMetricRow("Rejected", details.rejected)
                        SwiftMetricRow("Idle noise", details.idleNoise)
                        SwiftMetricRow("Idle std dev", details.idleStdDev)
                        SwiftMetricRow("Drift", details.drift)
                    }
                }
                if (details.transportComparison.isVisible) {
                    item {
                        SavedDetailPanel("Transport comparison") {
                            TransportComparisonPanel(details.transportComparison)
                        }
                    }
                }
                if (details.samplePoints.size >= 2 || details.packetIntervals.isNotEmpty()) {
                    item {
                        SavedDetailPanel("Charts") {
                            Text("Weight stream", fontWeight = FontWeight.SemiBold)
                            ChartWeightStream(
                                points = details.samplePoints,
                                flowPoints = details.flowPoints,
                                thresholdMs = details.longGapThresholdMs,
                                scoringGaps = details.packetTimeline.scoringGaps,
                                durationSeconds = details.packetTimeline.durationSeconds
                            )
                            Text(
                                weightChartExplanation(
                                    thresholdMs = details.longGapThresholdMs,
                                    hasFlow = details.flowPoints.isNotEmpty()
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            ProblemAreasSection(
                                points = details.samplePoints,
                                flowPoints = details.flowPoints,
                                timeline = details.packetTimeline,
                                windows = details.problemWindows
                            )
                            Text("Packet cadence", fontWeight = FontWeight.SemiBold)
                            ChartPacketCadence(
                                intervals = details.packetIntervals,
                                thresholdMs = details.longGapThresholdMs
                            )
                            Text(
                                cadenceChartExplanation(
                                    intervals = details.packetIntervals,
                                    thresholdMs = details.longGapThresholdMs
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text("Packet timeline", fontWeight = FontWeight.SemiBold)
                            val defaultEntry = remember(details.packetTimeline.entries) { defaultPacketEntry(details.packetTimeline) }
                            var selectedPacketID by remember(details.packetTimeline.entries) { mutableIntStateOf(defaultEntry?.id ?: -1) }
                            val selectedEntry = details.packetTimeline.entries.firstOrNull { it.id == selectedPacketID } ?: defaultEntry
                            PacketTimelineChart(
                                timeline = details.packetTimeline,
                                selectedEntryId = selectedEntry?.id,
                                onSelect = { selectedPacketID = it.id }
                            )
                            PacketLegend(details.packetTimeline)
                            PacketInspectorPreview(
                                timeline = details.packetTimeline,
                                selectedEntryId = selectedEntry?.id,
                                onSelect = { selectedPacketID = it.id }
                            )
                        }
                    }
                }
                item {
                    SavedDetailPanel("Samples") {
                        SwiftMetricRow("First weight", details.firstWeight)
                        SwiftMetricRow("Last weight", details.lastWeight)
                        SwiftMetricRow("Min battery", details.batteryMin)
                        SwiftMetricRow("Max battery", details.batteryMax)
                    }
                }
                if (details.rawPreview.isNotEmpty()) {
                    item {
                        SavedDetailPanel("Raw packet preview") {
                            details.rawPreview.forEach { packet ->
                                Text(packet, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        },
        dismissButton = {
            TextButton(onClick = { confirmDelete = true }) {
                Text("Delete")
            }
        },
        confirmButton = {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(onClick = onShareScorecard, enabled = details.canShareScorecard) {
                    Text("Share Scorecard")
                }
                OutlinedButton(onClick = onExport) {
                    Text("Save JSON...")
                }
                Button(onClick = onDismiss) {
                    Text("Done")
                }
            }
        }
    )

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete recording?") },
            text = {
                Text(details.title, color = MaterialTheme.colorScheme.onSurfaceVariant)
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) {
                    Text("Cancel")
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDelete = false
                        onDelete()
                    }
                ) {
                    Text("Delete")
                }
            }
        )
    }
}

@Composable
private fun SavedDetailPanel(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp)
        ) {
            Text(title, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

internal data class SavedRecordingDetails(
    val summary: SavedRecordingSummary,
    val title: String,
    val notes: String,
    val protocol: String,
    val mode: String,
    val started: String,
    val duration: String,
    val sampleCount: Int,
    val rawPacketCount: Int,
    val batteryEventCount: Int,
    val scoreTitle: String,
    val score: String,
    val validity: String,
    val validityReasons: String,
    val scoreExplanationLines: List<String>,
    val coverage: String,
    val purityTitle: String,
    val purity: String,
    val verification: String,
    val effectiveRateTitle: String,
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
    val flowPoints: List<ChartPoint>,
    val packetIntervals: List<Double>,
    val rejectedPacketIndexes: Set<Int>,
    val packetTimeline: AndroidPacketTimeline,
    val problemWindows: List<ChartWindow>,
    val transportComparison: AndroidTransportComparison,
    val rawPreview: List<String>,
    val canShareScorecard: Boolean
)

internal fun readSavedRecordingDetails(store: SavedRecordingStore, summary: SavedRecordingSummary): SavedRecordingDetails {
    return try {
        val recording = store.recordingForAnalysis(summary)
        val analysis = ChartAnalysis.create(recording, recording.metrics)
        val objectJson = store.recordingObject(recording)
        val metrics = objectJson.optJSONObject("metrics") ?: JSONObject()
        val samples = objectJson.optJSONArray("samples")
        val packets = objectJson.optJSONArray("rawPackets")
        val batteryEvents = objectJson.optJSONArray("batteryEvents")
        val firstSample = samples?.optJSONObject(0)
        val lastSample = samples?.optJSONObject((samples.length() - 1).coerceAtLeast(0))
        val delivery = metrics.optJSONObject("delivery")
        val verification = metrics.optJSONObject("protocolVerification")
        val validity = metrics.optJSONObject("validity")
        val scoreValue = when (summary.mode) {
            RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> delivery?.nullableInt("deliveryScore")
            RecordingMode.IDLE_STABILITY -> metrics.nullableInt("stabilityScore")
            RecordingMode.STEP_RESPONSE, RecordingMode.TARE_LATENCY, RecordingMode.BATTERY_STABILITY -> null
        }
        val scoreDisplay = if (scoreValue != null) {
            "$scoreValue/100"
        } else if (summary.mode == RecordingMode.STEP_RESPONSE || summary.mode == RecordingMode.TARE_LATENCY || summary.mode == RecordingMode.BATTERY_STABILITY) {
            "Metrics only"
        } else {
            "--"
        }
        val started = objectJson.optLong("startedAtMillis", 0L)
        val ended = objectJson.optLong("endedAtMillis", started)
        val monotonicDuration = if (metrics.isNull("recordingSpanSeconds")) null else metrics.optDouble("recordingSpanSeconds")
        val sampleCount = samples?.length() ?: summary.sampleCount
        val rawPacketCount = packets?.length() ?: summary.rawPacketCount
        val boundaryMissing = validity
            ?.optJSONArray("reasons")
            ?.jsonStrings()
            .orEmpty()
            .contains("recordingBoundariesMissing")
        val hasData = sampleCount > 0 || rawPacketCount > 0 || metrics.optInt("relevantWeightFrameCount", 0) > 0
        val longGapThresholdMs = analysis.packetTimeline.thresholdMs
        SavedRecordingDetails(
            summary = summary,
            title = summary.title,
            notes = objectJson.optString("notes", summary.notes ?: ""),
            protocol = summary.protocolKind.displayName,
            mode = summary.mode.displayName,
            started = if (started > 0) java.text.DateFormat.getDateTimeInstance().format(java.util.Date(started)) else "--",
            duration = when {
                monotonicDuration != null && monotonicDuration > 0.0 -> String.format(Locale.US, "%.1f s", monotonicDuration)
                boundaryMissing || !hasData -> "--"
                ended >= started -> formatDuration(ended - started)
                else -> "--"
            },
            sampleCount = sampleCount,
            rawPacketCount = rawPacketCount,
            batteryEventCount = batteryEvents?.length() ?: 0,
            scoreTitle = standardScoreTitle(summary.mode),
            score = scoreDisplay,
            validity = validity?.let { if (it.optBoolean("isValid", false)) "Valid" else "Not valid" } ?: "--",
            validityReasons = validity?.optJSONArray("reasons")?.jsonStrings()?.joinToString("; ") { validityReasonLabel(it) } ?: "",
            scoreExplanationLines = scoreExplanationLines(summary.mode, metrics),
            coverage = deliveredDisplay(metrics, delivery),
            purityTitle = "Usable readings",
            purity = usableDisplay(metrics, delivery),
            verification = if (hasData) verification?.let {
                protocolDetailDisplay(
                    availableChecks = it.optJSONArray("verifiableClasses")?.length(),
                    totalChecks = (it.optJSONArray("verifiableClasses")?.length() ?: 0) +
                        (it.optJSONArray("unverifiableClasses")?.length() ?: 0)
                )
            } ?: "--" else "--",
            effectiveRateTitle = if (objectJson.optString("source") == "usbSerial") "Received rate" else "Effective rate",
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
            longGapThresholdMs = longGapThresholdMs,
            samplePoints = analysis.weightPoints,
            flowPoints = analysis.flowPoints,
            packetIntervals = analysis.packetTimeline.sampleIntervals.map { it.intervalMs },
            rejectedPacketIndexes = rejectedPacketIndexes(packets),
            packetTimeline = analysis.packetTimeline,
            problemWindows = analysis.problemWindows,
            transportComparison = AndroidTransportComparison.from(recording),
            rawPreview = rawPreview(packets),
            canShareScorecard = canShareOfficialScorecard(summary.mode, recording.metrics)
        )
    } catch (error: Exception) {
        SavedRecordingDetails(
            summary = summary,
            title = summary.title,
            notes = summary.notes ?: "",
            protocol = summary.protocolKind.displayName,
            mode = summary.mode.displayName,
            started = "--",
            duration = "--",
            sampleCount = summary.sampleCount,
            rawPacketCount = summary.rawPacketCount,
            batteryEventCount = 0,
            scoreTitle = standardScoreTitle(summary.mode),
            score = summary.score?.let { "$it/100" } ?: "--",
            validity = "--",
            validityReasons = "",
            scoreExplanationLines = listOf("Could not recalculate this recording: ${error.message ?: "unknown error"}"),
            coverage = "--",
            purityTitle = "Usable readings",
            purity = "--",
            verification = "--",
            effectiveRateTitle = "Effective rate",
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
            flowPoints = emptyList(),
            packetIntervals = emptyList(),
            rejectedPacketIndexes = emptySet(),
            packetTimeline = AndroidPacketTimeline(emptyList(), emptyList(), 300.0),
            problemWindows = emptyList(),
            transportComparison = AndroidTransportComparison(emptyList()),
            rawPreview = listOf("Could not open saved JSON: ${error.message ?: "unknown error"}"),
            canShareScorecard = false
        )
    }
}

internal fun rejectedPacketIndexes(packets: org.json.JSONArray?): Set<Int> {
    if (packets == null) return emptySet()
    return (0 until packets.length()).mapNotNull { index ->
        val packet = packets.optJSONObject(index)
        if (packet != null && packet.has("rejectionReason")) index else null
    }.toSet()
}

private fun deliveredDisplay(metrics: org.json.JSONObject, delivery: org.json.JSONObject?): String {
    val coverage = delivery?.nullableDouble("coverage")
    val served = metrics.nullableInt("servedSlots")
    val total = metrics.nullableInt("slotCount")
    return if (coverage != null && served != null && total != null && total > 0) {
        "$served/$total (${formatPercent(coverage)})"
    } else {
        coverage?.let(::formatPercent) ?: "--"
    }
}

private fun usableDisplay(metrics: org.json.JSONObject, delivery: org.json.JSONObject?): String {
    val purity = delivery?.nullableDouble("purity")
    val usable = metrics.nullableInt("usableSampleCount")
    val total = metrics.nullableInt("relevantWeightFrameCount")
    return if (purity != null && usable != null && total != null && total > 0) {
        "$usable/$total (${formatPercent(purity)})"
    } else {
        purity?.let(::formatPercent) ?: "--"
    }
}
