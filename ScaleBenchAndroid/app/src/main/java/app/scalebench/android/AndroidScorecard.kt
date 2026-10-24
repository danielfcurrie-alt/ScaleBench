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
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.delay
import org.json.JSONObject
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper

@Composable
internal fun ScorecardSection(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    SectionCard("Scorecard") {
        ScoreHero(
            title = standardScoreTitle(recording.mode),
            value = standardScoreDisplay(recording.mode, metrics),
            isValid = metrics.validity?.isValid
        )
        StandardScoreRows(recording.mode, metrics, showScore = false)
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

@Composable
internal fun ScoreHero(title: String, value: String, isValid: Boolean?) {
    val accent = when {
        isValid == false -> MaterialTheme.colorScheme.error
        value == "--" -> MaterialTheme.colorScheme.onSurfaceVariant
        value == "Metrics only" -> MaterialTheme.colorScheme.tertiary
        else -> MaterialTheme.colorScheme.primary
    }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = accent.copy(alpha = 0.12f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.labelLarge, color = accent)
                Text(
                    when (isValid) {
                        true -> "Valid Standard v1 recording"
                        false -> "Diagnostics only"
                        null -> "ScaleBench Standard v1"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(Modifier.width(12.dp))
            Text(value, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = accent)
        }
    }
}

@Composable
internal fun StandardScoreRows(mode: RecordingMode, metrics: ScaleQualityMetrics, showScore: Boolean = true) {
    SwiftMetricRow("Benchmark", "ScaleBench Standard v1")
    if (showScore) SwiftMetricRow(standardScoreTitle(mode), standardScoreDisplay(mode, metrics))
    metrics.validity?.let { SwiftMetricRow("Validity", if (it.isValid) "Valid" else "Not valid") }

    if (mode == RecordingMode.SHOT || mode == RecordingMode.TRANSPORT_STRESS) {
        SwiftMetricRow("Delivered", deliveredUpdatesDisplay(metrics))
        SwiftMetricRow("Usable readings", usableReadingsDisplay(metrics))
        PacketCheckStatusRows(metrics)
    } else if (mode == RecordingMode.IDLE_STABILITY) {
        SwiftMetricRow("Noise component", metrics.idleNoiseScore?.let { "$it/100" } ?: "--")
        SwiftMetricRow("Drift component", metrics.idleDriftScore?.let { "$it/100" } ?: "--")
    } else if (mode == RecordingMode.STEP_RESPONSE) {
        val step = metrics.stepResponse
        SwiftMetricRow("Step detected", if (step?.stepDetected == true) "Yes" else "No")
        SwiftMetricRow("10-90% rise", step?.riseTime10To90Seconds?.let(::formatSecondsValue) ?: "--")
        SwiftMetricRow("Settling time", step?.settlingTimeSeconds?.let(::formatSecondsValue) ?: "--")
        SwiftMetricRow("Overshoot", step?.overshootPercent?.let { String.format(Locale.US, "%.1f%%", it) } ?: "--")
    }
}

@Composable
internal fun PacketCheckStatusRows(metrics: ScaleQualityMetrics) {
    metrics.protocolVerification?.let { verification ->
        packetCheckStatuses(verification).forEach { status ->
            PacketCheckStatusRow(status)
        }
    }
}

@Composable
private fun PacketCheckStatusRow(status: PacketCheckStatus) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(status.label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(16.dp))
        Text(
            if (status.isAvailable) "Available" else "Not available",
            fontWeight = FontWeight.SemiBold,
            color = if (status.isAvailable) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
internal fun ScoreBreakdownRows(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    Text("How it was calculated", fontWeight = FontWeight.SemiBold)
    val validity = metrics.validity
    if (validity != null && !validity.isValid) {
        Text(
            "No official score was produced because this recording did not meet the Standard v1 requirements.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        validity.reasons.forEach { reason -> Text("• ${validityReasonLabel(reason)}", style = MaterialTheme.typography.bodySmall) }
    }

    when (recording.mode) {
        RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> {
            ScoreExplanationBlock(scoreExplanationLines(recording.mode, metrics))
            ScoreInfoButtons()
            Text(
                "Delivery score uses delivered updates and usable readings. The formula is shown above so the score is auditable without opening the JSON.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text("Telemetry available", fontWeight = FontWeight.SemiBold)
            TelemetryAvailabilityRows(recording, metrics)
            Text(
                "Telemetry is extra protocol data ScaleBench records when the scale exposes it. It is useful for diagnosis, but it is not a separate score term.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            metrics.frameClassification?.let { frames ->
                SwiftMetricRow("Usable readings", frames.usable.toString())
                SwiftMetricRow("Unreadable packets", frames.parseFailure.toString())
                SwiftMetricRow("Out of order", frames.outOfOrder.toString())
                SwiftMetricRow("Stale readings", frames.stale.toString())
                SwiftMetricRow("Implausible readings", frames.implausible.toString())
                SwiftMetricRow("Repeated readings", frames.duplicate.toString())
            }
        }
        RecordingMode.IDLE_STABILITY -> Text(
            "Idle Stability combines detrended residual noise and drift. It is separate from Delivery.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        RecordingMode.STEP_RESPONSE -> Text(
            "Step Response reports lag and settling metrics; Standard v1 does not turn them into a 0-100 score.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        RecordingMode.TARE_LATENCY -> Text("Tare Latency is metrics-only in Standard v1.", style = MaterialTheme.typography.bodySmall)
        RecordingMode.BATTERY_STABILITY -> Text("Battery Logging is telemetry-only in Standard v1.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
internal fun TelemetryAvailabilityRows(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    telemetryStatuses(recording, metrics).forEach { status ->
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(status.label, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(16.dp))
            Text(
                if (status.isAvailable) "Available" else "Not seen",
                fontWeight = FontWeight.SemiBold,
                color = if (status.isAvailable) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
internal fun ScoreExplanationBlock(lines: List<String>) {
    if (lines.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Why this score?", fontWeight = FontWeight.SemiBold)
        lines.forEach { line ->
            Text(line, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ScoreInfoButtons() {
    var selected by remember { mutableStateOf<ScoreHelpTopic?>(null) }

    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("Help", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        ScoreHelpTopic.entries.forEach { topic ->
            TextButton(onClick = { selected = topic }, contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)) {
                Text("i", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            }
        }
    }

    selected?.let { topic ->
        AlertDialog(
            onDismissRequest = { selected = null },
            title = { Text(topic.title) },
            text = { Text(topic.message) },
            confirmButton = {
                TextButton(onClick = { selected = null }) {
                    Text("OK")
                }
            }
        )
    }
}

private enum class ScoreHelpTopic(
    val label: String,
    val title: String,
    val message: String
) {
    DELIVERED(
        "Delivered",
        "Delivered",
        "Shot / Pour expects one usable weight update every 50 ms, or 20 per second. Missing updates reduce this part of the score."
    ),
    USABLE(
        "Usable",
        "Usable readings",
        "This counts how many received weight readings were usable for scoring. Unreadable, stale, implausible, or repeated readings reduce this part."
    ),
    CHECKS(
        "Checks",
        "Packet checks",
        "Some scales expose more packet details than others. More checks make it easier for ScaleBench to prove what happened, but the main score still comes from delivered updates and usable readings."
    )
}
