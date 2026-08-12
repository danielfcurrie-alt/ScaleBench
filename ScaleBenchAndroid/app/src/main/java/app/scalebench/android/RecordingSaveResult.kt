package app.scalebench.android

internal data class RecordingSaveResult(
    val saved: Boolean,
    val retryable: Boolean,
    val message: String
)
