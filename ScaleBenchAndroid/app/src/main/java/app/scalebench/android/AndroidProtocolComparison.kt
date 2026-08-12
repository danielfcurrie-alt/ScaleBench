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
