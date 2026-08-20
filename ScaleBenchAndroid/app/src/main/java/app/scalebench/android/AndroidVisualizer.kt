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
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper

@Composable
internal fun VisualizerSection(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    SectionCard("Visualizer") {
        RecordingVisualizer(recording = recording, metrics = metrics)
    }
}

@Composable
internal fun RecordingVisualizer(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
    var analysis by remember(
        recording.id,
        recording.samples.size,
        recording.rawPackets.size,
        recording.recordingEndMonotonicSeconds
    ) {
        mutableStateOf<AndroidChartAnalysis?>(null)
    }
    LaunchedEffect(
        recording.id,
        recording.samples.size,
        recording.rawPackets.size,
        recording.recordingEndMonotonicSeconds
    ) {
        analysis = null
        analysis = withContext(Dispatchers.Default) {
            ChartAnalysis.create(recording, metrics)
        }
    }

    val prepared = analysis
    if (prepared == null) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            Text(
                "Preparing charts and packet inspector...",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        return
    }

    RecordingVisualizerContent(metrics = metrics, analysis = prepared)
}

@Composable
private fun RecordingVisualizerContent(metrics: ScaleQualityMetrics, analysis: AndroidChartAnalysis) {
    val timeline = analysis.packetTimeline
    val thresholdMs = timeline.thresholdMs
    val weightPoints = analysis.weightPoints
    val flowPoints = analysis.flowPoints
    val defaultEntry = remember(timeline.entries) { defaultPacketEntry(timeline) }
    var selectedPacketID by remember(timeline.entries) { mutableIntStateOf(defaultEntry?.id ?: -1) }
    val selectedEntry = timeline.entries.firstOrNull { it.id == selectedPacketID } ?: defaultEntry
    val packetIntervals = remember(timeline.sampleIntervals) {
        timeline.sampleIntervals.map { it.intervalMs }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PacketEvidenceSummary(metrics = metrics, timeline = timeline)

        if (!analysis.signalDiagnostics.isEmpty()) {
            SignalDiagnosticsSection(analysis.signalDiagnostics)
        }

        Text("Weight stream", fontWeight = FontWeight.SemiBold)
        ChartWeightStream(
            points = weightPoints,
            flowPoints = flowPoints,
            thresholdMs = thresholdMs,
            scoringGaps = timeline.scoringGaps,
            durationSeconds = timeline.durationSeconds
        )
        Text(
            weightChartExplanation(
                thresholdMs = thresholdMs,
                hasFlow = flowPoints.isNotEmpty()
            ),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        ProblemAreasSection(
            points = weightPoints,
            flowPoints = flowPoints,
            timeline = timeline,
            windows = analysis.problemWindows
        )

        Text("Packet cadence", fontWeight = FontWeight.SemiBold)
        ChartPacketCadence(
            intervals = packetIntervals,
            thresholdMs = thresholdMs
        )
        Text(
            cadenceChartExplanation(
                intervals = packetIntervals,
                thresholdMs = thresholdMs
            ),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Text("Packet timeline", fontWeight = FontWeight.SemiBold)
        PacketTimelineChart(
            timeline = timeline,
            selectedEntryId = selectedEntry?.id,
            onSelect = { selectedPacketID = it.id }
        )
        PacketLegend(timeline)
        Text(
            "Tap a tick to inspect the raw packet below.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        PacketInspectorPreview(
            timeline = timeline,
            selectedEntryId = selectedEntry?.id,
            onSelect = { selectedPacketID = it.id }
        )
    }
}

@Composable
internal fun ChartWeightStream(
    points: List<ChartPoint>,
    flowPoints: List<ChartPoint> = emptyList(),
    thresholdMs: Double,
    scoringGaps: List<AndroidScoringGap> = emptyList(),
    durationSeconds: Double? = null,
    window: ChartWindow? = null
) {
    if (points.size < 2) {
        EmptyChart("Record at least two samples to show weight.")
        return
    }

    val primary = MaterialTheme.colorScheme.primary
    val flowColor = MaterialTheme.colorScheme.tertiary
    val warning = MaterialTheme.colorScheme.error
    val text = MaterialTheme.colorScheme.onSurfaceVariant
    val textMeasurer = rememberTextMeasurer()
    val axisStyle = MaterialTheme.typography.labelSmall.copy(
        color = text.copy(alpha = 0.78f),
        fontSize = 9.sp
    )
    val fullVisiblePoints = remember(points, window) {
        ChartAnalysis.pointsInWindow(points, window)
    }
    val fullVisibleFlowPoints = remember(flowPoints, window) {
        ChartAnalysis.pointsInWindow(flowPoints, window)
    }
    val visiblePoints = remember(fullVisiblePoints) {
        downsampleChartPointsForDisplay(fullVisiblePoints, maximumCount = 1_000)
    }
    val visibleFlowPoints = remember(fullVisibleFlowPoints) {
        downsampleChartPointsForDisplay(fullVisibleFlowPoints, maximumCount = 1_000)
    }
    val minT = window?.startSeconds ?: if (durationSeconds != null) 0.0 else fullVisiblePoints.first().seconds
    val maxT = window?.endSeconds ?: max(durationSeconds ?: 0.0, fullVisiblePoints.last().seconds)
    val visibleGaps = remember(scoringGaps, minT, maxT) {
        compactScoringGapsForDisplay(
            scoringGaps.filter { it.startSeconds <= maxT && it.endSeconds >= minT },
            maximumCount = 220
        )
    }
    val minWeight = fullVisiblePoints.minOf { it.value }
    val maxWeight = fullVisiblePoints.maxOf { it.value }
    val yPad = max(0.05, (maxWeight - minWeight) * 0.08)
    val minY = minWeight - yPad
    val maxY = maxWeight + yPad
    val minFlow = fullVisibleFlowPoints.minOfOrNull { it.value } ?: 0.0
    val maxFlow = fullVisibleFlowPoints.maxOfOrNull { it.value } ?: 0.0
    val showsFlow = visibleFlowPoints.size >= 2 && maxFlow > minFlow
    val chartDescription = String.format(
        Locale.US,
        "Weight stream chart, %d samples, %.2f to %.2f grams over %.1f seconds%s",
        fullVisiblePoints.size,
        minWeight,
        maxWeight,
        max(0.0, maxT - minT),
        if (showsFlow) ", with scale-reported flow on a separate visual scale" else ""
    )

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (showsFlow) {
            WeightStreamLegend(weightColor = primary, flowColor = flowColor)
        }

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(180.dp)
            .semantics { contentDescription = chartDescription }
    ) {
        val chartLeft = 42.dp.toPx()
        val chartTop = 8.dp.toPx()
        val chartRight = if (showsFlow) 36.dp.toPx() else 8.dp.toPx()
        val chartBottom = 24.dp.toPx()
        val chartWidth = max(1f, size.width - chartLeft - chartRight)
        val chartHeight = max(1f, size.height - chartTop - chartBottom)
        val gridColor = text.copy(alpha = 0.14f)

        (0..2).forEach { index ->
            val fraction = index / 2f
            val y = chartTop + chartHeight * fraction
            drawLine(
                color = gridColor,
                start = Offset(chartLeft, y),
                end = Offset(chartLeft + chartWidth, y),
                strokeWidth = 0.5.dp.toPx()
            )
            val value = maxY - (maxY - minY) * fraction
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatWeightAxis(value, includeUnit = index == 0),
                style = axisStyle,
                anchor = Offset(chartLeft - 6.dp.toPx(), y),
                horizontalAnchor = 1f,
                verticalAnchor = 0.5f
            )
        }

        (0..2).forEach { index ->
            val fraction = index / 2f
            val x = chartLeft + chartWidth * fraction
            drawLine(
                color = gridColor,
                start = Offset(x, chartTop),
                end = Offset(x, chartTop + chartHeight),
                strokeWidth = 0.5.dp.toPx()
            )
            val seconds = minT + (maxT - minT) * fraction
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatTimeAxis(seconds),
                style = axisStyle,
                anchor = Offset(x, chartTop + chartHeight + 5.dp.toPx()),
                horizontalAnchor = fraction,
                verticalAnchor = 0f
            )
        }

        fun x(seconds: Double): Float {
            val span = max(0.001, maxT - minT)
            return chartLeft + (((seconds - minT) / span).toFloat() * chartWidth)
        }

        fun y(weight: Double): Float {
            val span = max(0.001, maxY - minY)
            return chartTop + chartHeight - (((weight - minY) / span).toFloat() * chartHeight)
        }

        fun flowY(flow: Double): Float {
            val span = max(0.001, maxFlow - minFlow)
            return chartTop + chartHeight - (((flow - minFlow) / span).toFloat() * chartHeight)
        }

        visibleGaps.forEach { gap ->
            val start = x(max(minT, gap.startSeconds))
            val end = x(min(maxT, gap.endSeconds))
            drawRect(
                color = warning.copy(alpha = 0.08f),
                topLeft = Offset(start, chartTop),
                size = Size(max(2f, end - start), chartHeight)
            )
        }

        val weightOffsets = visiblePoints.map { Offset(x(it.seconds), y(it.value)) }
        drawPath(
            catmullRomPath(weightOffsets, baseline = chartTop + chartHeight),
            color = primary.copy(alpha = 0.11f)
        )
        drawPath(
            catmullRomPath(weightOffsets),
            color = primary,
            style = Stroke(
                width = 2.dp.toPx(),
                cap = StrokeCap.Round,
                join = StrokeJoin.Round
            )
        )

        if (showsFlow) {
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatFlowAxis(maxFlow, includeUnit = true),
                style = axisStyle.copy(color = flowColor.copy(alpha = 0.86f)),
                anchor = Offset(chartLeft + chartWidth + 6.dp.toPx(), chartTop),
                horizontalAnchor = 0f,
                verticalAnchor = 0.5f
            )
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatFlowAxis(minFlow, includeUnit = false),
                style = axisStyle.copy(color = flowColor.copy(alpha = 0.86f)),
                anchor = Offset(chartLeft + chartWidth + 6.dp.toPx(), chartTop + chartHeight),
                horizontalAnchor = 0f,
                verticalAnchor = 0.5f
            )
            val flowOffsets = visibleFlowPoints.map { Offset(x(it.seconds), flowY(it.value)) }
            drawPath(
                catmullRomPath(flowOffsets),
                color = flowColor.copy(alpha = 0.82f),
                style = Stroke(
                    width = 1.5.dp.toPx(),
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round
                )
            )
        }

        visibleGaps.forEach { gap ->
                val start = x(max(minT, gap.startSeconds))
                val end = x(min(maxT, gap.endSeconds))
                drawLine(
                    color = warning.copy(alpha = 0.72f),
                    start = Offset(start, chartTop),
                    end = Offset(start, chartTop + chartHeight),
                    strokeWidth = 1.dp.toPx()
                )
                drawLine(
                    color = warning.copy(alpha = 0.72f),
                    start = Offset(end, chartTop),
                    end = Offset(end, chartTop + chartHeight),
                    strokeWidth = 1.dp.toPx()
                )
                if (end - start >= 58.dp.toPx()) {
                    drawChartLabel(
                        textMeasurer = textMeasurer,
                        text = formatGapDuration(gap.intervalMs),
                        style = axisStyle.copy(color = warning, fontWeight = FontWeight.SemiBold),
                        anchor = Offset((start + end) / 2f, chartTop + 4.dp.toPx()),
                        horizontalAnchor = 0.5f,
                        verticalAnchor = 0f
                    )
                }
        }
    }
    }
}

@Composable
private fun WeightStreamLegend(weightColor: Color, flowColor: Color) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        ChartLegendItem(color = weightColor, label = "Weight")
        ChartLegendItem(color = flowColor, label = "Reported flow")
    }
}

@Composable
private fun ChartLegendItem(color: Color, label: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Canvas(modifier = Modifier.size(8.dp)) {
            drawCircle(color)
        }
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
internal fun ChartPacketCadence(
    intervals: List<Double>,
    thresholdMs: Double
) {
    if (intervals.isEmpty()) {
        EmptyChart("Record at least two parsed samples to show cadence.")
        return
    }

    val primary = MaterialTheme.colorScheme.primary
    val warning = MaterialTheme.colorScheme.error
    val text = MaterialTheme.colorScheme.onSurfaceVariant
    val textMeasurer = rememberTextMeasurer()
    val axisStyle = MaterialTheme.typography.labelSmall.copy(
        color = text.copy(alpha = 0.78f),
        fontSize = 9.sp
    )
    val actualMaxInterval = intervals.maxOrNull() ?: thresholdMs
    val maxInterval = cadenceDisplayMax(intervals, thresholdMs)
    val hasClippedOutliers = actualMaxInterval > maxInterval
    val renderedIntervals = remember(intervals) {
        downsampleCadenceIntervals(intervals, maximumCount = 700)
    }
    val cadenceDescription = String.format(
        Locale.US,
        "Packet cadence chart, %d sample intervals, longest %.0f milliseconds, long gap threshold %.0f milliseconds%s",
        intervals.size,
        actualMaxInterval,
        thresholdMs,
        if (hasClippedOutliers) ", display scale capped so normal cadence remains visible" else ""
    )

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(150.dp)
            .semantics { contentDescription = cadenceDescription }
    ) {
        val chartLeft = 42.dp.toPx()
        val chartTop = 8.dp.toPx()
        val chartRight = 8.dp.toPx()
        val chartBottom = 24.dp.toPx()
        val chartWidth = max(1f, size.width - chartLeft - chartRight)
        val chartHeight = max(1f, size.height - chartTop - chartBottom)
        val barWidth = chartWidth / max(1, renderedIntervals.size).toFloat()
        val barGap = if (barWidth > 2.dp.toPx()) 1.dp.toPx() else 0f
        val gridColor = text.copy(alpha = 0.14f)

        (0..2).forEach { index ->
            val fraction = index / 2f
            val y = chartTop + chartHeight * fraction
            drawLine(
                color = gridColor,
                start = Offset(chartLeft, y),
                end = Offset(chartLeft + chartWidth, y),
                strokeWidth = 0.5.dp.toPx()
            )
            val milliseconds = maxInterval * (1f - fraction)
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatMillisecondsAxis(milliseconds, includeUnit = index == 0),
                style = axisStyle,
                anchor = Offset(chartLeft - 6.dp.toPx(), y),
                horizontalAnchor = 1f,
                verticalAnchor = 0.5f
            )
        }

        (0..2).forEach { index ->
            val fraction = index / 2f
            val x = chartLeft + chartWidth * fraction
            drawLine(
                color = gridColor,
                start = Offset(x, chartTop),
                end = Offset(x, chartTop + chartHeight),
                strokeWidth = 0.5.dp.toPx()
            )
            val sample = 1 + ((intervals.size - 1) * fraction).toInt()
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = sample.toString(),
                style = axisStyle,
                anchor = Offset(x, chartTop + chartHeight + 5.dp.toPx()),
                horizontalAnchor = fraction,
                verticalAnchor = 0f
            )
        }

        renderedIntervals.forEach { rendered ->
            val fraction = if (intervals.size <= 1) 0f else rendered.index.toFloat() / (intervals.size - 1).toFloat()
            val x = chartLeft + fraction * max(0f, chartWidth - barWidth)
            val plottedValue = min(rendered.value, maxInterval)
            val height = ((plottedValue / maxInterval).toFloat() * chartHeight).coerceIn(1f, chartHeight)
            val width = max(0.75f, barWidth - barGap)
            drawRoundRect(
                color = if (rendered.value >= thresholdMs) warning else primary.copy(alpha = 0.68f),
                topLeft = Offset(x, chartTop + chartHeight - height),
                size = Size(width, height),
                cornerRadius = CornerRadius(min(2.dp.toPx(), width / 2f))
            )
        }

        if (thresholdMs <= maxInterval) {
            val thresholdY = chartTop + chartHeight - ((thresholdMs / maxInterval).toFloat() * chartHeight)
            drawLine(
                color = warning.copy(alpha = 0.72f),
                start = Offset(chartLeft, thresholdY),
                end = Offset(chartLeft + chartWidth, thresholdY),
                strokeWidth = 1.dp.toPx()
            )
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = String.format(Locale.US, "%.0f ms limit", thresholdMs),
                style = axisStyle.copy(color = warning),
                anchor = Offset(chartLeft + chartWidth - 3.dp.toPx(), thresholdY - 3.dp.toPx()),
                horizontalAnchor = 1f,
                verticalAnchor = 1f
            )
        } else {
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = String.format(Locale.US, "%.0f ms limit above chart", thresholdMs),
                style = axisStyle.copy(color = warning),
                anchor = Offset(chartLeft + chartWidth - 3.dp.toPx(), chartTop + 3.dp.toPx()),
                horizontalAnchor = 1f,
                verticalAnchor = 0f
            )
        }
        if (hasClippedOutliers) {
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = "max ${formatCompactMilliseconds(actualMaxInterval)}",
                style = axisStyle.copy(color = warning, fontWeight = FontWeight.SemiBold),
                anchor = Offset(chartLeft + chartWidth - 3.dp.toPx(), chartTop + 3.dp.toPx()),
                horizontalAnchor = 1f,
                verticalAnchor = 0f
            )
        }
    }
}

@Composable
internal fun PacketEvidenceSummary(metrics: ScaleQualityMetrics, timeline: AndroidPacketTimeline) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        MetricChip("Packets", timeline.entries.size.toString())
        MetricChip("Rejected", metrics.rejectedPacketCount.toString())
        MetricChip("Gaps", metrics.longGapCount.toString())
        MetricChip("Warnings", timeline.warningCount.toString())
        MetricChip("Threshold", String.format(Locale.US, "%.0f ms", timeline.thresholdMs))
    }
}

@Composable
internal fun SignalDiagnosticsSection(diagnostics: AndroidSignalDiagnostics) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("Signal diagnostics", fontWeight = FontWeight.SemiBold)

            diagnostics.flowValidation?.let { flow ->
                SwiftMetricRow(
                    "Reported flow error",
                    String.format(Locale.US, "%.2f g/s median", flow.medianAbsoluteErrorGramsPerSecond)
                )
                flow.lagMilliseconds?.let { lag ->
                    SwiftMetricRow("Reported flow timing", flowLagDescription(lag))
                }
                Text(
                    "Compared ${flow.sampleCount} reported flow values with weight change measured across a centered 1-second window.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            diagnostics.clockSkew?.let { clock ->
                SwiftMetricRow("Scale clock drift", clockSkewDescription(clock.skewPartsPerMillion))
                Text(
                    "Compared the scale's free-running clock with the phone clock across ${clock.sampleCount} updates.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            diagnostics.packetCoalescing?.let { packet ->
                SwiftMetricRow(
                    "Frames per occupied slot",
                    String.format(Locale.US, "%.2fx", packet.framesPerServedSlot)
                )
                Text(
                    "Average weight frames received in each occupied 50 ms scoring slot. Values above 1 mean extra updates arrived together or faster than 20 Hz.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            diagnostics.streamQuality?.let { stream ->
                stream.effectiveOutputRateHz?.let { rate ->
                    SwiftMetricRow("Effective output rate", String.format(Locale.US, "%.1f Hz", rate))
                }
                if (stream.implausibleCount > 0) {
                    SwiftMetricRow("Impossible readings", stream.implausibleCount.toString())
                    stream.implausibleP95ErrorGrams?.let { p95 ->
                        SwiftMetricRow("Typical bad-reading size", String.format(Locale.US, "%.2f g p95", p95))
                    }
                    stream.implausibleMaxErrorGrams?.let { max ->
                        SwiftMetricRow("Largest impossible jump", String.format(Locale.US, "%.2f g", max))
                    }
                }
                val negativeCount = stream.activePourNegativeStepCount ?: 0
                if (negativeCount > 0) {
                    SwiftMetricRow("Backward pour steps", negativeCount.toString())
                    stream.activePourNegativeStepTotalGrams?.let { total ->
                        SwiftMetricRow("Backward pour motion", String.format(Locale.US, "%.2f g", total))
                    }
                }
                if (stream.duplicateRunMaxMilliseconds > 0.0) {
                    SwiftMetricRow("Longest frozen reading", formatCompactMilliseconds(stream.duplicateRunMaxMilliseconds))
                    stream.freezeThenReleaseMaxGrams?.let { release ->
                        SwiftMetricRow("Worst freeze release", String.format(Locale.US, "%.2f g", release))
                    }
                }
                Text(
                    "These are stream-quality checks, not calibration or physical accuracy measurements.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
internal fun ProblemAreasSection(
    points: List<ChartPoint>,
    flowPoints: List<ChartPoint>,
    timeline: AndroidPacketTimeline,
    windows: List<ChartWindow>
) {
    if (windows.isEmpty()) return

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Problem areas", fontWeight = FontWeight.SemiBold)
        Text(
            "Zoomed windows around the first scoring gaps or packet penalties.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        windows.forEach { window ->
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
            ) {
                Column(
                    modifier = Modifier.padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    SwiftMetricRow(
                        window.title,
                        "${formatSecondsValue(window.startSeconds)}-${formatSecondsValue(window.endSeconds)}"
                    )
                    ChartWeightStream(
                        points = points,
                        flowPoints = flowPoints,
                        thresholdMs = timeline.thresholdMs,
                        scoringGaps = timeline.scoringGaps,
                        durationSeconds = timeline.durationSeconds,
                        window = window
                    )
                    val largestGap = timeline.scoringGaps
                        .filter { it.startSeconds <= window.endSeconds && it.endSeconds >= window.startSeconds }
                        .maxByOrNull { it.intervalMs }
                    if (largestGap != null) {
                        Text(
                            "Red marks a ${formatGapDuration(largestGap.intervalMs)} without a weight update; the limit is ${formatThreshold(timeline.thresholdMs)}.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun PacketTimelineChart(
    timeline: AndroidPacketTimeline,
    selectedEntryId: Int? = null,
    onSelect: (AndroidPacketTimelineEntry) -> Unit = {}
) {
    if (timeline.entries.isEmpty()) {
        EmptyChart("No raw packets to show.")
        return
    }

    val text = MaterialTheme.colorScheme.onSurfaceVariant
    val warning = MaterialTheme.colorScheme.error
    val textMeasurer = rememberTextMeasurer()
    val axisStyle = MaterialTheme.typography.labelSmall.copy(
        color = text.copy(alpha = 0.78f),
        fontSize = 8.sp
    )
    val duration = max(0.001, timeline.durationSeconds)
    val compactEntries = remember(timeline.entries) {
        compactTimelineEntriesForDisplay(timeline.entries, maximumCount = 1_200)
    }
    val renderedGaps = remember(timeline.scoringGaps, duration) {
        compactScoringGapsForDisplay(timeline.scoringGaps, maximumCount = 220)
    }
    val selectedEntry = remember(timeline.entries, selectedEntryId) {
        timeline.entries.firstOrNull { it.id == selectedEntryId }
    }
    val renderedEntries = remember(compactEntries, selectedEntry) {
        if (selectedEntry == null || compactEntries.any { it.id == selectedEntry.id }) {
            compactEntries
        } else {
            (compactEntries + selectedEntry).sortedBy { it.relativeSeconds }
        }
    }
    var canvasSize by remember { mutableStateOf(IntSize.Zero) }
    val density = LocalDensity.current
    val chartLeftPx = with(density) { 52.dp.toPx() }
    val chartTopPx = with(density) { 20.dp.toPx() }
    val chartRightPx = with(density) { 8.dp.toPx() }
    val chartBottomPx = with(density) { 22.dp.toPx() }

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(132.dp)
            .semantics {
                contentDescription = "Packet timeline, ${timeline.entries.size} packets over ${String.format(Locale.US, "%.1f", duration)} seconds, ${timeline.scoringGaps.size} scoring gaps. Individual packets are available in the packet list below."
            }
            .onSizeChanged { canvasSize = it }
            .pointerInput(renderedEntries, canvasSize) {
                detectTapGestures { offset ->
                    nearestPacketEntry(
                        timeline = timeline,
                        entries = renderedEntries,
                        canvasSize = canvasSize,
                        offset = offset,
                        chartLeft = chartLeftPx,
                        chartTop = chartTopPx,
                        chartRight = chartRightPx,
                        chartBottom = chartBottomPx
                    )?.let(onSelect)
                }
            }
    ) {
        val chartLeft = chartLeftPx
        val chartTop = chartTopPx
        val chartWidth = max(1f, size.width - chartLeft - chartRightPx)
        val chartHeight = max(1f, size.height - chartTop - chartBottomPx)
        val lanes = AndroidPacketLane.values()
        val laneHeight = chartHeight / lanes.size.toFloat()

        (0..2).forEach { index ->
            val fraction = index / 2f
            val x = chartLeft + chartWidth * fraction
            drawLine(
                color = text.copy(alpha = 0.12f),
                start = Offset(x, chartTop),
                end = Offset(x, chartTop + chartHeight),
                strokeWidth = 0.5.dp.toPx()
            )
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatTimeAxis(duration * fraction),
                style = axisStyle,
                anchor = Offset(x, chartTop + chartHeight + 4.dp.toPx()),
                horizontalAnchor = fraction,
                verticalAnchor = 0f
            )
        }

        lanes.forEach { lane ->
            val y = chartTop + laneHeight * (lane.index + 0.5f)
            drawLine(
                color = text.copy(alpha = 0.18f),
                start = Offset(chartLeft, y),
                end = Offset(chartLeft + chartWidth, y),
                strokeWidth = 0.5.dp.toPx()
            )
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = packetLaneLabel(lane),
                style = axisStyle,
                anchor = Offset(chartLeft - 6.dp.toPx(), y),
                horizontalAnchor = 1f,
                verticalAnchor = 0.5f
            )
        }

        renderedGaps.forEach { gap ->
            val start = chartLeft + ((gap.startSeconds / duration).toFloat().coerceIn(0f, 1f) * chartWidth)
            val end = chartLeft + ((gap.endSeconds / duration).toFloat().coerceIn(0f, 1f) * chartWidth)
            drawRect(
                color = warning.copy(alpha = 0.08f),
                topLeft = Offset(min(start, end), chartTop),
                size = Size(max(2f, kotlin.math.abs(end - start)), chartHeight)
            )
            drawLine(
                color = warning.copy(alpha = 0.72f),
                start = Offset(start, chartTop),
                end = Offset(start, chartTop + chartHeight),
                strokeWidth = 1.dp.toPx()
            )
            drawLine(
                color = warning.copy(alpha = 0.72f),
                start = Offset(end, chartTop),
                end = Offset(end, chartTop + chartHeight),
                strokeWidth = 1.dp.toPx()
            )
        }

        timeline.scoringGaps.maxByOrNull { it.intervalMs }?.let { gap ->
            val centerFraction = (((gap.startSeconds + gap.endSeconds) / 2.0) / duration)
                .toFloat()
                .coerceIn(0f, 1f)
            val center = chartLeft + centerFraction * chartWidth
            val anchor = when {
                centerFraction < 0.18f -> 0f
                centerFraction > 0.82f -> 1f
                else -> 0.5f
            }
            drawChartLabel(
                textMeasurer = textMeasurer,
                text = formatGapDuration(gap.intervalMs),
                style = axisStyle.copy(color = warning, fontWeight = FontWeight.SemiBold),
                anchor = Offset(center, 2.dp.toPx()),
                horizontalAnchor = anchor,
                verticalAnchor = 0f
            )
        }

        renderedEntries.forEach { entry ->
            val x = chartLeft + ((entry.relativeSeconds / duration).toFloat().coerceIn(0f, 1f) * chartWidth)
            val y = chartTop + laneHeight * (entry.lane.index + 0.5f)
            val tickHeight = laneHeight * if (entry.severity == AndroidPacketSeverity.PENALTY) 0.86f else 0.62f
            val saturatedColor = packetColor(entry)
            val timelineColor = when (entry.severity) {
                AndroidPacketSeverity.PENALTY -> saturatedColor
                AndroidPacketSeverity.WARNING -> saturatedColor.copy(alpha = 0.82f)
                AndroidPacketSeverity.INFO,
                AndroidPacketSeverity.NORMAL -> saturatedColor.copy(alpha = 0.55f)
            }
            if (entry.id == selectedEntryId) {
                drawCircle(
                    color = saturatedColor.copy(alpha = 0.18f),
                    radius = max(4.dp.toPx(), laneHeight * 0.42f),
                    center = Offset(x, y)
                )
                drawCircle(
                    color = saturatedColor,
                    radius = max(2.dp.toPx(), laneHeight * 0.16f),
                    center = Offset(x, y)
                )
            }
            drawLine(
                color = timelineColor,
                start = Offset(x, y - tickHeight / 2f),
                end = Offset(x, y + tickHeight / 2f),
                strokeWidth = if (entry.severity == AndroidPacketSeverity.PENALTY) 2.dp.toPx() else 1.dp.toPx(),
                cap = StrokeCap.Round
            )
        }
    }
}

@Composable
internal fun PacketLegend(timeline: AndroidPacketTimeline) {
    val summary = remember(timeline.entries, timeline.scoringGaps, timeline.thresholdMs) {
        packetLegendSummary(timeline)
    }
    Text(
        summary,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
internal fun LegendDot(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Canvas(modifier = Modifier.size(8.dp)) {
            drawCircle(color = color)
        }
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun packetLegendSummary(timeline: AndroidPacketTimeline): String {
    val warningCount = timeline.entries.count { it.severity == AndroidPacketSeverity.WARNING }
    val penaltyCount = timeline.entries.count { it.severity == AndroidPacketSeverity.PENALTY }
    val metadataCount = timeline.entries.count { it.roleLabel.lowercase(Locale.US) != "weight" }
    val parts = mutableListOf("Blue ticks are weight packets.")
    if (metadataCount > 0) parts += "Other colors are metadata or unknown packets."
    if (warningCount > 0 || penaltyCount > 0) parts += "Orange/red ticks need attention."
    timeline.scoringGaps.maxByOrNull { it.intervalMs }?.let { largestGap ->
        parts += "Red highlights mark waits of ${formatThreshold(timeline.thresholdMs)} or more between weight updates; the longest was a ${formatGapDuration(largestGap.intervalMs)}."
    }
    return parts.joinToString(" ")
}

@Composable
internal fun PacketInspectorPreview(
    timeline: AndroidPacketTimeline,
    selectedEntryId: Int? = null,
    onSelect: (AndroidPacketTimelineEntry) -> Unit = {}
) {
    if (timeline.entries.isEmpty()) return
    var badOnly by remember(timeline.entries) { mutableStateOf(false) }
    val inspectorEntries = remember(timeline.entries, badOnly) {
        if (badOnly) timeline.entries.filter { it.isBadForInspector() } else timeline.entries
    }
    val defaultEntry = remember(inspectorEntries) {
        inspectorEntries.firstOrNull { it.severity == AndroidPacketSeverity.PENALTY }
            ?: inspectorEntries.firstOrNull { it.severity == AndroidPacketSeverity.WARNING }
            ?: inspectorEntries.firstOrNull()
    }
    val selected = inspectorEntries.firstOrNull { it.id == selectedEntryId } ?: defaultEntry

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Packet inspector", fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (badOnly) {
                    Button(onClick = { badOnly = false }) { Text("All") }
                } else {
                    OutlinedButton(onClick = { badOnly = true }) { Text("Bad only") }
                }
            }
        }
        if (inspectorEntries.isEmpty()) {
            Text(
                "No bad raw packets in this recording. Delivered packets, usable readings, and packet checks are explained in the Score section.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(6.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.28f)
            ) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height((max(1, min(7, inspectorEntries.size)) * 40).dp),
                    contentPadding = PaddingValues(vertical = 2.dp)
                ) {
                    items(inspectorEntries, key = { it.id }) { entry ->
                        PacketInspectorRow(
                            entry = entry,
                            thresholdMs = timeline.thresholdMs,
                            isSelected = selected?.id == entry.id,
                            onClick = { onSelect(entry) }
                        )
                    }
                }
            }
            Text(
                if (badOnly) "${inspectorEntries.size} bad packets" else "${inspectorEntries.size} packets",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            if (selected != null) {
                PacketDetailCard(entry = selected)
            }
        }
    }
}

@Composable
private fun PacketInspectorRow(
    entry: AndroidPacketTimelineEntry,
    thresholdMs: Double,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    val background = if (isSelected) packetColor(entry).copy(alpha = 0.14f) else Color.Transparent
    val intervalDescription = entry.intervalMs?.let { String.format(Locale.US, "%.0f milliseconds", it) } ?: "first packet"
    val rowDescription = "${formatSecondsValue(entry.relativeSeconds)}, ${packetEventLabel(entry, thresholdMs)}, $intervalDescription"
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .semantics {
                contentDescription = rowDescription
                role = Role.Button
                selected = isSelected
            }
            .clickable(onClick = onClick),
        color = background
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Canvas(modifier = Modifier.size(7.dp)) {
                drawCircle(packetColor(entry))
            }
            Text(
                formatSecondsValue(entry.relativeSeconds),
                modifier = Modifier.width(68.dp),
                style = MaterialTheme.typography.labelMedium,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1
            )
            Text(
                packetEventLabel(entry, thresholdMs),
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1
            )
            Text(
                entry.intervalMs?.let { String.format(Locale.US, "%.0f ms", it) } ?: "start",
                modifier = Modifier.width(48.dp),
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }
    }
}

private fun packetEventLabel(entry: AndroidPacketTimelineEntry, thresholdMs: Double): String {
    entry.rejectionReason?.let { return humanizePacketValue(it) }
    if (entry.intervalMs != null && entry.intervalMs >= thresholdMs) return "long packet interval"
    if (entry.severity == AndroidPacketSeverity.WARNING && entry.intervalMs != null) return "near gap threshold"
    return when (entry.roleLabel.lowercase(Locale.US)) {
        "weight" -> entry.weightGrams?.let { String.format(Locale.US, "weight %.2f g", it) } ?: "weight update"
        "battery" -> "battery update"
        "capabilities" -> "capabilities"
        "commandack" -> "command acknowledgement"
        else -> "unknown packet"
    }
}

private fun humanizePacketValue(value: String): String {
    return value
        .replace(Regex("([a-z])([A-Z])"), "$1 $2")
        .replace('_', ' ')
        .lowercase(Locale.US)
}

private fun AndroidPacketTimelineEntry.isBadForInspector(): Boolean {
    return severity == AndroidPacketSeverity.WARNING || severity == AndroidPacketSeverity.PENALTY
}

@Composable
internal fun PacketDetailCard(entry: AndroidPacketTimelineEntry) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = packetColor(entry).copy(alpha = 0.13f)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Canvas(modifier = Modifier.size(14.dp)) {
                        drawCircle(packetColor(entry))
                    }
                    Text(entry.roleLabel, fontWeight = FontWeight.SemiBold, color = packetColor(entry))
                }
                Text(formatSecondsValue(entry.relativeSeconds), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            entry.evidence.forEach { evidence ->
                Text(
                    evidence,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (entry.severity == AndroidPacketSeverity.PENALTY) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    }
                )
            }

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                MetricChip("Severity", entry.severity.label)
                MetricChip("Lane", entry.lane.name.lowercase(Locale.ROOT))
                MetricChip("Interval", entry.intervalMs?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--")
                entry.sequence?.let { MetricChip("Seq", it.toString()) }
                entry.weightGrams?.let { MetricChip("Weight", String.format(Locale.US, "%.2f g", it)) }
                entry.rejectionReason?.let { MetricChip("Rejected", it) }
            }

            if (entry.characteristicUuid.isNotBlank()) {
                Text(
                    entry.characteristicUuid,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (entry.bytesHex.isNotBlank()) {
                SelectionContainer {
                    Text(
                        annotatedPacketHex(entry, MaterialTheme.colorScheme.onSurfaceVariant),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
            if (entry.fields.isNotEmpty()) {
                HorizontalDivider()
                entry.fields.forEach { field ->
                    PacketFieldRow(field)
                }
            }
        }
    }
}

@Composable
private fun PacketFieldRow(field: PacketFieldAnnotation) {
    val fieldColor = packetFieldColor(field.semantic, Color.Gray)
    val isLongValue = field.decodedValue.length > 18
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            Canvas(modifier = Modifier.size(7.dp)) {
                drawCircle(fieldColor)
            }
            Text(
                field.label,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
            if (!isLongValue) {
                Text(
                    field.decodedValue,
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1
                )
            }
        }
        if (isLongValue) {
            Text(
                field.decodedValue,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 14.dp),
                style = MaterialTheme.typography.labelMedium,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun annotatedPacketHex(entry: AndroidPacketTimelineEntry, fallback: Color): AnnotatedString {
    val bytes = ScaleParsers.parseHex(entry.bytesHex) ?: return AnnotatedString(entry.bytesHex)
    return buildAnnotatedString {
        bytes.forEachIndexed { index, byte ->
            val field = entry.fields.firstOrNull { it.startByte <= index && index < it.endByteExclusive }
            withStyle(SpanStyle(color = packetFieldColor(field?.semantic, fallback))) {
                append(String.format(Locale.US, "%02X", byte.toInt() and 0xFF))
            }
            if (index < bytes.lastIndex) append(if ((index + 1) % 10 == 0) "\n" else " ")
        }
    }
}

private fun packetFieldColor(semantic: PacketFieldSemantic?, fallback: Color): Color = when (semantic) {
    PacketFieldSemantic.HEADER -> Color(0xFF1E88E5)
    PacketFieldSemantic.TIMESTAMP -> Color(0xFF00ACC1)
    PacketFieldSemantic.WEIGHT -> Color(0xFF43A047)
    PacketFieldSemantic.FLOW -> Color(0xFF00897B)
    PacketFieldSemantic.BATTERY -> Color(0xFFF9A825)
    PacketFieldSemantic.SEQUENCE -> Color(0xFF8E24AA)
    PacketFieldSemantic.STATUS -> Color(0xFFFB8C00)
    PacketFieldSemantic.QUALITY -> Color(0xFF5C6BC0)
    PacketFieldSemantic.SAMPLE_RATE -> Color(0xFF00897B)
    PacketFieldSemantic.CHECKSUM -> Color(0xFFE53935)
    PacketFieldSemantic.UNIT -> Color(0xFFD81B60)
    PacketFieldSemantic.PAYLOAD, null -> fallback
}

internal fun defaultPacketEntry(timeline: AndroidPacketTimeline): AndroidPacketTimelineEntry? {
    return timeline.entries.firstOrNull { it.severity == AndroidPacketSeverity.PENALTY }
        ?: timeline.entries.firstOrNull { it.severity == AndroidPacketSeverity.WARNING }
        ?: timeline.entries.firstOrNull()
}

internal fun nearestPacketEntry(
    timeline: AndroidPacketTimeline,
    entries: List<AndroidPacketTimelineEntry> = timeline.entries,
    canvasSize: IntSize,
    offset: Offset,
    chartLeft: Float = 10f,
    chartTop: Float = 10f,
    chartRight: Float = 10f,
    chartBottom: Float = 10f
): AndroidPacketTimelineEntry? {
    if (entries.isEmpty() || canvasSize.width <= 0 || canvasSize.height <= 0) return null
    val chartWidth = canvasSize.width - chartLeft - chartRight
    val chartHeight = canvasSize.height - chartTop - chartBottom
    if (chartWidth <= 0f || chartHeight <= 0f) return null
    val lanes = AndroidPacketLane.values()
    val laneHeight = chartHeight / lanes.size.toFloat()
    val duration = max(0.001, timeline.durationSeconds)
    val horizontalTolerance = max(18f, chartWidth / max(1, entries.size) * 2.5f)
    val verticalTolerance = max(16f, laneHeight * 0.55f)

    return entries.minByOrNull { entry ->
        val x = chartLeft + ((entry.relativeSeconds / duration).toFloat().coerceIn(0f, 1f) * chartWidth)
        val y = chartTop + laneHeight * (entry.lane.index + 0.5f)
        abs(offset.x - x) + abs(offset.y - y) * 1.8f
    }?.takeIf { entry ->
        val x = chartLeft + ((entry.relativeSeconds / duration).toFloat().coerceIn(0f, 1f) * chartWidth)
        val y = chartTop + laneHeight * (entry.lane.index + 0.5f)
        abs(offset.x - x) <= horizontalTolerance && abs(offset.y - y) <= verticalTolerance
    }
}

private data class RenderedCadenceInterval(val index: Int, val value: Double)

private fun cadenceDisplayMax(intervals: List<Double>, thresholdMs: Double): Double {
    val actualMax = intervals.maxOrNull() ?: thresholdMs
    val percentile95 = percentile(intervals, 0.95) ?: actualMax
    val usefulScale = max(thresholdMs * 1.25, percentile95 * 1.35)
    return min(actualMax, usefulScale)
}

private fun downsampleChartPointsForDisplay(points: List<ChartPoint>, maximumCount: Int): List<ChartPoint> {
    if (maximumCount < 4 || points.size <= maximumCount) return points
    val interiorCount = points.size - 2
    val bucketCount = max(1, (maximumCount - 2) / 2)
    val result = ArrayList<ChartPoint>(maximumCount)
    result += points.first()
    for (bucket in 0 until bucketCount) {
        val lower = 1 + (bucket.toDouble() * interiorCount / bucketCount).toInt()
        val upper = 1 + ((bucket + 1).toDouble() * interiorCount / bucketCount).toInt()
        if (lower >= upper) continue
        var minimumIndex = lower
        var maximumIndex = lower
        for (index in (lower + 1) until upper) {
            if (points[index].value < points[minimumIndex].value) minimumIndex = index
            if (points[index].value > points[maximumIndex].value) maximumIndex = index
        }
        when {
            minimumIndex == maximumIndex -> result += points[minimumIndex]
            minimumIndex < maximumIndex -> {
                result += points[minimumIndex]
                result += points[maximumIndex]
            }
            else -> {
                result += points[maximumIndex]
                result += points[minimumIndex]
            }
        }
    }
    result += points.last()
    return result
}

private fun downsampleCadenceIntervals(
    intervals: List<Double>,
    maximumCount: Int
): List<RenderedCadenceInterval> {
    if (maximumCount <= 0) return emptyList()
    if (intervals.size <= maximumCount) {
        return intervals.mapIndexed { index, value -> RenderedCadenceInterval(index, value) }
    }
    return (0 until maximumCount).mapNotNull { bucket ->
        val lower = (bucket.toDouble() * intervals.size / maximumCount).toInt()
        val upper = ((bucket + 1).toDouble() * intervals.size / maximumCount).toInt()
        if (lower >= upper) return@mapNotNull null
        var largestIndex = lower
        for (index in (lower + 1) until upper) {
            if (intervals[index] > intervals[largestIndex]) largestIndex = index
        }
        RenderedCadenceInterval(largestIndex, intervals[largestIndex])
    }
}

private fun compactTimelineEntriesForDisplay(
    entries: List<AndroidPacketTimelineEntry>,
    maximumCount: Int
): List<AndroidPacketTimelineEntry> {
    if (maximumCount <= 0) return emptyList()
    if (entries.size <= maximumCount) return entries
    val important = entries.filter {
        it.severity == AndroidPacketSeverity.WARNING || it.severity == AndroidPacketSeverity.PENALTY
    }
    val regular = entries.filter {
        it.severity != AndroidPacketSeverity.WARNING && it.severity != AndroidPacketSeverity.PENALTY
    }
    val regularBudget = max(0, maximumCount - important.size)
    if (regularBudget == 0) return important.sortedBy { it.relativeSeconds }

    var sampled = AndroidPacketLane.values().flatMap { lane ->
        val laneEntries = regular.filter { it.lane == lane }
        if (laneEntries.isEmpty()) {
            emptyList()
        } else {
            val proportional = (
                laneEntries.size.toDouble() / max(regular.size, 1).toDouble() * regularBudget
            ).toInt().coerceAtLeast(1)
            evenlySample(laneEntries, proportional)
        }
    }
    if (sampled.size > regularBudget) {
        sampled = evenlySample(sampled.sortedBy { it.relativeSeconds }, regularBudget)
    }
    return (important + sampled).distinctBy { it.id }.sortedBy { it.relativeSeconds }
}

private fun compactScoringGapsForDisplay(
    gaps: List<AndroidScoringGap>,
    maximumCount: Int
): List<AndroidScoringGap> {
    if (maximumCount <= 0) return emptyList()
    if (gaps.size <= maximumCount) return gaps
    val keepLargestCount = max(1, maximumCount / 2)
    val largest = gaps
        .sortedByDescending { it.intervalMs }
        .take(keepLargestCount)
    val sampled = evenlySample(gaps.sortedBy { it.startSeconds }, maximumCount - largest.size)
    return (largest + sampled)
        .distinctBy { it.index }
        .sortedBy { it.startSeconds }
}

private fun <T> evenlySample(values: List<T>, maximumCount: Int): List<T> {
    if (maximumCount <= 0) return emptyList()
    if (values.size <= maximumCount) return values
    if (maximumCount == 1) return listOf(values[values.size / 2])
    return (0 until maximumCount).map { index ->
        val sourceIndex = (
            index.toDouble() * (values.size - 1).toDouble() / (maximumCount - 1).toDouble()
        ).toInt()
        values[sourceIndex]
    }
}

private fun percentile(values: List<Double>, fraction: Double): Double? {
    if (values.isEmpty()) return null
    val sorted = values.sorted()
    val index = ((sorted.size - 1) * fraction.coerceIn(0.0, 1.0)).toInt()
    return sorted[index]
}

private fun catmullRomPath(points: List<Offset>, baseline: Float? = null): Path {
    val path = Path()
    if (points.isEmpty()) return path
    path.moveTo(points.first().x, points.first().y)
    if (points.size == 2) {
        path.lineTo(points.last().x, points.last().y)
    } else {
        for (index in 0 until points.lastIndex) {
            val p0 = points[max(0, index - 1)]
            val p1 = points[index]
            val p2 = points[index + 1]
            val p3 = points[min(points.lastIndex, index + 2)]
            path.cubicTo(
                p1.x + (p2.x - p0.x) / 6f,
                p1.y + (p2.y - p0.y) / 6f,
                p2.x - (p3.x - p1.x) / 6f,
                p2.y - (p3.y - p1.y) / 6f,
                p2.x,
                p2.y
            )
        }
    }
    if (baseline != null) {
        path.lineTo(points.last().x, baseline)
        path.lineTo(points.first().x, baseline)
        path.close()
    }
    return path
}

private fun DrawScope.drawChartLabel(
    textMeasurer: TextMeasurer,
    text: String,
    style: TextStyle,
    anchor: Offset,
    horizontalAnchor: Float,
    verticalAnchor: Float
) {
    val layout = textMeasurer.measure(text = text, style = style)
    drawText(
        textLayoutResult = layout,
        topLeft = Offset(
            anchor.x - layout.size.width * horizontalAnchor,
            anchor.y - layout.size.height * verticalAnchor
        )
    )
}

private fun formatWeightAxis(value: Double, includeUnit: Boolean): String {
    val format = if (abs(value) >= 10) "%.0f" else "%.1f"
    return String.format(Locale.US, format + if (includeUnit) " g" else "", value)
}

private fun formatFlowAxis(value: Double, includeUnit: Boolean): String {
    val format = if (abs(value) >= 10) "%.0f" else "%.1f"
    return String.format(Locale.US, format + if (includeUnit) " g/s" else "", value)
}

private fun formatMillisecondsAxis(value: Double, includeUnit: Boolean): String {
    return String.format(Locale.US, "%.0f%s", value, if (includeUnit) " ms" else "")
}

private fun formatGapDuration(milliseconds: Double): String {
    return if (milliseconds >= 1_000.0) {
        String.format(Locale.US, "%.2f s gap", milliseconds / 1_000.0)
    } else {
        String.format(Locale.US, "%.0f ms gap", milliseconds)
    }
}

private fun formatCompactMilliseconds(milliseconds: Double): String {
    return if (milliseconds >= 1_000.0) {
        String.format(Locale.US, "%.2f s", milliseconds / 1_000.0)
    } else {
        String.format(Locale.US, "%.0f ms", milliseconds)
    }
}

private fun formatThreshold(milliseconds: Double): String =
    String.format(Locale.US, "%.0f ms", milliseconds)

internal fun weightChartExplanation(thresholdMs: Double, hasFlow: Boolean): String {
    val flow = if (hasFlow) {
        " Purple is flow reported by the scale, shown on its own g/s scale."
    } else {
        ""
    }
    return "Cyan is measured weight over time.$flow Red highlights mark waits of ${formatThreshold(thresholdMs)} or more for the next weight update."
}

internal fun cadenceChartExplanation(intervals: List<Double>, thresholdMs: Double): String {
    val largestGap = intervals.filter { it >= thresholdMs }.maxOrNull()
    val detail = largestGap?.let { " The longest red bar marks a ${formatGapDuration(it)}." }.orEmpty()
    return "Each bar is the wait for the next weight update. Red bars crossed the ${formatThreshold(thresholdMs)} limit.$detail"
}

private fun formatTimeAxis(value: Double): String {
    val format = if (value >= 10) "%.0f s" else "%.1f s"
    return String.format(Locale.US, format, value)
}

private fun flowLagDescription(milliseconds: Double): String {
    if (abs(milliseconds) < 25.0) return "Aligned with weight"
    return String.format(
        Locale.US,
        "%.0f ms %s weight",
        abs(milliseconds),
        if (milliseconds > 0) "behind" else "ahead of"
    )
}

private fun clockSkewDescription(ppm: Double): String {
    val secondsPerHour = ppm * 3_600.0 / 1_000_000.0
    return String.format(Locale.US, "%+.0f ppm (%+.2f s/hour)", ppm, secondsPerHour)
}

private fun packetLaneLabel(lane: AndroidPacketLane): String = when (lane) {
    AndroidPacketLane.WEIGHT -> "weight"
    AndroidPacketLane.METADATA -> "metadata"
    AndroidPacketLane.CONTROL -> "control"
    AndroidPacketLane.PENALTY -> "penalty"
    AndroidPacketLane.UNKNOWN -> "other"
}

internal fun packetColor(entry: AndroidPacketTimelineEntry): Color = when (entry.severity) {
    AndroidPacketSeverity.PENALTY -> Color(0xFFD32F2F)
    AndroidPacketSeverity.WARNING -> Color(0xFFF57C00)
    AndroidPacketSeverity.INFO -> when (entry.lane) {
        AndroidPacketLane.METADATA -> Color(0xFF2E7D32)
        AndroidPacketLane.CONTROL -> Color(0xFF7B1FA2)
        else -> Color(0xFF757575)
    }
    AndroidPacketSeverity.NORMAL -> when (entry.lane) {
        AndroidPacketLane.WEIGHT -> Color(0xFF1976D2)
        AndroidPacketLane.METADATA -> Color(0xFF2E7D32)
        AndroidPacketLane.CONTROL -> Color(0xFF7B1FA2)
        AndroidPacketLane.UNKNOWN -> Color(0xFF757575)
        AndroidPacketLane.PENALTY -> Color(0xFFD32F2F)
    }
}

@Composable
internal fun EmptyChart(message: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(110.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
