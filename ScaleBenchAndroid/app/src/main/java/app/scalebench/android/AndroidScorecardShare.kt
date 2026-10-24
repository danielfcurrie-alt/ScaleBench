package app.scalebench.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import java.io.File
import java.io.FileOutputStream
import java.text.DateFormat
import java.util.Date
import java.util.Locale

internal object AndroidScorecardShare {
    fun writeScorecard(context: Context, recording: ScaleRecording): File {
        recording.metrics = ScaleQualityAnalyzer.analyze(recording)
        officialScorecardError(recording.mode, recording.metrics)?.let { error ->
            throw IllegalArgumentException(error)
        }

        val outputDirectory = File(context.cacheDir, "scorecards")
        outputDirectory.mkdirs()
        val file = File(outputDirectory, "${safeFileName(recording.defaultTitle())}-${System.currentTimeMillis()}.png")
        val bitmap = render(context, recording)
        FileOutputStream(file).use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
        }
        bitmap.recycle()
        return file
    }

    private fun render(context: Context, recording: ScaleRecording): Bitmap {
        val width = 1200
        val height = 1200
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val metrics = recording.metrics
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        canvas.drawColor(Color.rgb(244, 249, 253))

        drawLogo(context, canvas, paint, 48f, 52f, 98f)
        drawText(canvas, paint, "ScaleBench", 172f, 100f, 56f, Color.BLACK, Paint.Align.LEFT, true)
        val meta = listOfNotNull(
            recording.device?.name ?: recording.samples.lastOrNull()?.scaleKind?.displayName,
            platformDisplayName("android"),
            DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(recording.startedAtMillis))
        ).joinToString(" · ")
        drawText(canvas, paint, meta, 172f, 144f, 25f, Color.rgb(101, 111, 121), Paint.Align.LEFT, false)

        roundRect(canvas, paint, RectF(936f, 74f, 1148f, 128f), 27f, Color.rgb(211, 247, 243))
        drawText(canvas, paint, "Standard v1", 1042f, 109f, 25f, Color.rgb(16, 87, 91), Paint.Align.CENTER, true)

        val hero = RectF(48f, 166f, 1152f, 456f)
        roundRect(canvas, paint, hero, 8f, Color.rgb(3, 36, 72))
        val gradientSteps = 80
        for (step in 0 until gradientSteps) {
            val fraction = step.toFloat() / gradientSteps.toFloat()
            paint.color = blend(Color.rgb(3, 36, 72), Color.rgb(0, 133, 114), fraction)
            canvas.drawRect(
                hero.left + hero.width() * fraction,
                hero.top,
                hero.left + hero.width() * (step + 1) / gradientSteps.toFloat() + 1f,
                hero.bottom,
                paint
            )
        }
        drawText(canvas, paint, scorecardHeroLabel(recording.mode), 86f, 236f, 31f, Color.WHITE, Paint.Align.LEFT, true)
        drawScore(canvas, paint, recording)
        drawTextFitted(
            canvas,
            paint,
            recording.device?.kind?.displayName ?: recording.samples.lastOrNull()?.scaleKind?.displayName ?: "Unknown Scale",
            1086f,
            314f,
            35f,
            24f,
            430f,
            Color.WHITE,
            Paint.Align.RIGHT,
            true
        )
        drawText(canvas, paint, recording.mode.displayName, 1086f, 360f, 29f, Color.rgb(204, 224, 224), Paint.Align.RIGHT, false)

        val cardsTop = 488f
        val cardGap = 18f
        val cardWidth = (1104f - cardGap * 2f) / 3f
        metricCard(canvas, paint, 48f, cardsTop, cardWidth, 148f, "Delivered", deliveredCompact(metrics), 54f)
        metricCard(canvas, paint, 48f + cardWidth + cardGap, cardsTop, cardWidth, 148f, scorecardRateLabel(recording), scorecardRateCompact(recording, metrics), 54f)
        metricCard(canvas, paint, 48f + (cardWidth + cardGap) * 2f, cardsTop, cardWidth, 148f, "Usable", usableCompact(metrics), 54f)

        val wideWidth = (1104f - cardGap) / 2f
        metricCard(canvas, paint, 48f, 666f, wideWidth, 120f, scorecardFirstWideLabel(recording), scorecardFirstWideValue(recording, metrics), 38f)
        metricCard(canvas, paint, 48f + wideWidth + cardGap, 666f, wideWidth, 120f, "Max gap", metrics.packetIntervalMaxMilliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--", 38f)
        metricCard(canvas, paint, 48f, 816f, wideWidth, 120f, "p95 interval", metrics.packetIntervalP95Milliseconds?.let { String.format(Locale.US, "%.0f ms", it) } ?: "--", 38f)
        metricCard(canvas, paint, 48f + wideWidth + cardGap, 816f, wideWidth, 120f, "Long gaps", metrics.longGapCount.toString(), 38f)

        val formula = scoreFormulaLine(recording.mode, metrics)
        roundRect(canvas, paint, RectF(48f, 964f, 1152f, 1034f), 8f, Color.WHITE)
        drawWrappedText(
            canvas,
            paint,
            formula,
            70f,
            994f,
            1060f,
            25f,
            Color.rgb(104, 113, 122),
            2
        )

        val footer = "Official ScaleBench Standard v1 ${scorecardHeroLabel(recording.mode)} result. Delivered packets and usable readings create the score; packet checks explain how much the protocol lets ScaleBench verify."
        drawWrappedText(
            canvas,
            paint,
            footer,
            48f,
            1104f,
            1104f,
            20f,
            Color.rgb(104, 113, 122),
            2
        )
        return bitmap
    }

    private fun drawLogo(context: Context, canvas: Canvas, paint: Paint, left: Float, top: Float, size: Float) {
        roundRect(canvas, paint, RectF(left, top, left + size, top + size), 20f, Color.rgb(5, 34, 66))
        val drawable = context.getDrawable(R.mipmap.ic_launcher_foreground)
        if (drawable != null) {
            val inset = 8
            drawable.setBounds(
                (left + inset).toInt(),
                (top + inset).toInt(),
                (left + size - inset).toInt(),
                (top + size - inset).toInt()
            )
            drawable.draw(canvas)
        }
    }

    private fun drawScore(canvas: Canvas, paint: Paint, recording: ScaleRecording) {
        val value = standardScoreDisplay(recording.mode, recording.metrics)
        val slash = value.indexOf("/")
        if (slash > 0) {
            val score = value.substring(0, slash)
            val scoreSize = fittedTextSize(paint, score, 112f, 72f, 300f, true)
            drawText(canvas, paint, score, 86f, 386f, scoreSize, Color.WHITE, Paint.Align.LEFT, true)
            paint.textSize = scoreSize
            paint.typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
            val slashX = 86f + paint.measureText(score) + 12f
            drawText(canvas, paint, "/100", slashX, 386f, 42f, Color.WHITE, Paint.Align.LEFT, true)
        } else {
            drawTextFitted(canvas, paint, value, 86f, 378f, 74f, 42f, 430f, Color.WHITE, Paint.Align.LEFT, true)
        }
    }

    private fun metricCard(
        canvas: Canvas,
        paint: Paint,
        left: Float,
        top: Float,
        width: Float,
        height: Float,
        label: String,
        value: String,
        valueSize: Float
    ) {
        roundRect(canvas, paint, RectF(left, top, left + width, top + height), 8f, Color.WHITE)
        drawText(canvas, paint, label, left + 22f, top + 44f, 24f, Color.rgb(122, 128, 134), Paint.Align.LEFT, true)
        drawTextFitted(
            canvas,
            paint,
            value,
            left + 22f,
            top + 104f,
            valueSize,
            26f,
            width - 44f,
            Color.BLACK,
            Paint.Align.LEFT,
            true
        )
    }

    private fun deliveredCompact(metrics: ScaleQualityMetrics): String {
        val served = metrics.servedSlots
        val total = metrics.slotCount
        return if (served != null && total != null && total > 0) "$served/$total" else "--"
    }

    private fun usableCompact(metrics: ScaleQualityMetrics): String {
        val usable = metrics.usableSampleCount
        val total = metrics.relevantWeightFrameCount
        return if (usable != null && total != null && total > 0) "$usable/$total" else "--"
    }

    private fun scorecardRateLabel(recording: ScaleRecording): String =
        if (recording.source == RecordingSource.USB_SERIAL) "Received" else "Rate"

    private fun scorecardRateCompact(recording: ScaleRecording, metrics: ScaleQualityMetrics): String {
        if (recording.source == RecordingSource.USB_SERIAL) return usbHostReceiveRate(recording)
        return metrics.effectiveSampleRateHz?.let { String.format(Locale.US, "%.1f Hz", it) } ?: "--"
    }

    private fun scorecardFirstWideLabel(recording: ScaleRecording): String =
        if (recording.source == RecordingSource.USB_SERIAL) "Device cadence" else "Checks"

    private fun scorecardFirstWideValue(recording: ScaleRecording, metrics: ScaleQualityMetrics): String =
        if (recording.source == RecordingSource.USB_SERIAL) usbDeviceCadence(recording) else checksCompact(metrics)

    private fun checksCompact(metrics: ScaleQualityMetrics): String {
        val verification = metrics.protocolVerification ?: return "--"
        val total = verification.verifiableClasses.size + verification.unverifiableClasses.size
        return if (total > 0) "${verification.verifiableClasses.size}/$total" else "--"
    }

    private fun scorecardHeroLabel(mode: RecordingMode): String = when (mode) {
        RecordingMode.SHOT, RecordingMode.TRANSPORT_STRESS -> "Delivery"
        RecordingMode.IDLE_STABILITY -> "Idle Stability"
        RecordingMode.STEP_RESPONSE -> "Step Response"
        RecordingMode.TARE_LATENCY -> "Tare Latency"
        RecordingMode.BATTERY_STABILITY -> "Battery Logging"
    }

    private fun scoreFormulaLine(mode: RecordingMode, metrics: ScaleQualityMetrics): String {
        if (mode != RecordingMode.SHOT && mode != RecordingMode.TRANSPORT_STRESS) {
            return scoreExplanationLines(mode, metrics).firstOrNull() ?: "ScaleBench Standard v1 result."
        }
        val score = metrics.delivery?.deliveryScore
        val coverage = metrics.delivery?.coverage
        val purity = metrics.delivery?.purity
        return if (score != null && coverage != null && purity != null) {
            "Score: round(100 x ${formatMultiplier(coverage)} x ${formatMultiplier(purity)}) = $score/100."
        } else {
            "Delivery score needs a complete, valid recording."
        }
    }

    private fun drawWrappedText(
        canvas: Canvas,
        paint: Paint,
        text: String,
        x: Float,
        y: Float,
        width: Float,
        textSize: Float,
        color: Int,
        maxLines: Int
    ) {
        paint.textSize = textSize
        paint.color = color
        paint.typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.NORMAL)
        val words = text.split(" ")
        var line = ""
        var lineY = y
        var lines = 0
        for (word in words) {
            val candidate = if (line.isEmpty()) word else "$line $word"
            if (paint.measureText(candidate) <= width) {
                line = candidate
            } else {
                canvas.drawText(line, x, lineY, paint)
                lines++
                if (lines >= maxLines) return
                line = word
                lineY += textSize + 9f
            }
        }
        if (line.isNotEmpty() && lines < maxLines) {
            canvas.drawText(line, x, lineY, paint)
        }
    }

    private fun drawText(
        canvas: Canvas,
        paint: Paint,
        text: String,
        x: Float,
        y: Float,
        size: Float,
        color: Int,
        align: Paint.Align,
        bold: Boolean
    ) {
        paint.textSize = size
        paint.color = color
        paint.textAlign = align
        paint.typeface = android.graphics.Typeface.create(
            android.graphics.Typeface.DEFAULT,
            if (bold) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL
        )
        canvas.drawText(text, x, y, paint)
    }

    private fun drawTextFitted(
        canvas: Canvas,
        paint: Paint,
        text: String,
        x: Float,
        y: Float,
        preferredSize: Float,
        minimumSize: Float,
        maxWidth: Float,
        color: Int,
        align: Paint.Align,
        bold: Boolean
    ) {
        drawText(
            canvas,
            paint,
            text,
            x,
            y,
            fittedTextSize(paint, text, preferredSize, minimumSize, maxWidth, bold),
            color,
            align,
            bold
        )
    }

    private fun fittedTextSize(
        paint: Paint,
        text: String,
        preferredSize: Float,
        minimumSize: Float,
        maxWidth: Float,
        bold: Boolean
    ): Float {
        paint.typeface = android.graphics.Typeface.create(
            android.graphics.Typeface.DEFAULT,
            if (bold) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL
        )
        var size = preferredSize
        while (size > minimumSize) {
            paint.textSize = size
            if (paint.measureText(text) <= maxWidth) return size
            size -= 2f
        }
        return minimumSize
    }

    private fun roundRect(canvas: Canvas, paint: Paint, rect: RectF, radius: Float, color: Int) {
        paint.style = Paint.Style.FILL
        paint.color = color
        canvas.drawRoundRect(rect, radius, radius, paint)
    }

    private fun blend(start: Int, end: Int, fraction: Float): Int {
        val clamped = fraction.coerceIn(0f, 1f)
        return Color.rgb(
            (Color.red(start) + (Color.red(end) - Color.red(start)) * clamped).toInt(),
            (Color.green(start) + (Color.green(end) - Color.green(start)) * clamped).toInt(),
            (Color.blue(start) + (Color.blue(end) - Color.blue(start)) * clamped).toInt()
        )
    }

    private fun safeFileName(title: String): String {
        return title
            .replace(Regex("[^A-Za-z0-9._-]+"), "-")
            .trim('-')
            .take(72)
            .ifBlank { "ScaleBench-Scorecard" }
    }
}
