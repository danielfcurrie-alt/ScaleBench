package app.scalebench.android;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

final class SavedRecordingStore {
    private static final String PREFS_NAME = "scalebench-recordings";
    private static final String EXAMPLES_SEEDED_KEY = "sharedExamplesSeeded.v1";
    private static final int SUMMARY_SCHEMA_VERSION = 2;

    private final File directory;
    private final SharedPreferences preferences;
    private final List<SavedRecordingSummary> recordings = new ArrayList<>();
    private String lastErrorMessage;

    SavedRecordingStore(Context context) {
        directory = new File(context.getFilesDir(), "recordings");
        preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        load();
        ensureSharedExamplesSeeded();
    }

    synchronized List<SavedRecordingSummary> recordings() {
        return new ArrayList<>(recordings);
    }

    synchronized String lastErrorMessage() {
        return lastErrorMessage;
    }

    synchronized SavedRecordingSummary save(ScaleRecording recording, String notes, String title) throws Exception {
        return save(recording, notes, title, true);
    }

    synchronized SavedRecordingSummary save(
            ScaleRecording recording,
            String notes,
            String title,
            boolean recalculateMetrics
    ) throws Exception {
        if (!directory.exists() && !directory.mkdirs()) {
            throw new IllegalStateException("Could not create the recordings directory");
        }
        recording.endedAtMillis = recording.endedAtMillis == null ? System.currentTimeMillis() : recording.endedAtMillis;
        recording.notes = notes == null ? "" : notes;
        if (recalculateMetrics) {
            recording.metrics = ScaleQualityAnalyzer.analyze(recording);
        }

        SavedRecordingSummary summary = new SavedRecordingSummary();
        summary.summarySchemaVersion = SUMMARY_SCHEMA_VERSION;
        summary.scoringModelVersion = ScaleRecording.SCORING_MODEL_VERSION;
        summary.id = recording.id;
        summary.savedAtMillis = System.currentTimeMillis();
        summary.title = title == null || title.trim().isEmpty() ? recording.defaultTitle() : title.trim();
        recording.title = summary.title;
        summary.notes = recording.notes;
        summary.recordingFileName = summary.id + "-recording.json";
        summary.protocolKind = protocolKind(recording);
        summary.mode = recording.mode;
        summary.platform = recording.platform;
        summary.score = recording.metrics.overallScore;
        summary.verificationCoveragePercent = recording.metrics.protocolVerification == null
                ? null : recording.metrics.protocolVerification.verificationCoveragePercent;
        summary.purityIsUpperBound = recording.metrics.delivery != null
                && Boolean.TRUE.equals(recording.metrics.delivery.purityIsUpperBound);
        summary.sampleCount = recording.samples.size();
        summary.rawPacketCount = recording.rawPackets.size();
        summary.sampleRateHz = recording.metrics.effectiveSampleRateHz;
        summary.p95IntervalMilliseconds = recording.metrics.packetIntervalP95Milliseconds;
        summary.maxGapMilliseconds = recording.metrics.packetIntervalMaxMilliseconds;
        summary.longGapCount = recording.metrics.longGapCount;
        summary.rejectedPacketCount = recording.metrics.rejectedPacketCount;

        File recordingFile = new File(directory, summary.recordingFileName);
        backupExistingFileIfNeeded(recordingFile);
        JsonExporter.writeRecording(recording, recordingFile);
        writeSummary(summary);
        replaceSummary(summary);
        sort();
        lastErrorMessage = null;
        return summary;
    }

    synchronized int loadExampleRecordings() throws Exception {
        int loaded = 0;
        for (SampleRecordingFactory.Example example : SampleRecordingFactory.examples()) {
            if (hasRecordingTitle(example.title)) continue;
            save(example.recording, example.notes, example.title);
            loaded++;
        }
        return loaded;
    }

    synchronized void delete(SavedRecordingSummary summary) throws Exception {
        deleteBackupFiles(directory, summary.id);
        deleteQuietly(new File(directory, summary.id + ".summary.json"));
        deleteQuietly(new File(directory, summary.recordingFileName));
        recordings.removeIf(saved -> saved.id.equals(summary.id));
        lastErrorMessage = null;
    }

    synchronized JSONObject recordingObject(SavedRecordingSummary summary) throws Exception {
        return recordingObject(recalculatedRecording(summary));
    }

    JSONObject recordingObject(ScaleRecording recording) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        JsonExporter.writeRecording(recording, output);
        return new JSONObject(output.toString(StandardCharsets.UTF_8.name()));
    }

    synchronized void writeRecording(SavedRecordingSummary summary, OutputStream output) throws Exception {
        JsonExporter.writeRecording(recalculatedRecording(summary), output);
    }

    synchronized ScaleRecording recordingForAnalysis(SavedRecordingSummary summary) throws Exception {
        return recalculatedRecording(summary);
    }

    synchronized SavedRecordingSummary importRecording(String json, String fallbackTitle) throws Exception {
        ScaleRecording recording = decodeSharedRecording(json);
        String title = recording.title == null || recording.title.trim().isEmpty()
                ? "Imported " + (fallbackTitle == null || fallbackTitle.trim().isEmpty()
                ? recording.defaultTitle()
                : fallbackTitle.replaceFirst("\\.json$", ""))
                : recording.title.trim();
        return save(recording, recording.notes, title);
    }

    static ScaleRecording decodeSharedRecording(String json) throws Exception {
        return readRecording(new JSONObject(json));
    }

    synchronized void load() {
        recordings.clear();
        if (!directory.exists()) {
            lastErrorMessage = null;
            return;
        }
        cleanupPendingWrites();
        File[] files = directory.listFiles((dir, name) ->
                name.endsWith(".summary.json")
        );
        if (files == null) {
            lastErrorMessage = null;
            return;
        }
        int failedFileCount = 0;
        for (File file : files) {
            try {
                SavedRecordingSummary summary = readSummary(file);
                File recordingFile = new File(directory, summary.recordingFileName);
                if (recordingFile.exists()) {
                    replaceSummary(summary);
                } else {
                    failedFileCount++;
                }
            } catch (Exception unreadable) {
                failedFileCount++;
            }
        }
        sort();
        List<String> notices = new ArrayList<>();
        if (failedFileCount > 0) {
            notices.add(failedFileCount + " saved recording summary"
                    + (failedFileCount == 1 ? "" : "s")
                    + " could not be read. Full recordings will be checked in the background.");
        }
        lastErrorMessage = notices.isEmpty() ? null : String.join(" ", notices);
    }

    int recoverMissingSummaries() {
        if (!directory.exists()) return 0;
        cleanupPendingWrites();
        File[] files = directory.listFiles((dir, name) ->
                name.endsWith(".json") && !name.endsWith(".summary.json")
        );
        if (files == null) return 0;

        Set<String> currentRecordingFiles = new HashSet<>();
        synchronized (this) {
            for (SavedRecordingSummary summary : recordings) {
                if (!summaryNeedsRefresh(summary)) {
                    currentRecordingFiles.add(summary.recordingFileName);
                }
            }
        }

        int recoveredFileCount = 0;
        int refreshedFileCount = 0;
        int failedFileCount = 0;
        for (File file : files) {
            if (currentRecordingFiles.contains(file.getName())) continue;
            try {
                ScaleRecording recording = readRecording(file);
                SavedRecordingSummary summary = summaryForRecording(recording, file);
                writeSummary(summary);
                if (addRecoveredSummary(summary)) {
                    recoveredFileCount++;
                } else {
                    refreshedFileCount++;
                }
            } catch (Exception unreadable) {
                try {
                    ScaleRecording recovered = recoverRecordingFromBackup(file);
                    if (recovered == null) {
                        failedFileCount++;
                    } else {
                        SavedRecordingSummary summary = summaryForRecording(recovered, file);
                        writeSummary(summary);
                        if (addRecoveredSummary(summary)) {
                            recoveredFileCount++;
                        } else {
                            refreshedFileCount++;
                        }
                    }
                } catch (Exception recoveryFailed) {
                    failedFileCount++;
                }
            }
        }

        List<String> notices = new ArrayList<>();
        if (recoveredFileCount > 0) {
            notices.add("Recovered " + recoveredFileCount + " saved recording "
                    + (recoveredFileCount == 1 ? "summary" : "summaries") + " in the background.");
        }
        if (refreshedFileCount > 0) {
            notices.add("Refreshed " + refreshedFileCount + " saved recording "
                    + (refreshedFileCount == 1 ? "summary" : "summaries") + " in the background.");
        }
        if (failedFileCount > 0) {
            notices.add(failedFileCount + " saved recording file"
                    + (failedFileCount == 1 ? "" : "s")
                    + " could not be read. Files were left in place.");
        }
        if (!notices.isEmpty()) {
            synchronized (this) {
                lastErrorMessage = String.join(" ", notices);
            }
        }
        return recoveredFileCount + refreshedFileCount;
    }

    private void writeSummary(SavedRecordingSummary summary) throws Exception {
        JSONObject object = new JSONObject();
        object.put("summarySchemaVersion", SUMMARY_SCHEMA_VERSION);
        object.put("scoringModelVersion", ScaleRecording.SCORING_MODEL_VERSION);
        object.put("id", summary.id);
        object.put("savedAtMillis", summary.savedAtMillis);
        object.put("title", summary.title);
        object.put("notes", summary.notes);
        object.put("recordingFileName", summary.recordingFileName);
        object.put("protocolKind", summary.protocolKind.name());
        object.put("mode", summary.mode.name());
        object.put("platform", summary.platform);
        object.put("score", summary.score == null ? JSONObject.NULL : summary.score);
        object.put("verificationCoveragePercent", summary.verificationCoveragePercent == null
                ? JSONObject.NULL : summary.verificationCoveragePercent);
        object.put("purityIsUpperBound", summary.purityIsUpperBound);
        object.put("sampleCount", summary.sampleCount);
        object.put("rawPacketCount", summary.rawPacketCount);
        object.put("sampleRateHz", summary.sampleRateHz == null ? JSONObject.NULL : summary.sampleRateHz);
        object.put("p95IntervalMilliseconds", summary.p95IntervalMilliseconds == null
                ? JSONObject.NULL : summary.p95IntervalMilliseconds);
        object.put("maxGapMilliseconds", summary.maxGapMilliseconds == null
                ? JSONObject.NULL : summary.maxGapMilliseconds);
        object.put("longGapCount", summary.longGapCount);
        object.put("rejectedPacketCount", summary.rejectedPacketCount);
        File summaryFile = new File(directory, summary.id + ".summary.json");
        backupExistingFileIfNeeded(summaryFile);
        JsonExporter.writeUtf8Atomically(object.toString(2), summaryFile);
    }

    private SavedRecordingSummary readSummary(File file) throws Exception {
        JSONObject object = new JSONObject(readText(file));
        SavedRecordingSummary summary = new SavedRecordingSummary();
        summary.summarySchemaVersion = object.optInt("summarySchemaVersion", 0);
        summary.scoringModelVersion = object.optString("scoringModelVersion", "");
        summary.id = object.getString("id");
        summary.savedAtMillis = object.getLong("savedAtMillis");
        summary.title = object.optString("title", "Untitled Recording");
        summary.notes = object.optString("notes", "");
        summary.recordingFileName = object.optString("recordingFileName", summary.id + "-recording.json");
        summary.protocolKind = ScaleKind.valueOf(object.optString("protocolKind", ScaleKind.UNKNOWN.name()));
        summary.mode = RecordingMode.valueOf(object.optString("mode", RecordingMode.SHOT.name()));
        summary.platform = object.optString("platform", "unknown");
        summary.score = object.isNull("score") ? null : object.getInt("score");
        summary.verificationCoveragePercent = object.isNull("verificationCoveragePercent")
                ? null : object.getInt("verificationCoveragePercent");
        summary.purityIsUpperBound = object.optBoolean("purityIsUpperBound", false);
        summary.sampleCount = object.optInt("sampleCount", 0);
        summary.rawPacketCount = object.optInt("rawPacketCount", 0);
        summary.sampleRateHz = nullableDouble(object, "sampleRateHz");
        summary.p95IntervalMilliseconds = nullableDouble(object, "p95IntervalMilliseconds");
        summary.maxGapMilliseconds = nullableDouble(object, "maxGapMilliseconds");
        summary.longGapCount = object.optInt("longGapCount", 0);
        summary.rejectedPacketCount = object.optInt("rejectedPacketCount", 0);
        return summary;
    }

    private static boolean summaryNeedsRefresh(SavedRecordingSummary summary) {
        return summary.summarySchemaVersion != SUMMARY_SCHEMA_VERSION
                || !ScaleRecording.SCORING_MODEL_VERSION.equals(summary.scoringModelVersion);
    }

    private ScaleRecording recalculatedRecording(SavedRecordingSummary summary) throws Exception {
        ScaleRecording recording = readRecording(new File(directory, summary.recordingFileName));
        recording.schemaVersion = ScaleRecording.SCHEMA_VERSION;
        recording.scoringModelVersion = ScaleRecording.SCORING_MODEL_VERSION;
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);
        return recording;
    }

    private SavedRecordingSummary summaryForRecording(ScaleRecording recording, File file) {
        recording.schemaVersion = ScaleRecording.SCHEMA_VERSION;
        recording.scoringModelVersion = ScaleRecording.SCORING_MODEL_VERSION;
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);

        SavedRecordingSummary summary = new SavedRecordingSummary();
        summary.summarySchemaVersion = SUMMARY_SCHEMA_VERSION;
        summary.scoringModelVersion = ScaleRecording.SCORING_MODEL_VERSION;
        summary.id = recording.id;
        long modified = file.lastModified();
        summary.savedAtMillis = modified > 0 ? modified : recording.startedAtMillis;
        summary.title = recording.title == null || recording.title.trim().isEmpty()
                ? recording.defaultTitle()
                : recording.title.trim();
        recording.title = summary.title;
        summary.recordingFileName = file.getName();
        summary.notes = recording.notes;
        summary.protocolKind = protocolKind(recording);
        summary.mode = recording.mode;
        summary.platform = recording.platform;
        summary.score = recording.metrics.overallScore;
        summary.verificationCoveragePercent = recording.metrics.protocolVerification == null
                ? null : recording.metrics.protocolVerification.verificationCoveragePercent;
        summary.purityIsUpperBound = recording.metrics.delivery != null
                && Boolean.TRUE.equals(recording.metrics.delivery.purityIsUpperBound);
        summary.sampleCount = recording.samples.size();
        summary.rawPacketCount = recording.rawPackets.size();
        summary.sampleRateHz = recording.metrics.effectiveSampleRateHz;
        summary.p95IntervalMilliseconds = recording.metrics.packetIntervalP95Milliseconds;
        summary.maxGapMilliseconds = recording.metrics.packetIntervalMaxMilliseconds;
        summary.longGapCount = recording.metrics.longGapCount;
        summary.rejectedPacketCount = recording.metrics.rejectedPacketCount;
        return summary;
    }

    private static ScaleRecording readRecording(File file) throws Exception {
        JSONObject object = new JSONObject(readText(file));
        // Pre-v1 Android builds stored packet bytes without spaces. Limit this repair to the local library.
        normalizeStoredPacketHex(object);
        return readRecording(object);
    }

    private static void normalizeStoredPacketHex(JSONObject object) throws Exception {
        JSONArray packets = object.optJSONArray("rawPackets");
        if (packets == null) return;
        for (int index = 0; index < packets.length(); index++) {
            JSONObject packet = packets.optJSONObject(index);
            if (packet == null) continue;
            String bytesHex = packet.optString("bytesHex", "");
            if (bytesHex.matches("^([0-9A-F]{2})+$")) {
                packet.put("bytesHex", ScaleParsers.normalizeHex(bytesHex));
            }
        }
    }

    private static ScaleRecording readRecording(JSONObject object) throws Exception {
        validateSharedRecordingContract(object);
        ScaleRecording recording = ScaleRecording.empty(parseMode(object.getString("mode")));
        String embeddedID = nullableString(object, "id");
        if (embeddedID == null || embeddedID.trim().isEmpty()) {
            throw new IllegalArgumentException("Shared recording id is required");
        }
        recording.id = UUID.fromString(embeddedID.trim()).toString();
        recording.schemaVersion = object.getInt("schemaVersion");
        recording.appName = object.getString("appName");
        recording.appVersion = object.getString("appVersion");
        recording.appBuild = object.getString("appBuild");
        recording.platform = object.getString("platform");
        recording.scoringModelVersion = object.getString("scoringModelVersion");
        recording.source = parseRecordingSource(nullableString(object, "source"));
        recording.protocolName = nullableString(object, "protocol");
        recording.serialBaud = nullableInt(object, "serialBaud");
        recording.title = nullableString(object, "title");
        recording.startedAtMillis = object.getLong("startedAtMillis");
        recording.endedAtMillis = object.isNull("endedAtMillis") ? null : object.optLong("endedAtMillis");
        recording.recordingStartMonotonicSeconds = nullableDouble(object, "recordingStartMonotonicSeconds");
        recording.recordingEndMonotonicSeconds = nullableDouble(object, "recordingEndMonotonicSeconds");
        recording.notes = object.getString("notes");
        recording.device = readDevice(object.optJSONObject("device"));
        recording.protocolCapabilities = readProtocolCapabilities(object.optJSONObject("protocolCapabilities"));
        readLink(object.getJSONObject("link"), recording.link);
        readSamples(object.getJSONArray("samples"), recording.samples);
        readBatteryEvents(object.getJSONArray("batteryEvents"), recording.batteryEvents);
        readEvents(object.getJSONArray("events"), recording.events);
        readRawPackets(object.getJSONArray("rawPackets"), recording.rawPackets);
        return recording;
    }

    private static void validateSharedRecordingContract(JSONObject object) throws Exception {
        requireKeys(object, "recording",
                "id", "schemaVersion", "appName", "appVersion", "appBuild", "platform",
                "scoringModelVersion", "mode", "startedAtMillis", "notes", "scoringProfile",
                "link", "metrics", "samples", "batteryEvents", "events", "rawPackets");
        allowOnlyKeys(object, "recording",
                "id", "schemaVersion", "appName", "appVersion", "appBuild", "platform",
                "scoringModelVersion", "source", "protocol", "serialBaud", "title", "mode", "startedAtMillis", "endedAtMillis",
                "recordingStartMonotonicSeconds", "recordingEndMonotonicSeconds", "notes",
                "scoringProfile", "device", "protocolCapabilities", "link", "metrics", "samples",
                "batteryEvents", "events", "rawPackets");

        if (object.getInt("schemaVersion") != ScaleRecording.SCHEMA_VERSION) {
            throw new IllegalArgumentException("Unsupported recording schema version; expected " + ScaleRecording.SCHEMA_VERSION);
        }
        if (!ScaleRecording.SCORING_MODEL_VERSION.equals(object.getString("scoringModelVersion"))) {
            throw new IllegalArgumentException("Unsupported scoring model " + object.getString("scoringModelVersion"));
        }
        parseMode(object.getString("mode"));
        UUID.fromString(object.getString("id"));
        object.getString("appName");
        object.getString("appVersion");
        object.getString("appBuild");
        object.getString("platform");
        object.getLong("startedAtMillis");
        object.getString("notes");
        RecordingSource source = parseRecordingSource(nullableString(object, "source"));
        String protocolName = nullableString(object, "protocol");
        Integer serialBaud = nullableInt(object, "serialBaud");
        if (source == RecordingSource.USB_SERIAL) {
            if (protocolName == null || protocolName.trim().isEmpty()) {
                throw new IllegalArgumentException("USB recording protocol is required");
            }
            if (serialBaud == null || serialBaud != 115200) {
                throw new IllegalArgumentException("WMB+ USB Serial recordings must use 115200 baud");
            }
        } else if (protocolName != null || serialBaud != null) {
            throw new IllegalArgumentException("Serial metadata requires source usbSerial");
        }

        JSONObject profile = object.getJSONObject("scoringProfile");
        requireKeys(profile, "scoringProfile", "name");
        allowOnlyKeys(profile, "scoringProfile", "name");
        if (!ScoringProfile.STANDARD_BENCHMARK_NAME.equals(profile.getString("name"))) {
            throw new IllegalArgumentException("Unsupported scoring profile " + profile.getString("name"));
        }

        Double start = nullableDouble(object, "recordingStartMonotonicSeconds");
        Double end = nullableDouble(object, "recordingEndMonotonicSeconds");
        if (start != null && end != null && end < start) {
            throw new IllegalArgumentException("Recording end must not precede recording start");
        }

        if (object.has("device") && !object.isNull("device")) validateDevice(object.getJSONObject("device"));
        if (object.has("protocolCapabilities") && !object.isNull("protocolCapabilities")) {
            validateProtocolCapabilities(object.getJSONObject("protocolCapabilities"));
        }
        validateLink(object.getJSONObject("link"));
        object.getJSONObject("metrics");
        validateSamples(object.getJSONArray("samples"));
        validateBatteryEvents(object.getJSONArray("batteryEvents"));
        validateEvents(object.getJSONArray("events"));
        validateRawPackets(object.getJSONArray("rawPackets"));
    }

    private static void validateDevice(JSONObject object) throws Exception {
        requireKeys(object, "device", "name", "identifier", "kind", "advertisedServices");
        allowOnlyKeys(object, "device", "name", "identifier", "kind", "advertisedServices");
        object.getString("name");
        object.getString("identifier");
        parseScaleKind(object.getString("kind"));
        JSONArray services = object.getJSONArray("advertisedServices");
        for (int index = 0; index < services.length(); index++) services.getString(index);
    }

    private static void validateProtocolCapabilities(JSONObject object) throws Exception {
        requireKeys(object, "protocolCapabilities", "hasChecksum", "hasSequence", "hasDeviceClock", "deviceClockSemantics");
        allowOnlyKeys(object, "protocolCapabilities", "hasChecksum", "hasSequence", "sequenceModulus",
                "hasDeviceClock", "deviceClockSemantics", "deviceClockModulus");
        object.getBoolean("hasChecksum");
        object.getBoolean("hasSequence");
        object.getBoolean("hasDeviceClock");
        parseClockSemantics(object.getString("deviceClockSemantics"));
        nullableLong(object, "sequenceModulus");
        nullableLong(object, "deviceClockModulus");
    }

    private static void validateLink(JSONObject object) throws Exception {
        allowOnlyKeys(object, "link", "requestedConnectionPriority", "requestedMtu", "negotiatedMtu");
        nullableString(object, "requestedConnectionPriority");
        nullableInt(object, "requestedMtu");
        nullableInt(object, "negotiatedMtu");
    }

    private static void validateSamples(JSONArray array) throws Exception {
        for (int index = 0; index < array.length(); index++) {
            JSONObject sample = array.getJSONObject(index);
            requireKeys(sample, "sample", "arrivalTimeMillis", "monotonicSeconds", "scaleKind", "weightGrams");
            allowOnlyKeys(sample, "sample", "arrivalTimeMillis", "monotonicSeconds", "scaleKind", "weightGrams",
                    "deviceTimestampMilliseconds", "sequence", "batteryPercent", "flowGramsPerSecond",
                    "firmwareQualityScore", "detectedSampleRateHz", "statusFlags", "diagnosticFlags",
                    "firmwareMillis", "sequenceNumber", "usbStatusRaw", "usbStatusLabels",
                    "firmwareQuality", "hx711Hz", "usbDroppedCumulative", "usbDroppedDelta", "hostReceivedAt");
            sample.getLong("arrivalTimeMillis");
            sample.getDouble("monotonicSeconds");
            parseScaleKind(sample.getString("scaleKind"));
            sample.getDouble("weightGrams");
            requireRange(nullableInt(sample, "sequence"), 0, 255, "sample sequence");
            requireRange(nullableInt(sample, "batteryPercent"), 0, 100, "sample battery percent");
            validateUSBSerialMetadata(sample, "sample");
            if (sample.has("statusFlags") && !sample.isNull("statusFlags")) validateStatusFlags(sample.getJSONObject("statusFlags"));
            if (sample.has("diagnosticFlags") && !sample.isNull("diagnosticFlags")) validateDiagnosticFlags(sample.getJSONObject("diagnosticFlags"));
        }
    }

    private static void validateStatusFlags(JSONObject object) throws Exception {
        String[] keys = {"timerRunning", "hx711Connected", "tarePending", "atomicTareStartPending",
                "batteryLow", "batteryCritical", "batteryPresent", "displayPresent"};
        requireKeys(object, "statusFlags", keys);
        allowOnlyKeys(object, "statusFlags", keys);
        for (String key : keys) object.getBoolean(key);
    }

    private static void validateDiagnosticFlags(JSONObject object) throws Exception {
        String[] keys = {"recentBump", "longGapSeen", "cadenceValid", "detected80SPS", "detected10SPS",
                "qualityValid", "flowPresent", "extensionPresent"};
        requireKeys(object, "diagnosticFlags", keys);
        allowOnlyKeys(object, "diagnosticFlags", keys);
        for (String key : keys) object.getBoolean(key);
    }

    private static void validateBatteryEvents(JSONArray array) throws Exception {
        for (int index = 0; index < array.length(); index++) {
            JSONObject event = array.getJSONObject(index);
            requireKeys(event, "batteryEvent", "arrivalTimeMillis", "monotonicSeconds", "scaleKind", "percent");
            allowOnlyKeys(event, "batteryEvent", "arrivalTimeMillis", "monotonicSeconds", "scaleKind", "percent");
            event.getLong("arrivalTimeMillis");
            event.getDouble("monotonicSeconds");
            parseScaleKind(event.getString("scaleKind"));
            requireRange(event.getInt("percent"), 0, 100, "battery event percent");
        }
    }

    private static void validateEvents(JSONArray array) throws Exception {
        for (int index = 0; index < array.length(); index++) {
            JSONObject event = array.getJSONObject(index);
            requireKeys(event, "recordingEvent", "type", "monotonicSeconds");
            allowOnlyKeys(event, "recordingEvent", "type", "monotonicSeconds");
            parseRecordingEventType(event.getString("type"));
            event.getDouble("monotonicSeconds");
        }
    }

    private static void validateRawPackets(JSONArray array) throws Exception {
        for (int index = 0; index < array.length(); index++) {
            JSONObject packet = array.getJSONObject(index);
            requireKeys(packet, "rawPacket", "arrivalTimeMillis", "monotonicSeconds", "scaleKind",
                    "characteristicUUID", "role", "bytesHex");
            allowOnlyKeys(packet, "rawPacket", "arrivalTimeMillis", "monotonicSeconds", "scaleKind",
                    "characteristicUUID", "role", "bytesHex", "rejectionReason", "weightGrams", "sequence",
                    "deviceTimestampMilliseconds", "fields", "firmwareMillis", "sequenceNumber",
                    "usbStatusRaw", "usbStatusLabels", "firmwareQuality", "hx711Hz",
                    "usbDroppedCumulative", "usbDroppedDelta", "hostReceivedAt");
            packet.getLong("arrivalTimeMillis");
            packet.getDouble("monotonicSeconds");
            parseScaleKind(packet.getString("scaleKind"));
            packet.getString("characteristicUUID");
            parsePacketRole(packet.getString("role"));
            String bytesHex = packet.getString("bytesHex");
            if (!bytesHex.matches("^([0-9A-F]{2}( [0-9A-F]{2})*)?$")) {
                throw new IllegalArgumentException("Packet bytesHex must use uppercase, space-separated bytes");
            }
            parseRejectionReason(nullableString(packet, "rejectionReason"));
            requireRange(nullableInt(packet, "sequence"), 0, 255, "packet sequence");
            validateUSBSerialMetadata(packet, "raw packet");
            if (packet.has("fields") && !packet.isNull("fields")) validatePacketFields(packet.getJSONArray("fields"));
        }
    }

    private static void validateUSBSerialMetadata(JSONObject object, String label) throws Exception {
        String[] keys = {
                "firmwareMillis", "sequenceNumber", "usbStatusRaw", "usbStatusLabels",
                "firmwareQuality", "hx711Hz", "usbDroppedCumulative", "usbDroppedDelta", "hostReceivedAt"
        };
        boolean anyPresent = false;
        for (String key : keys) anyPresent |= object.has(key) && !object.isNull(key);
        if (!anyPresent) return;

        requireKeys(object, label + " USB metadata", keys);
        requireRangeLong(object.getLong("firmwareMillis"), 0, 0xFFFF_FFFFL, label + " firmware millis");
        requireRangeLong(object.getLong("sequenceNumber"), 0, 0xFFFF_FFFFL, label + " sequence number");
        requireRangeLong(object.getLong("usbStatusRaw"), 0, 0xFFFFL, label + " USB status");
        JSONArray labels = object.getJSONArray("usbStatusLabels");
        for (int index = 0; index < labels.length(); index++) labels.getString(index);
        requireRange(object.getInt("firmwareQuality"), 0, 100, label + " firmware quality");
        double hx711Hz = object.getDouble("hx711Hz");
        if (!Double.isFinite(hx711Hz) || hx711Hz < 0) {
            throw new IllegalArgumentException(label + " HX711 cadence must be finite and nonnegative");
        }
        requireRangeLong(object.getLong("usbDroppedCumulative"), 0, 0xFFFF_FFFFL, label + " USB dropped count");
        requireRangeLong(object.getLong("usbDroppedDelta"), 0, 0xFFFF_FFFFL, label + " USB dropped delta");
        object.getLong("hostReceivedAt");
    }

    private static void validatePacketFields(JSONArray array) throws Exception {
        for (int index = 0; index < array.length(); index++) {
            JSONObject field = array.getJSONObject(index);
            requireKeys(field, "packetField", "startByte", "endByteExclusive", "label", "decodedValue", "semantic");
            allowOnlyKeys(field, "packetField", "startByte", "endByteExclusive", "label", "decodedValue", "semantic");
            int start = field.getInt("startByte");
            int end = field.getInt("endByteExclusive");
            if (start < 0 || end <= start) throw new IllegalArgumentException("Packet field byte range is invalid");
            if (field.getString("label").isEmpty()) throw new IllegalArgumentException("Packet field label is required");
            field.getString("decodedValue");
            parsePacketFieldSemantic(field.getString("semantic"));
        }
    }

    private static void requireKeys(JSONObject object, String label, String... keys) {
        for (String key : keys) {
            if (!object.has(key) || object.isNull(key)) {
                throw new IllegalArgumentException(label + " is missing required field " + key);
            }
        }
    }

    private static void allowOnlyKeys(JSONObject object, String label, String... keys) {
        Set<String> allowed = new HashSet<>(Arrays.asList(keys));
        Iterator<String> iterator = object.keys();
        while (iterator.hasNext()) {
            String key = iterator.next();
            if (!allowed.contains(key)) throw new IllegalArgumentException(label + " has unknown field " + key);
        }
    }

    private static void requireRange(Integer value, int minimum, int maximum, String label) {
        if (value != null && (value < minimum || value > maximum)) {
            throw new IllegalArgumentException(label + " must be between " + minimum + " and " + maximum);
        }
    }

    private static void requireRangeLong(long value, long minimum, long maximum, String label) {
        if (value < minimum || value > maximum) {
            throw new IllegalArgumentException(label + " must be between " + minimum + " and " + maximum);
        }
    }

    private static ScaleDeviceIdentity readDevice(JSONObject object) {
        if (object == null) return null;
        ScaleDeviceIdentity device = new ScaleDeviceIdentity();
        device.name = object.optString("name", "");
        device.identifier = object.optString("identifier", "");
        device.kind = parseScaleKind(object.optString("kind", ScaleKind.UNKNOWN.name()));
        device.advertisedServices = jsonStrings(object.optJSONArray("advertisedServices"));
        return device;
    }

    private static ProtocolScoringCapabilities readProtocolCapabilities(JSONObject object) {
        if (object == null) return null;
        ProtocolScoringCapabilities capabilities = new ProtocolScoringCapabilities();
        capabilities.hasChecksum = object.optBoolean("hasChecksum", false);
        capabilities.hasSequence = object.optBoolean("hasSequence", false);
        capabilities.sequenceModulus = nullableLong(object, "sequenceModulus");
        capabilities.hasDeviceClock = object.optBoolean("hasDeviceClock", false);
        capabilities.deviceClockSemantics = parseClockSemantics(object.optString("deviceClockSemantics", "none"));
        capabilities.deviceClockModulus = nullableLong(object, "deviceClockModulus");
        return capabilities;
    }

    private static void readLink(JSONObject object, ScaleLinkMetadata link) {
        if (object == null) return;
        link.requestedConnectionPriority = nullableString(object, "requestedConnectionPriority");
        link.requestedMtu = nullableInt(object, "requestedMtu");
        link.negotiatedMtu = nullableInt(object, "negotiatedMtu");
    }

    private static USBSerialSampleMetadata readUSBSerialMetadata(JSONObject object) {
        if (!object.has("firmwareMillis") || object.isNull("firmwareMillis")) return null;
        USBSerialSampleMetadata metadata = new USBSerialSampleMetadata();
        metadata.firmwareMillis = object.optLong("firmwareMillis");
        metadata.sequenceNumber = object.optLong("sequenceNumber");
        metadata.usbStatusRaw = object.optInt("usbStatusRaw");
        metadata.usbStatusLabels.addAll(jsonStrings(object.optJSONArray("usbStatusLabels")));
        metadata.firmwareQuality = object.optInt("firmwareQuality");
        metadata.hx711Hz = object.optDouble("hx711Hz");
        metadata.usbDroppedCumulative = object.optLong("usbDroppedCumulative");
        metadata.usbDroppedDelta = object.optLong("usbDroppedDelta");
        metadata.hostReceivedAtMillis = object.optLong("hostReceivedAt");
        return metadata;
    }

    private static void readSamples(JSONArray array, List<ScaleSample> samples) {
        if (array == null) return;
        for (int index = 0; index < array.length(); index++) {
            JSONObject object = array.optJSONObject(index);
            if (object == null) continue;
            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = object.optLong("arrivalTimeMillis", 0);
            sample.monotonicSeconds = object.optDouble("monotonicSeconds", 0);
            sample.scaleKind = parseScaleKind(object.optString("scaleKind", ScaleKind.UNKNOWN.name()));
            sample.weightGrams = object.optDouble("weightGrams", 0);
            sample.deviceTimestampMilliseconds = nullableLong(object, "deviceTimestampMilliseconds");
            sample.sequence = nullableInt(object, "sequence");
            sample.batteryPercent = nullableInt(object, "batteryPercent");
            sample.flowGramsPerSecond = nullableDouble(object, "flowGramsPerSecond");
            sample.firmwareQualityScore = nullableInt(object, "firmwareQualityScore");
            sample.detectedSampleRateHz = nullableInt(object, "detectedSampleRateHz");
            sample.statusFlags = readStatusFlags(object.optJSONObject("statusFlags"));
            sample.diagnosticFlags = readDiagnosticFlags(object.optJSONObject("diagnosticFlags"));
            sample.usbSerial = readUSBSerialMetadata(object);
            samples.add(sample);
        }
    }

    private static ScaleStatusFlags readStatusFlags(JSONObject object) {
        if (object == null) return null;
        int value = 0;
        if (object.optBoolean("timerRunning")) value |= 0x01;
        if (object.optBoolean("hx711Connected")) value |= 0x02;
        if (object.optBoolean("tarePending")) value |= 0x04;
        if (object.optBoolean("atomicTareStartPending")) value |= 0x08;
        if (object.optBoolean("batteryLow")) value |= 0x10;
        if (object.optBoolean("batteryCritical")) value |= 0x20;
        if (object.optBoolean("batteryPresent")) value |= 0x40;
        if (object.optBoolean("displayPresent")) value |= 0x80;
        return new ScaleStatusFlags(value);
    }

    private static ScaleDiagnosticFlags readDiagnosticFlags(JSONObject object) {
        if (object == null) return null;
        int value = 0;
        if (object.optBoolean("recentBump")) value |= 0x01;
        if (object.optBoolean("longGapSeen")) value |= 0x02;
        if (object.optBoolean("cadenceValid")) value |= 0x04;
        if (object.optBoolean("detected80SPS")) value |= 0x08;
        if (object.optBoolean("detected10SPS")) value |= 0x10;
        if (object.optBoolean("qualityValid")) value |= 0x20;
        if (object.optBoolean("flowPresent")) value |= 0x40;
        if (object.optBoolean("extensionPresent")) value |= 0x80;
        return new ScaleDiagnosticFlags(value);
    }

    private static void readBatteryEvents(JSONArray array, List<ScaleBatteryEvent> batteryEvents) {
        if (array == null) return;
        for (int index = 0; index < array.length(); index++) {
            JSONObject object = array.optJSONObject(index);
            if (object == null) continue;
            ScaleBatteryEvent event = new ScaleBatteryEvent();
            event.arrivalTimeMillis = object.optLong("arrivalTimeMillis", 0);
            event.monotonicSeconds = object.optDouble("monotonicSeconds", 0);
            event.scaleKind = parseScaleKind(object.optString("scaleKind", ScaleKind.UNKNOWN.name()));
            event.percent = object.optInt("percent", 0);
            batteryEvents.add(event);
        }
    }

    private static void readEvents(JSONArray array, List<ScaleRecordingEvent> events) {
        if (array == null) return;
        for (int index = 0; index < array.length(); index++) {
            JSONObject object = array.optJSONObject(index);
            if (object == null) continue;
            RecordingEventType type = parseRecordingEventType(object.optString("type"));
            ScaleRecordingEvent event = new ScaleRecordingEvent();
            event.type = type;
            event.monotonicSeconds = object.optDouble("monotonicSeconds", 0);
            events.add(event);
        }
    }

    private static RecordingEventType parseRecordingEventType(String value) {
        if ("disconnect".equals(value)) return RecordingEventType.DISCONNECT;
        if ("reconnect".equals(value)) return RecordingEventType.RECONNECT;
        if ("appBackgrounded".equals(value)) return RecordingEventType.APP_BACKGROUNDED;
        if ("appForegrounded".equals(value)) return RecordingEventType.APP_FOREGROUNDED;
        throw new IllegalArgumentException("Unknown recording event type " + value);
    }

    private static void readRawPackets(JSONArray array, List<RawScalePacket> rawPackets) {
        if (array == null) return;
        for (int index = 0; index < array.length(); index++) {
            JSONObject object = array.optJSONObject(index);
            if (object == null) continue;
            RawScalePacket packet = new RawScalePacket();
            packet.arrivalTimeMillis = object.optLong("arrivalTimeMillis", 0);
            packet.monotonicSeconds = object.optDouble("monotonicSeconds", 0);
            packet.scaleKind = parseScaleKind(object.optString("scaleKind", ScaleKind.UNKNOWN.name()));
            packet.characteristicUuid = nullableString(object, "characteristicUUID");
            packet.role = parsePacketRole(object.optString("role", "unknown"));
            packet.bytesHex = ScaleParsers.normalizeHex(object.optString("bytesHex", ""));
            packet.rejectionReason = parseRejectionReason(nullableString(object, "rejectionReason"));
            packet.weightGrams = nullableDouble(object, "weightGrams");
            packet.sequence = nullableInt(object, "sequence");
            packet.deviceTimestampMilliseconds = nullableLong(object, "deviceTimestampMilliseconds");
            packet.usbSerial = readUSBSerialMetadata(object);
            readPacketFields(object.optJSONArray("fields"), packet.fields);
            if (packet.fields.isEmpty()) packet.fields.addAll(ScaleParsers.packetFields(packet));
            rawPackets.add(packet);
        }
    }

    private static void readPacketFields(JSONArray array, List<PacketFieldAnnotation> fields) {
        if (array == null) return;
        for (int index = 0; index < array.length(); index++) {
            JSONObject object = array.optJSONObject(index);
            if (object == null) continue;
            int start = object.optInt("startByte", -1);
            int end = object.optInt("endByteExclusive", -1);
            PacketFieldSemantic semantic = parsePacketFieldSemantic(object.optString("semantic", "payload"));
            if (start < 0 || end <= start) continue;
            fields.add(PacketFieldAnnotation.of(
                    start,
                    end,
                    object.optString("label", "Field"),
                    object.optString("decodedValue", ""),
                    semantic
            ));
        }
    }

    private static PacketFieldSemantic parsePacketFieldSemantic(String value) {
        if ("sampleRate".equals(value)) return PacketFieldSemantic.SAMPLE_RATE;
        try {
            return PacketFieldSemantic.valueOf(value.replaceAll("([a-z])([A-Z])", "$1_$2").toUpperCase(Locale.US));
        } catch (Exception ignored) {
            throw new IllegalArgumentException("Unknown packet field semantic " + value);
        }
    }

    private ScaleKind protocolKind(ScaleRecording recording) {
        if (recording.device != null) return recording.device.kind;
        if (!recording.samples.isEmpty()) return recording.samples.get(recording.samples.size() - 1).scaleKind;
        return ScaleKind.UNKNOWN;
    }

    private boolean hasRecordingTitle(String title) {
        for (SavedRecordingSummary recording : recordings) {
            if (recording.title != null && recording.title.equals(title)) return true;
        }
        return false;
    }

    private void replaceSummary(SavedRecordingSummary summary) {
        recordings.removeIf(saved -> saved.id.equals(summary.id));
        recordings.add(summary);
    }

    private synchronized boolean addRecoveredSummary(SavedRecordingSummary summary) {
        boolean alreadyListed = false;
        for (SavedRecordingSummary existing : recordings) {
            if (existing.recordingFileName.equals(summary.recordingFileName)) {
                alreadyListed = true;
                break;
            }
        }
        replaceSummary(summary);
        sort();
        return !alreadyListed;
    }

    private void ensureSharedExamplesSeeded() {
        if (preferences.getBoolean(EXAMPLES_SEEDED_KEY, false)) return;
        if (hasAnyRecordingFiles()) return;
        try {
            if (recordings.isEmpty()) {
                loadExampleRecordings();
            }
            preferences.edit().putBoolean(EXAMPLES_SEEDED_KEY, true).apply();
        } catch (Exception ignored) {
            // Manual example loading remains available if first-launch seeding cannot write.
        }
    }

    private boolean hasAnyRecordingFiles() {
        if (!directory.exists()) return false;
        File[] files = directory.listFiles((dir, name) ->
                name.endsWith(".json") || name.endsWith(".summary.json")
        );
        return files != null && files.length > 0;
    }

    private static RecordingMode parseMode(String value) {
        if ("idleStability".equals(value)) return RecordingMode.IDLE_STABILITY;
        if ("shot".equals(value)) return RecordingMode.SHOT;
        if ("stepResponse".equals(value)) return RecordingMode.STEP_RESPONSE;
        if ("tareLatency".equals(value)) return RecordingMode.TARE_LATENCY;
        if ("transportStress".equals(value)) return RecordingMode.TRANSPORT_STRESS;
        if ("batteryStability".equals(value)) return RecordingMode.BATTERY_STABILITY;
        throw new IllegalArgumentException("Unknown recording mode " + value);
    }

    private static RecordingSource parseRecordingSource(String value) {
        if (value == null || "bluetooth".equals(value)) return RecordingSource.BLUETOOTH;
        if ("usbSerial".equals(value)) return RecordingSource.USB_SERIAL;
        throw new IllegalArgumentException("Unknown recording source " + value);
    }

    private static ScaleKind parseScaleKind(String value) {
        if ("unknown".equals(value)) return ScaleKind.UNKNOWN;
        if ("bookoo".equals(value)) return ScaleKind.BOOKOO;
        if ("bookooMini".equals(value)) return ScaleKind.BOOKOO_MINI;
        if ("bookooUltra".equals(value)) return ScaleKind.BOOKOO_ULTRA;
        if ("weighMyBru".equals(value)) return ScaleKind.WEIGH_MY_BRU;
        if ("weighMyBruPlus".equals(value)) return ScaleKind.WEIGH_MY_BRU_PLUS;
        if ("eureka".equals(value)) return ScaleKind.EUREKA;
        if ("acaia".equals(value)) return ScaleKind.ACAIA;
        if ("decent".equals(value)) return ScaleKind.DECENT;
        if ("espressi".equals(value)) return ScaleKind.ESPRESSI;
        if ("difluid".equals(value)) return ScaleKind.DIFLUID;
        if ("difluidTi".equals(value)) return ScaleKind.DIFLUID_TI;
        if ("felicita".equals(value)) return ScaleKind.FELICITA;
        if ("futula".equals(value)) return ScaleKind.FUTULA;
        if ("skale2".equals(value)) return ScaleKind.SKALE2;
        if ("timemoreDot".equals(value)) return ScaleKind.TIMEMORE_DOT;
        throw new IllegalArgumentException("Unknown scale kind " + value);
    }

    private static DeviceClockSemantics parseClockSemantics(String value) {
        if ("none".equals(value)) return DeviceClockSemantics.NONE;
        if ("freeRunning".equals(value)) return DeviceClockSemantics.FREE_RUNNING;
        if ("shotTimer".equals(value)) return DeviceClockSemantics.SHOT_TIMER;
        throw new IllegalArgumentException("Unknown device clock semantics " + value);
    }

    private static PacketRole parsePacketRole(String value) {
        if ("weight".equals(value)) return PacketRole.WEIGHT;
        if ("capabilities".equals(value)) return PacketRole.CAPABILITIES;
        if ("battery".equals(value)) return PacketRole.BATTERY;
        if ("commandAck".equals(value)) return PacketRole.COMMAND_ACK;
        if ("unknown".equals(value)) return PacketRole.UNKNOWN;
        throw new IllegalArgumentException("Unknown packet role " + value);
    }

    private static ParseRejectionReason parseRejectionReason(String value) {
        if (value == null || value.isEmpty()) return null;
        if ("invalidLength".equals(value)) return ParseRejectionReason.INVALID_LENGTH;
        if ("invalidProduct".equals(value)) return ParseRejectionReason.INVALID_PRODUCT;
        if ("invalidMessageType".equals(value)) return ParseRejectionReason.INVALID_MESSAGE_TYPE;
        if ("invalidChecksum".equals(value)) return ParseRejectionReason.INVALID_CHECKSUM;
        if ("invalidHeader".equals(value)) return ParseRejectionReason.INVALID_HEADER;
        if ("invalidUnit".equals(value)) return ParseRejectionReason.INVALID_UNIT;
        if ("invalidRange".equals(value)) return ParseRejectionReason.INVALID_RANGE;
        if ("invalidCRC".equals(value)) return ParseRejectionReason.INVALID_CRC;
        if ("invalidFloat".equals(value)) return ParseRejectionReason.INVALID_FLOAT;
        if ("unsupportedFrame".equals(value)) return ParseRejectionReason.UNSUPPORTED_FRAME;
        if ("unsupportedCharacteristic".equals(value)) return ParseRejectionReason.UNSUPPORTED_CHARACTERISTIC;
        throw new IllegalArgumentException("Unknown packet rejection reason " + value);
    }

    private static List<String> jsonStrings(JSONArray array) {
        List<String> values = new ArrayList<>();
        if (array == null) return values;
        for (int index = 0; index < array.length(); index++) {
            values.add(array.optString(index));
        }
        return values;
    }

    private static String nullableString(JSONObject object, String key) {
        return object.isNull(key) ? null : object.optString(key, null);
    }

    private static Integer nullableInt(JSONObject object, String key) {
        return object.isNull(key) ? null : object.optInt(key);
    }

    private static Long nullableLong(JSONObject object, String key) {
        return object.isNull(key) ? null : object.optLong(key);
    }

    private static Double nullableDouble(JSONObject object, String key) {
        return object.isNull(key) ? null : object.optDouble(key);
    }

    private void sort() {
        recordings.sort(Comparator.comparingLong((SavedRecordingSummary saved) -> saved.savedAtMillis).reversed());
    }

    private static void deleteQuietly(File file) throws Exception {
        if (file.exists() && !file.delete()) {
            throw new IllegalStateException("Could not delete " + file.getName());
        }
    }

    static void deleteBackupFiles(File recordingDirectory, String recordingId) throws Exception {
        File backupDirectory = new File(recordingDirectory, ".backups");
        if (!backupDirectory.exists()) return;
        File[] backups = backupDirectory.listFiles((directory, name) ->
                name.startsWith(recordingId + ".") || name.startsWith(recordingId + "-")
        );
        if (backups == null) {
            throw new IllegalStateException("Could not inspect recording backups");
        }
        for (File backup : backups) deleteQuietly(backup);
    }

    static ScaleRecording recoverRecordingFromBackup(File recordingFile) throws Exception {
        File parent = recordingFile.getAbsoluteFile().getParentFile();
        if (parent == null) return null;
        File backupDirectory = new File(parent, ".backups");
        File[] backups = backupDirectory.listFiles((directory, name) ->
                name.startsWith(recordingFile.getName() + ".") && name.endsWith(".bak")
        );
        if (backups == null || backups.length == 0) return null;
        Arrays.sort(backups, Comparator.comparingLong(File::lastModified).reversed());
        for (File backup : backups) {
            try {
                ScaleRecording recovered = readRecording(backup);
                JsonExporter.copyAtomically(backup, recordingFile);
                return recovered;
            } catch (Exception ignored) {
                // Continue to the next older backup.
            }
        }
        return null;
    }

    private void cleanupPendingWrites() {
        File[] pending = directory.listFiles((dir, name) -> name.startsWith(".") && name.endsWith(".tmp"));
        if (pending == null) return;
        for (File file : pending) {
            if (!file.delete()) file.deleteOnExit();
        }
    }

    private void backupExistingFileIfNeeded(File file) throws Exception {
        if (!file.exists()) return;
        File backupDirectory = new File(directory, ".backups");
        if (!backupDirectory.exists() && !backupDirectory.mkdirs()) {
            throw new IllegalStateException("Could not create recording backup directory");
        }
        File backup = new File(
                backupDirectory,
                file.getName() + "." + System.currentTimeMillis() + ".bak"
        );
        try (FileInputStream input = new FileInputStream(file);
             FileOutputStream output = new FileOutputStream(backup)) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = input.read(buffer)) >= 0) {
                output.write(buffer, 0, read);
            }
        }
    }

    private static String readText(File file) throws Exception {
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            int offset = 0;
            while (offset < bytes.length) {
                int read = input.read(bytes, offset, bytes.length - offset);
                if (read < 0) break;
                offset += read;
            }
            return new String(bytes, 0, offset, StandardCharsets.UTF_8);
        }
    }
}
