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

internal fun standardScoreTitle(mode: RecordingMode): String = when (mode) {
    RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> "Delivery score"
    RecordingMode.IDLE_STABILITY -> "Idle Stability score"
    RecordingMode.STEP_RESPONSE -> "Step Response"
    RecordingMode.TARE_LATENCY -> "Tare Latency"
    RecordingMode.BATTERY_STABILITY -> "Battery Logging"
}

fun deviceUtilityCapabilityLabel(services: List<String>): String {
    val normalized = services.map { it.uppercase(Locale.ROOT) }
    return when {
        normalized.any { it.contains("FE59") } -> "Nordic DFU advertised"
        normalized.any { it.contains("8D53DC1D") } -> "SMP / McuManager advertised"
        else -> "Not advertised"
    }
}

internal fun platformDisplayName(platform: String?): String = when (platform) {
    "android" -> "Android"
    "ios" -> "iOS / iPadOS"
    "macos-catalyst" -> "macOS Catalyst"
    else -> "Unknown platform"
}

internal fun standardScoreDisplay(mode: RecordingMode, metrics: ScaleQualityMetrics): String {
    val score = when (mode) {
        RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> metrics.delivery?.deliveryScore
        RecordingMode.IDLE_STABILITY -> metrics.stabilityScore
        RecordingMode.STEP_RESPONSE, RecordingMode.TARE_LATENCY, RecordingMode.BATTERY_STABILITY -> null
    }
    if (score == null) {
        return if (mode == RecordingMode.STEP_RESPONSE || mode == RecordingMode.TARE_LATENCY || mode == RecordingMode.BATTERY_STABILITY) {
            "Metrics only"
        } else {
            "--"
        }
    }
    return "$score/100"
}

internal fun officialScorecardError(mode: RecordingMode, metrics: ScaleQualityMetrics): String? {
    val validity = metrics.validity
    if (validity?.isValid != true) {
        val reasons = validity?.reasons
            ?.joinToString("; ") { validityReasonLabel(it) }
            ?.takeIf { it.isNotBlank() }
            ?: "run a complete recording for this mode"
        return "This recording is not valid for an official scorecard: $reasons."
    }
    val score = when (mode) {
        RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> metrics.delivery?.deliveryScore
        RecordingMode.IDLE_STABILITY -> metrics.stabilityScore
        RecordingMode.STEP_RESPONSE, RecordingMode.TARE_LATENCY, RecordingMode.BATTERY_STABILITY -> null
    }
    return if (score == null) {
        "This recording mode reports metrics and does not produce an official 0-100 score."
    } else {
        null
    }
}

internal fun canShareOfficialScorecard(mode: RecordingMode, metrics: ScaleQualityMetrics): Boolean =
    officialScorecardError(mode, metrics) == null

internal fun deliveredUpdatesDisplay(metrics: ScaleQualityMetrics): String {
    val coverage = metrics.delivery?.coverage
    val served = metrics.servedSlots
    val total = metrics.slotCount
    return if (coverage != null && served != null && total != null && total > 0) {
        "$served/$total (${formatPercent(coverage)})"
    } else {
        coverage?.let(::formatPercent) ?: "--"
    }
}

internal fun usableReadingsDisplay(metrics: ScaleQualityMetrics): String {
    val purity = metrics.delivery?.purity
    val usable = metrics.usableSampleCount
    val total = metrics.relevantWeightFrameCount
    return if (purity != null && usable != null && total != null && total > 0) {
        "$usable/$total (${formatPercent(purity)})"
    } else {
        purity?.let(::formatPercent) ?: "--"
    }
}

internal fun scoreExplanationLines(mode: RecordingMode, metrics: ScaleQualityMetrics): List<String> {
    val validity = metrics.validity
    if (validity != null && !validity.isValid) {
        return listOf(
            "No official score was produced because this recording did not meet the Standard v1 requirements.",
            "Fix: ${validity.reasons.joinToString("; ") { validityReasonLabel(it) }}."
        )
    }

    return when (mode) {
        RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> deliveryScoreExplanation(
            score = metrics.delivery?.deliveryScore,
            coverage = metrics.delivery?.coverage,
            purity = metrics.delivery?.purity,
            slotCount = metrics.slotCount,
            servedSlots = metrics.servedSlots,
            longestUnservedRunMilliseconds = metrics.longestUnservedRunMilliseconds,
            longGapCount = metrics.longGapCount,
            missingSequenceCount = metrics.missingSequenceCount,
            rejectedPacketCount = metrics.rejectedPacketCount,
            usableFrames = metrics.usableSampleCount ?: metrics.frameClassification?.usable,
            relevantFrames = metrics.relevantWeightFrameCount,
            parseFailures = metrics.frameClassification?.parseFailure,
            outOfOrder = metrics.frameClassification?.outOfOrder,
            stale = metrics.frameClassification?.stale,
            implausible = metrics.frameClassification?.implausible,
            duplicates = metrics.frameClassification?.duplicate,
            availableChecks = metrics.protocolVerification?.verifiableClasses?.size,
            totalChecks = metrics.protocolVerification?.let { it.verifiableClasses.size + it.unverifiableClasses.size }
        )
        RecordingMode.IDLE_STABILITY -> idleScoreExplanation(
            score = metrics.stabilityScore,
            noiseScore = metrics.idleNoiseScore,
            driftScore = metrics.idleDriftScore,
            noise = metrics.idleNoiseStandardDeviationGrams,
            drift = metrics.driftGramsPerMinute,
            analysedSampleCount = metrics.idleAnalysedSampleCount
        )
        RecordingMode.STEP_RESPONSE -> stepScoreExplanation(metrics)
        RecordingMode.TARE_LATENCY -> listOf("Tare Latency is metrics-only in Standard v1; it does not produce a 0-100 score yet.")
        RecordingMode.BATTERY_STABILITY -> listOf("Battery Logging is telemetry-only in Standard v1; it records battery evidence without producing a 0-100 score.")
    }
}

internal fun scoreExplanationLines(mode: RecordingMode, metrics: JSONObject): List<String> {
    val validity = metrics.optJSONObject("validity")
    if (validity != null && !validity.optBoolean("isValid", false)) {
        val reasons = validity.optJSONArray("reasons")?.jsonStrings().orEmpty()
        return listOf(
            "No official score was produced because this recording did not meet the Standard v1 requirements.",
            "Fix: ${reasons.joinToString("; ") { validityReasonLabel(it) }.ifBlank { "run a complete recording for this mode" }}."
        )
    }

    return when (mode) {
        RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> {
            val delivery = metrics.optJSONObject("delivery")
            val frames = metrics.optJSONObject("frameClassification")
            val verification = metrics.optJSONObject("protocolVerification")
            deliveryScoreExplanation(
                score = delivery?.nullableInt("deliveryScore"),
                coverage = delivery?.nullableDouble("coverage"),
                purity = delivery?.nullableDouble("purity"),
                slotCount = metrics.nullableInt("slotCount"),
                servedSlots = metrics.nullableInt("servedSlots"),
                longestUnservedRunMilliseconds = metrics.nullableDouble("longestUnservedRunMilliseconds"),
                longGapCount = metrics.optInt("longGapCount", 0),
                missingSequenceCount = metrics.optInt("missingSequenceCount", 0),
                rejectedPacketCount = metrics.optInt("rejectedPacketCount", 0),
                usableFrames = metrics.nullableInt("usableSampleCount") ?: frames?.optInt("usable", 0),
                relevantFrames = metrics.nullableInt("relevantWeightFrameCount"),
                parseFailures = frames?.optInt("parseFailure", 0),
                outOfOrder = frames?.optInt("outOfOrder", 0),
                stale = frames?.optInt("stale", 0),
                implausible = frames?.optInt("implausible", 0),
                duplicates = frames?.optInt("duplicate", 0),
                availableChecks = verification?.optJSONArray("verifiableClasses")?.length(),
                totalChecks = verification?.let {
                    (it.optJSONArray("verifiableClasses")?.length() ?: 0) +
                        (it.optJSONArray("unverifiableClasses")?.length() ?: 0)
                }
            )
        }
        RecordingMode.IDLE_STABILITY -> idleScoreExplanation(
            score = metrics.nullableInt("stabilityScore"),
            noiseScore = metrics.nullableInt("idleNoiseScore"),
            driftScore = metrics.nullableInt("idleDriftScore"),
            noise = metrics.nullableDouble("idleNoiseStandardDeviationGrams"),
            drift = metrics.nullableDouble("driftGramsPerMinute"),
            analysedSampleCount = metrics.nullableInt("idleAnalysedSampleCount")
        )
        RecordingMode.STEP_RESPONSE -> stepScoreExplanation(metrics)
        RecordingMode.TARE_LATENCY -> listOf("Tare Latency is metrics-only in Standard v1; it does not produce a 0-100 score yet.")
        RecordingMode.BATTERY_STABILITY -> listOf("Battery Logging is telemetry-only in Standard v1; it records battery evidence without producing a 0-100 score.")
    }
}

internal fun deliveryScoreExplanation(
    score: Int?,
    coverage: Double?,
    purity: Double?,
    slotCount: Int?,
    servedSlots: Int?,
    longestUnservedRunMilliseconds: Double?,
    longGapCount: Int,
    missingSequenceCount: Int,
    rejectedPacketCount: Int,
    usableFrames: Int?,
    relevantFrames: Int?,
    parseFailures: Int?,
    outOfOrder: Int?,
    stale: Int?,
    implausible: Int?,
    duplicates: Int?,
    availableChecks: Int?,
    totalChecks: Int?
): List<String> {
    if (score == null || coverage == null || purity == null) {
        return listOf("Delivery score needs a valid recording plus enough packet evidence to count delivered packets and usable readings.")
    }

    val rawCoverageScore = 100.0 * coverage
    val rawFinalScore = rawCoverageScore * purity
    val coverageDeduction = 100.0 - rawCoverageScore
    val frameDeduction = rawCoverageScore - rawFinalScore
    val lines = mutableListOf<String>()

    if (slotCount != null && servedSlots != null && slotCount > 0) {
        lines += "Delivered packets: $servedSlots/$slotCount expected (${formatPercent(coverage)})."
    } else {
        lines += "Delivered packets: ${formatPercent(coverage)}."
    }

    if (usableFrames != null && relevantFrames != null && relevantFrames > 0) {
        lines += "Usable readings: $usableFrames/$relevantFrames (${formatPercent(purity)})."
    } else {
        lines += "Usable readings: ${formatPercent(purity)}."
    }

    lines += "Score: round(100 x ${formatMultiplier(coverage)} x ${formatMultiplier(purity)}) = $score/100."
    lines += "Biggest deduction: delivered packets cost ${formatPointValue(coverageDeduction)}; unusable or repeated readings cost ${formatPointValue(frameDeduction)}."

    val drivers = mutableListOf<String>()
    if (longGapCount > 0) drivers += "$longGapCount long ${if (longGapCount == 1) "gap" else "gaps"}"
    if (longestUnservedRunMilliseconds != null && longestUnservedRunMilliseconds >= 100) {
        drivers += "longest empty run ${String.format(Locale.US, "%.0f ms", longestUnservedRunMilliseconds)}"
    }
    if (rejectedPacketCount > 0) drivers += "$rejectedPacketCount rejected ${if (rejectedPacketCount == 1) "packet" else "packets"}"
    if ((parseFailures ?: 0) > 0) drivers += "${parseFailures} unreadable ${if (parseFailures == 1) "packet" else "packets"}"
    if ((outOfOrder ?: 0) > 0) drivers += "${outOfOrder} out-of-order"
    if ((stale ?: 0) > 0) drivers += "${stale} stale ${if (stale == 1) "reading" else "readings"}"
    if ((implausible ?: 0) > 0) drivers += "${implausible} implausible ${if (implausible == 1) "reading" else "readings"}"
    if ((duplicates ?: 0) > 0) drivers += "${duplicates} repeated ${if (duplicates == 1) "reading" else "readings"}"
    if (missingSequenceCount > 0) drivers += "$missingSequenceCount missing sequence ${if (missingSequenceCount == 1) "step" else "steps"}"
    lines += if (drivers.isEmpty()) {
        "Packet inspector: no bad packets found. The score dropped because too few updates arrived."
    } else {
        "Other issues found: ${drivers.joinToString(", ")}."
    }

    return lines
}

internal fun protocolDetailDisplay(availableChecks: Int?, totalChecks: Int?): String {
    return if (availableChecks != null && totalChecks != null && totalChecks > 0) {
        "$availableChecks of $totalChecks available"
    } else {
        "--"
    }
}

internal fun protocolDetailDisplay(metrics: ScaleQualityMetrics): String {
    val frameCount = metrics.relevantWeightFrameCount ?: metrics.usableSampleCount ?: 0
    val verification = metrics.protocolVerification
    return if (frameCount > 0 && verification != null) {
        protocolDetailDisplay(
            availableChecks = verification.verifiableClasses.size,
            totalChecks = verification.verifiableClasses.size + verification.unverifiableClasses.size
        )
    } else {
        "--"
    }
}

internal data class PacketCheckStatus(val label: String, val isAvailable: Boolean)

internal fun packetCheckStatuses(verification: ProtocolVerificationMetrics): List<PacketCheckStatus> {
    val verifiable = verification.verifiableClasses.toSet()
    val unverifiable = verification.unverifiableClasses.toSet()
    val known = listOf("parseFailure", "outOfOrder", "stale", "duplicate", "implausible")
    val extras = (verifiable + unverifiable - known.toSet()).sorted()
    return (known + extras)
        .filter { verifiable.contains(it) || unverifiable.contains(it) }
        .map { PacketCheckStatus(packetCheckDisplayName(it), verifiable.contains(it)) }
}

internal fun packetCheckDisplayName(check: String): String = when (check) {
    "parseFailure" -> "Unreadable packets"
    "outOfOrder" -> "Out of order"
    "stale" -> "Stale readings"
    "duplicate" -> "Repeated readings"
    "implausible" -> "Implausible readings"
    else -> check
}

internal data class TelemetryStatus(val label: String, val isAvailable: Boolean)

internal fun telemetryStatuses(recording: ScaleRecording, metrics: ScaleQualityMetrics): List<TelemetryStatus> {
    val capabilities = recording.protocolCapabilities
    val hasBattery = metrics.batteryMinPercent != null ||
        metrics.batteryMaxPercent != null ||
        recording.batteryEvents.isNotEmpty() ||
        recording.samples.any { it.batteryPercent != null }
    val hasFlow = recording.samples.any { it.flowGramsPerSecond != null }
    val hasClock = capabilities?.hasDeviceClock == true ||
        recording.samples.any { it.deviceTimestampMilliseconds != null } ||
        recording.rawPackets.any { it.deviceTimestampMilliseconds != null }
    val hasSequence = capabilities?.hasSequence == true ||
        recording.samples.any { it.sequence != null } ||
        recording.rawPackets.any { it.sequence != null }
    val hasChecksum = capabilities?.hasChecksum == true
    val hasFirmwareQuality = metrics.firmwareQualityAverage != null ||
        recording.samples.any { it.firmwareQualityScore != null }

    return listOf(
        TelemetryStatus("Battery", hasBattery),
        TelemetryStatus("Flow", hasFlow),
        TelemetryStatus("Device clock", hasClock),
        TelemetryStatus("Sequence number", hasSequence),
        TelemetryStatus("Checksum / CRC", hasChecksum),
        TelemetryStatus("Firmware quality", hasFirmwareQuality)
    )
}

internal fun resolutionDisplay(metrics: ScaleQualityMetrics): String {
    val resolution = metrics.estimatedResolutionGrams ?: metrics.idleResolutionGrams
    return resolution?.let { String.format(Locale.US, "%.3f g", it) } ?: "--"
}

internal fun badPacketCount(metrics: ScaleQualityMetrics): Int {
    val frames = metrics.frameClassification
    return metrics.rejectedPacketCount +
        (frames?.parseFailure ?: 0) +
        (frames?.outOfOrder ?: 0) +
        (frames?.stale ?: 0) +
        (frames?.duplicate ?: 0) +
        (frames?.implausible ?: 0)
}

internal fun idleScoreExplanation(
    score: Int?,
    noiseScore: Int?,
    driftScore: Int?,
    noise: Double?,
    drift: Double?,
    analysedSampleCount: Int?
): List<String> {
    if (score == null) {
        return listOf("Idle Stability needs a valid 60 second untouched recording with enough usable samples after the 5 second settling window.")
    }
    val lines = mutableListOf<String>()
    lines += "Score: geometric blend of noise and drift = $score/100."
    if (noiseScore != null && driftScore != null) {
        lines += "Noise contributed $noiseScore/100; drift contributed $driftScore/100."
    }
    val measurements = mutableListOf<String>()
    if (noise != null) measurements += "noise std dev ${String.format(Locale.US, "%.3f g", noise)}"
    if (drift != null) measurements += "drift ${String.format(Locale.US, "%.3f g/min", drift)}"
    if (analysedSampleCount != null) measurements += "$analysedSampleCount analysed samples"
    if (measurements.isNotEmpty()) lines += "Evidence: ${measurements.joinToString(", ")}."
    return lines
}

internal fun stepScoreExplanation(metrics: ScaleQualityMetrics): List<String> {
    val step = metrics.stepResponse
    if (step?.stepDetected != true) {
        return listOf("Step Response is metrics-only, and no clean step was detected in this recording.")
    }
    return listOf(
        "Step Response is metrics-only in Standard v1; it reports timing and settling instead of a 0-100 score.",
        "Detected step: onset ${step.onsetSecondsFromRecordingStart?.let(::formatSecondsValue) ?: "--"}, rise ${step.riseTime10To90Seconds?.let(::formatSecondsValue) ?: "--"}, settling ${step.settlingTimeSeconds?.let(::formatSecondsValue) ?: "--"}."
    )
}

internal fun stepScoreExplanation(metrics: JSONObject): List<String> {
    val step = metrics.optJSONObject("stepResponse")
    if (step == null || !step.optBoolean("stepDetected", false)) {
        return listOf("Step Response is metrics-only, and no clean step was detected in this recording.")
    }
    return listOf(
        "Step Response is metrics-only in Standard v1; it reports timing and settling instead of a 0-100 score.",
        "Detected step: onset ${step.nullableDouble("onsetSecondsFromRecordingStart")?.let(::formatSecondsValue) ?: "--"}, rise ${step.nullableDouble("riseTime10To90Seconds")?.let(::formatSecondsValue) ?: "--"}, settling ${step.nullableDouble("settlingTimeSeconds")?.let(::formatSecondsValue) ?: "--"}."
    )
}

internal fun formatPointValue(value: Double): String = "${String.format(Locale.US, "%.1f", value.coerceAtLeast(0.0))} points"

internal fun formatPercent(value: Double): String = String.format(Locale.US, "%.1f%%", value * 100.0)

internal fun formatMultiplier(value: Double): String = String.format(Locale.US, "%.3f", value)

internal fun formatSecondsValue(value: Double): String = String.format(Locale.US, "%.2f s", value)

internal fun validityReasonLabel(reason: String): String = when (reason) {
    "recordingBoundariesMissing" -> "Recording was not started and stopped cleanly"
    "durationBelowMinimum" -> "Recording is shorter than the required duration"
    "usableFrameCountBelowMinimum" -> "Too few usable weight frames"
    "idleAnalysedFrameCountBelowMinimum" -> "Too few idle frames remain after settling"
    "stepBaselineFrameCountBelowMinimum" -> "Too few baseline frames for Step Response"
    "stepFinalFrameCountBelowMinimum" -> "Too few final-window frames for Step Response"
    "disconnectDuringRecording" -> "The scale disconnected during the recording"
    "appLeftForeground" -> "ScaleBench left the foreground during the recording"
    "unknownMode" -> "The recording mode is unknown"
    else -> reason
}

internal fun JSONObject.nullableInt(key: String): Int? = if (isNull(key)) null else optInt(key)

internal fun JSONObject.nullableDouble(key: String): Double? = if (isNull(key)) null else optDouble(key)

internal fun org.json.JSONArray.jsonStrings(): List<String> =
    (0 until length()).mapNotNull { index -> optString(index).takeIf { it.isNotBlank() } }

internal fun jsonPercent(objectJson: JSONObject?, key: String): String {
    return if (objectJson == null || objectJson.isNull(key)) "--" else formatPercent(objectJson.optDouble(key))
}

internal fun number(metrics: JSONObject, key: String, format: String): String {
    return if (metrics.isNull(key)) "--" else String.format(Locale.US, format, metrics.optDouble(key))
}

internal fun weight(sample: JSONObject?): String {
    return sample?.let { String.format(Locale.US, "%.2f g", it.optDouble("weightGrams")) } ?: "--"
}

internal fun rawPreview(packets: org.json.JSONArray?): List<String> {
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

internal fun modeHelp(mode: RecordingMode): String {
    return when (mode) {
        RecordingMode.IDLE_STABILITY -> "Record at least 60 seconds untouched; the first 5 seconds are settling time."
        RecordingMode.SHOT -> "Record at least 20 seconds; tare and settle before Start, then stop before removing the vessel."
        RecordingMode.STEP_RESPONSE -> "Record at least 10 seconds. Start empty, wait 2 seconds, add at least 5 g once, then hold through the final window."
        RecordingMode.TARE_LATENCY -> "Record at least 5 seconds around one tare action. Metrics only."
        RecordingMode.TRANSPORT_STRESS -> "Stress the BLE link for at least 120 seconds; disconnects are recorded but allowed."
        RecordingMode.BATTERY_STABILITY -> "Log exposed battery telemetry for at least 60 seconds. Telemetry only."
    }
}

internal fun recordingStatusLabel(
    bluetooth: BluetoothScaleManager,
    canRecord: Boolean,
    hasRecordingData: Boolean
): String {
    return when {
        bluetooth.isRecording -> "Recording is active"
        !canRecord -> "Connect a scale to record"
        hasRecordingData -> "Recording ready to review or save"
        else -> "Ready to record"
    }
}

internal fun formatDuration(milliseconds: Long): String {
    val totalSeconds = milliseconds / 1000
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return String.format(Locale.US, "%d:%02d", minutes, seconds)
}


@Composable
internal fun MetricChip(label: String, value: String) {
    AssistChip(onClick = {}, label = { Text("$label $value") })
}
