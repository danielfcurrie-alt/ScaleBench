package app.scalebench.android

import android.content.Context
import org.json.JSONObject

internal data class SharedHelpContent(
    val schemaVersion: Int,
    val title: String,
    val sections: List<SharedHelpSection>
) {
    companion object {
        fun load(context: Context): SharedHelpContent {
            return try {
                context.assets.open("help-content.json").bufferedReader().use { reader ->
                    fromJson(JSONObject(reader.readText()))
                }
            } catch (_: Exception) {
                fallback
            }
        }

        private fun fromJson(json: JSONObject): SharedHelpContent {
            val sectionsJson = json.optJSONArray("sections")
            val sections = if (sectionsJson == null) {
                emptyList()
            } else {
                (0 until sectionsJson.length()).mapNotNull { index ->
                    sectionsJson.optJSONObject(index)?.let(SharedHelpSection::fromJson)
                }
            }
            return SharedHelpContent(
                schemaVersion = json.optInt("schemaVersion", 1),
                title = json.optString("title", "ScaleBench Help"),
                sections = sections
            )
        }

        private val fallback = SharedHelpContent(
            schemaVersion = 1,
            title = "ScaleBench Help",
            sections = listOf(
                SharedHelpSection(
                    title = "Quick start",
                    items = listOf(
                        SharedHelpItem(type = SharedHelpItemType.STEP, number = "1", title = "Scan and connect", text = "Power on a supported Bluetooth scale, tap Scan, then select the scale."),
                        SharedHelpItem(type = SharedHelpItemType.STEP, number = "2", title = "Choose a mode", text = "Use Shot / Pour for normal public comparisons."),
                        SharedHelpItem(type = SharedHelpItemType.STEP, number = "3", title = "Record", text = "Tap Start Recording. A timer sheet stays open so capture state is obvious."),
                        SharedHelpItem(type = SharedHelpItemType.STEP, number = "4", title = "Stop and inspect", text = "Tap Stop and View Results. ScaleBench saves the recording automatically; export JSON only when you want a file copy.")
                    )
                ),
                SharedHelpSection(
                    title = "Delivery score",
                    items = listOf(
                        SharedHelpItem(type = SharedHelpItemType.TEXT, text = "Shot / Pour and Transport Stress show the score math directly: delivered packets, usable readings, then score."),
                        SharedHelpItem(type = SharedHelpItemType.TEXT, text = "Delivered packets compares received updates against the 20-per-second Shot / Pour target."),
                        SharedHelpItem(type = SharedHelpItemType.TEXT, text = "Usable readings counts how many received weight readings could be trusted for scoring."),
                        SharedHelpItem(type = SharedHelpItemType.TEXT, text = "Packet checks shows how many extra packet details the scale exposes for diagnosis.")
                    )
                ),
                SharedHelpSection(
                    title = "Source & legal",
                    items = listOf(
                        SharedHelpItem(type = SharedHelpItemType.TEXT, text = "ScaleBench is open source. The repository includes the app code, shared schemas, test fixtures, scoring documentation, privacy policy, and MIT license."),
                        SharedHelpItem(type = SharedHelpItemType.LINK, title = "GitHub repository", value = "https://github.com/danielfcurrie-alt/ScaleBench"),
                        SharedHelpItem(type = SharedHelpItemType.LINK, title = "Privacy policy", value = "https://github.com/danielfcurrie-alt/ScaleBench/blob/main/PRIVACY.md"),
                        SharedHelpItem(type = SharedHelpItemType.LINK, title = "MIT license", value = "https://github.com/danielfcurrie-alt/ScaleBench/blob/main/LICENSE")
                    )
                )
            )
        )
    }
}

internal data class SharedHelpSection(
    val title: String,
    val items: List<SharedHelpItem>
) {
    companion object {
        fun fromJson(json: JSONObject): SharedHelpSection {
            val itemsJson = json.optJSONArray("items")
            val items = if (itemsJson == null) {
                emptyList()
            } else {
                (0 until itemsJson.length()).mapNotNull { index ->
                    itemsJson.optJSONObject(index)?.let(SharedHelpItem::fromJson)
                }
            }
            return SharedHelpSection(
                title = json.optString("title", ""),
                items = items
            )
        }
    }
}

internal data class SharedHelpItem(
    val type: SharedHelpItemType,
    val number: String? = null,
    val title: String? = null,
    val text: String? = null,
    val value: String? = null
) {
    companion object {
        fun fromJson(json: JSONObject): SharedHelpItem {
            return SharedHelpItem(
                type = SharedHelpItemType.from(json.optString("type", "text")),
                number = json.optString("number").takeIf { it.isNotBlank() },
                title = json.optString("title").takeIf { it.isNotBlank() },
                text = json.optString("text").takeIf { it.isNotBlank() },
                value = json.optString("value").takeIf { it.isNotBlank() }
            )
        }
    }
}

internal enum class SharedHelpItemType {
    TEXT,
    STEP,
    ROW,
    BULLET,
    LINK;

    companion object {
        fun from(value: String): SharedHelpItemType {
            return when (value) {
                "step" -> STEP
                "row" -> ROW
                "bullet" -> BULLET
                "link" -> LINK
                else -> TEXT
            }
        }
    }
}
