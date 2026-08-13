package app.scalebench.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.util.Locale

internal data class AndroidProtocolComparisonRow(
    val id: String,
    val title: String,
    val protocolKind: ScaleKind,
    val mode: RecordingMode,
    val platform: String?,
    val score: Int?,
    val verificationCoveragePercent: Int?,
    val purityIsUpperBound: Boolean,
    val sampleRateHz: Double?,
    val p95IntervalMilliseconds: Double?,
    val maxGapMilliseconds: Double?,
    val longGapCount: Int,
    val rejectedPacketCount: Int,
    val sampleCount: Int
)

internal data class AndroidProtocolComparison(val rows: List<AndroidProtocolComparisonRow>) {
    val bestOverall: AndroidProtocolComparisonRow?
        get() = rows.filter { !it.purityIsUpperBound }.maxByOrNull { it.score ?: -1 }

    companion object {
        fun from(recordings: List<SavedRecordingSummary>): AndroidProtocolComparison {
            return AndroidProtocolComparison(
                recordings.map { saved ->
                    AndroidProtocolComparisonRow(
                        id = saved.id,
                        title = saved.title,
                        protocolKind = saved.protocolKind,
                        mode = saved.mode,
                        platform = saved.platform,
                        score = saved.score,
                        verificationCoveragePercent = saved.verificationCoveragePercent,
                        purityIsUpperBound = saved.purityIsUpperBound,
                        sampleRateHz = saved.sampleRateHz,
                        p95IntervalMilliseconds = saved.p95IntervalMilliseconds,
                        maxGapMilliseconds = saved.maxGapMilliseconds,
                        longGapCount = saved.longGapCount,
                        rejectedPacketCount = saved.rejectedPacketCount,
                        sampleCount = saved.sampleCount
                    )
                }.sortedWith(compareByDescending<AndroidProtocolComparisonRow> { it.score ?: -1 }.thenBy { it.title })
            )
        }
    }
}

@Composable
internal fun ProtocolComparisonSection(recordings: List<SavedRecordingSummary>) {
    val comparison = AndroidProtocolComparison.from(recordings)
    SectionCard("Protocol comparison") {
        if (comparison.rows.size < 2) {
            Text(
                "Save or load two recordings to compare protocols side by side.",
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
            comparison.rows.forEach { row ->
                ProtocolComparisonCard(row)
            }
        }
    }
}

@Composable
private fun ProtocolComparisonCard(row: AndroidProtocolComparisonRow) {
    OutlinedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(row.title, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${row.protocolKind.displayName} · ${row.mode.displayName} · ${platformDisplayName(row.platform)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.width(12.dp))
                Text(
                    row.score?.let { "${if (row.purityIsUpperBound) "≤" else ""}$it/100" } ?: "--",
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
            }
            Text(
                "${row.sampleCount} samples · ${formatRate(row.sampleRateHz)} · p95 ${formatMillis(row.p95IntervalMilliseconds)} · max ${formatMillis(row.maxGapMilliseconds)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                "Checks ${protocolDetailDisplay(row.verificationCoveragePercent?.let { Math.round(it * 5.0 / 100.0).toInt() }, 5)} · gaps ${row.longGapCount} · rejected ${row.rejectedPacketCount}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun formatRate(value: Double?): String {
    return value?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--"
}

private fun formatMillis(value: Double?): String {
    return value?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--"
}

internal data class AndroidTransportComparisonPoint(
    val seconds: Double,
    val weightGrams: Double
)

internal data class AndroidTransportComparisonRow(
    val id: String,
    val title: String,
    val detail: String,
    val isOfficial: Boolean,
    val packetCount: Int,
    val rateHz: Double?,
    val medianIntervalMilliseconds: Double?,
    val p95IntervalMilliseconds: Double?,
    val maxGapMilliseconds: Double?,
    val matchedReferenceCount: Int?,
    val medianLagMilliseconds: Double?,
    val medianAbsoluteDeltaGrams: Double?
)

internal data class AndroidTransportComparison(val rows: List<AndroidTransportComparisonRow>) {
    val isVisible: Boolean
        get() = rows.size > 1

    companion object {
        fun from(recording: ScaleRecording): AndroidTransportComparison {
            val streams = transportStreams(recording)
            if (streams.size <= 1) return AndroidTransportComparison(emptyList())
            val referenceKey = streams.entries
                .filter { it.key.isOfficial }
                .maxByOrNull { it.value.size }
                ?.key ?: streams.entries.maxBy { it.value.size }.key
            val referencePoints = streams[referenceKey].orEmpty().sortedBy { it.seconds }
            val allSeconds = streams.values.flatten().map { it.seconds }
            val start = recording.recordingStartMonotonicSeconds ?: allSeconds.minOrNull() ?: 0.0
            val end = recording.recordingEndMonotonicSeconds ?: allSeconds.maxOrNull() ?: start
            val duration = (end - start).coerceAtLeast(0.0)
            return AndroidTransportComparison(
                streams.map { (key, points) ->
                    makeRow(
                        key = key,
                        points = points.sortedBy { it.seconds },
                        referencePoints = referencePoints,
                        durationSeconds = duration,
                        isReference = key == referenceKey
                    )
                }.sortedWith(
                    compareByDescending<AndroidTransportComparisonRow> { it.isOfficial }
                        .thenByDescending { it.packetCount }
                        .thenBy { it.title }
                )
            )
        }

        private fun makeRow(
            key: AndroidTransportStreamKey,
            points: List<AndroidTransportComparisonPoint>,
            referencePoints: List<AndroidTransportComparisonPoint>,
            durationSeconds: Double,
            isReference: Boolean
        ): AndroidTransportComparisonRow {
            val intervals = points.zipWithNext { previous, current ->
                ((current.seconds - previous.seconds) * 1000.0).coerceAtLeast(0.0)
            }
            val alignment = if (isReference) null else compare(points, referencePoints)
            return AndroidTransportComparisonRow(
                id = key.id,
                title = key.title,
                detail = key.detail,
                isOfficial = key.isOfficial,
                packetCount = points.size,
                rateHz = if (durationSeconds > 0.0) points.size / durationSeconds else null,
                medianIntervalMilliseconds = percentile(intervals, 0.50),
                p95IntervalMilliseconds = percentile(intervals, 0.95),
                maxGapMilliseconds = intervals.maxOrNull(),
                matchedReferenceCount = alignment?.matchedCount,
                medianLagMilliseconds = alignment?.medianLagMilliseconds,
                medianAbsoluteDeltaGrams = alignment?.medianAbsoluteDeltaGrams
            )
        }

        private fun transportStreams(recording: ScaleRecording): Map<AndroidTransportStreamKey, List<AndroidTransportComparisonPoint>> {
            val result = linkedMapOf<AndroidTransportStreamKey, MutableList<AndroidTransportComparisonPoint>>()
            recording.rawPackets.forEach { packet ->
                val decoded = decodeTransportPoint(packet, recording) ?: return@forEach
                result.getOrPut(decoded.first) { mutableListOf() }.add(decoded.second)
            }
            return result
        }

        private fun decodeTransportPoint(
            packet: RawScalePacket,
            recording: ScaleRecording
        ): Pair<AndroidTransportStreamKey, AndroidTransportComparisonPoint>? {
            if (packet.rejectionReason != null) return null
            val uuid = packet.characteristicUuid?.uppercase(Locale.US) ?: ""
            val bytes = bytesFromHex(packet.bytesHex ?: "")

            if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_WEIGHT20_UUID) && bytes.size == 20) {
                val extended = recording.device?.kind == ScaleKind.WEIGH_MY_BRU_PLUS ||
                    packet.scaleKind == ScaleKind.WEIGH_MY_BRU_PLUS ||
                    u(bytes[5]) == 0x01
                val key = AndroidTransportStreamKey(
                    id = "wmb-20-byte",
                    title = if (extended) "WMB+ 20-byte" else "WMB 20-byte",
                    detail = "Official benchmark stream",
                    isOfficial = true
                )
                return key to AndroidTransportComparisonPoint(
                    seconds = packet.monotonicSeconds,
                    weightGrams = signedCentiValue(u(bytes[6]), u(bytes[7]), u(bytes[8]), u(bytes[9]))
                )
            }

            if (ScaleParsers.uuidMatches(uuid, ScaleParsers.WMB_FLOAT32_UUID) && bytes.size == 4) {
                val raw = u(bytes[0]) or (u(bytes[1]) shl 8) or (u(bytes[2]) shl 16) or (u(bytes[3]) shl 24)
                val value = Float.fromBits(raw)
                if (!value.isFinite()) return null
                val key = AndroidTransportStreamKey(
                    id = "bean-conqueror-float32",
                    title = "Bean Conqueror Float32",
                    detail = "Compatibility stream; not used for official scoring when 20-byte data is present",
                    isOfficial = false
                )
                return key to AndroidTransportComparisonPoint(packet.monotonicSeconds, value.toDouble())
            }

            if (isBookooWeightPacket(packet, uuid, bytes)) {
                val kind = normalizedBookooKind(if (packet.scaleKind == ScaleKind.UNKNOWN) recording.device?.kind else packet.scaleKind)
                val key = AndroidTransportStreamKey(
                    id = "bookoo-${kind.name}-${ScaleParsers.shortUuid(uuid)}",
                    title = "${kind.displayName} 20-byte",
                    detail = "Native BooKoo benchmark stream",
                    isOfficial = true
                )
                return key to AndroidTransportComparisonPoint(
                    seconds = packet.monotonicSeconds,
                    weightGrams = signedCentiValue(u(bytes[6]), u(bytes[7]), u(bytes[8]), u(bytes[9]))
                )
            }

            return null
        }

        private fun compare(
            points: List<AndroidTransportComparisonPoint>,
            referencePoints: List<AndroidTransportComparisonPoint>
        ): AndroidTransportAlignment {
            if (points.isEmpty() || referencePoints.isEmpty()) return AndroidTransportAlignment(0, null, null)
            var referenceIndex = 0
            val lags = mutableListOf<Double>()
            val deltas = mutableListOf<Double>()
            points.forEach { point ->
                while (
                    referenceIndex + 1 < referencePoints.size &&
                    kotlin.math.abs(referencePoints[referenceIndex + 1].seconds - point.seconds) <
                    kotlin.math.abs(referencePoints[referenceIndex].seconds - point.seconds)
                ) {
                    referenceIndex += 1
                }
                val reference = referencePoints[referenceIndex]
                val lag = point.seconds - reference.seconds
                if (kotlin.math.abs(lag) <= 0.080) {
                    lags.add(lag * 1000.0)
                    deltas.add(kotlin.math.abs(point.weightGrams - reference.weightGrams))
                }
            }
            return AndroidTransportAlignment(
                matchedCount = lags.size,
                medianLagMilliseconds = percentile(lags, 0.50),
                medianAbsoluteDeltaGrams = percentile(deltas, 0.50)
            )
        }

        private fun bytesFromHex(hex: String): ByteArray {
            val cleaned = hex.filter { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
            if (cleaned.length % 2 != 0) return ByteArray(0)
            return ByteArray(cleaned.length / 2) { index ->
                cleaned.substring(index * 2, index * 2 + 2).toInt(16).toByte()
            }
        }

        private fun isBookooWeightPacket(packet: RawScalePacket, uuid: String, bytes: ByteArray): Boolean {
            if (bytes.size != 20 || u(bytes[0]) != 0x03 || u(bytes[1]) != 0x0B) return false
            if (ScaleParsers.uuidMatches(uuid, ScaleParsers.BOOKOO_NOTIFY_UUID)) return true
            return packet.scaleKind == ScaleKind.BOOKOO ||
                packet.scaleKind == ScaleKind.BOOKOO_MINI ||
                packet.scaleKind == ScaleKind.BOOKOO_ULTRA
        }

        private fun normalizedBookooKind(kind: ScaleKind?): ScaleKind {
            return when (kind) {
                ScaleKind.BOOKOO_MINI, ScaleKind.BOOKOO_ULTRA -> kind
                else -> ScaleKind.BOOKOO
            }
        }

        private fun signedCentiValue(sign: Int, high: Int, mid: Int, low: Int): Double {
            val raw = (high shl 16) or (mid shl 8) or low
            return (if (sign == 0x2D) -1.0 else 1.0) * raw / 100.0
        }

        private fun percentile(values: List<Double>, percentile: Double): Double? {
            if (values.isEmpty()) return null
            val sorted = values.sorted()
            val position = percentile.coerceIn(0.0, 1.0) * (sorted.size - 1)
            val lower = kotlin.math.floor(position).toInt()
            val upper = kotlin.math.ceil(position).toInt()
            if (lower == upper) return sorted[lower]
            val fraction = position - lower
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }

        private fun u(value: Byte): Int = value.toInt() and 0xFF
    }
}

private data class AndroidTransportStreamKey(
    val id: String,
    val title: String,
    val detail: String,
    val isOfficial: Boolean
)

private data class AndroidTransportAlignment(
    val matchedCount: Int,
    val medianLagMilliseconds: Double?,
    val medianAbsoluteDeltaGrams: Double?
)

@Composable
internal fun TransportComparisonPanel(comparison: AndroidTransportComparison) {
    if (!comparison.isVisible) return
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            "This compares weight transports captured during the same recording. The official stream is the one ScaleBench uses for scoring; compatibility streams are kept as evidence.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        comparison.rows.forEach { row ->
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (row.isOfficial) 0.48f else 0.28f)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.Top
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(row.title, fontWeight = FontWeight.SemiBold)
                            Text(
                                row.detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        Text(
                            if (row.isOfficial) "Official" else "Compare",
                            style = MaterialTheme.typography.labelMedium,
                            color = if (row.isOfficial) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Text(
                        "${row.packetCount} packets · ${formatRate(row.rateHz)} · p95 ${formatMillis(row.p95IntervalMilliseconds)} · max ${formatMillis(row.maxGapMilliseconds)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (row.matchedReferenceCount != null) {
                        Text(
                            "${row.matchedReferenceCount} matched · lag ${signedMillis(row.medianLagMilliseconds)} · delta ${formatGrams(row.medianAbsoluteDeltaGrams)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

private fun signedMillis(value: Double?): String {
    if (value == null) return "--"
    if (kotlin.math.abs(value) < 0.5) return "0 ms"
    return String.format(Locale.US, "%+.0f ms", value)
}

private fun formatGrams(value: Double?): String {
    return value?.let { String.format(Locale.US, "%.2f g", it) } ?: "--"
}
