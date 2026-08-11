package app.scalebench.android;

import android.content.Context;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

final class SavedRecordingStore {
    private final File directory;
    private final List<SavedRecordingSummary> recordings = new ArrayList<>();

    SavedRecordingStore(Context context) {
        directory = new File(context.getFilesDir(), "recordings");
        load();
    }

    List<SavedRecordingSummary> recordings() {
        return new ArrayList<>(recordings);
    }

    SavedRecordingSummary save(ScaleRecording recording, String notes, String title) throws Exception {
        directory.mkdirs();
        recording.endedAtMillis = recording.endedAtMillis == null ? System.currentTimeMillis() : recording.endedAtMillis;
        recording.notes = notes == null ? "" : notes;
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);

        SavedRecordingSummary summary = new SavedRecordingSummary();
        summary.id = UUID.randomUUID().toString();
        summary.savedAtMillis = System.currentTimeMillis();
        summary.title = title == null || title.trim().isEmpty() ? recording.defaultTitle() : title.trim();
        summary.notes = recording.notes;
        summary.recordingFileName = summary.id + "-recording.json";
        summary.protocolKind = protocolKind(recording);
        summary.mode = recording.mode;
        summary.score = recording.metrics.overallScore;
        summary.sampleCount = recording.samples.size();
        summary.rawPacketCount = recording.rawPackets.size();

        JsonExporter.writeRecording(recording, new File(directory, summary.recordingFileName));
        writeSummary(summary);
        recordings.add(summary);
        sort();
        return summary;
    }

    void delete(SavedRecordingSummary summary) throws Exception {
        deleteQuietly(new File(directory, summary.id + ".summary.json"));
        deleteQuietly(new File(directory, summary.recordingFileName));
        recordings.removeIf(saved -> saved.id.equals(summary.id));
    }

    JSONObject recordingObject(SavedRecordingSummary summary) throws Exception {
        return new JSONObject(readText(new File(directory, summary.recordingFileName)));
    }

    void load() {
        recordings.clear();
        if (!directory.exists()) return;
        File[] files = directory.listFiles((dir, name) -> name.endsWith(".summary.json"));
        if (files == null) return;
        for (File file : files) {
            try {
                recordings.add(readSummary(file));
            } catch (Exception ignored) {
                // Ignore one corrupt summary instead of hiding the rest of the library.
            }
        }
        sort();
    }

    private void writeSummary(SavedRecordingSummary summary) throws Exception {
        JSONObject object = new JSONObject();
        object.put("id", summary.id);
        object.put("savedAtMillis", summary.savedAtMillis);
        object.put("title", summary.title);
        object.put("notes", summary.notes);
        object.put("recordingFileName", summary.recordingFileName);
        object.put("protocolKind", summary.protocolKind.name());
        object.put("mode", summary.mode.name());
        object.put("score", summary.score == null ? JSONObject.NULL : summary.score);
        object.put("sampleCount", summary.sampleCount);
        object.put("rawPacketCount", summary.rawPacketCount);
        try (OutputStreamWriter writer = new OutputStreamWriter(
                new FileOutputStream(new File(directory, summary.id + ".summary.json")),
                StandardCharsets.UTF_8
        )) {
            writer.write(object.toString(2));
        }
    }

    private SavedRecordingSummary readSummary(File file) throws Exception {
        JSONObject object = new JSONObject(readText(file));
        SavedRecordingSummary summary = new SavedRecordingSummary();
        summary.id = object.getString("id");
        summary.savedAtMillis = object.getLong("savedAtMillis");
        summary.title = object.optString("title", "Untitled Recording");
        summary.notes = object.optString("notes", "");
        summary.recordingFileName = object.optString("recordingFileName", summary.id + "-recording.json");
        summary.protocolKind = ScaleKind.valueOf(object.optString("protocolKind", ScaleKind.UNKNOWN.name()));
        summary.mode = RecordingMode.valueOf(object.optString("mode", RecordingMode.SHOT.name()));
        summary.score = object.isNull("score") ? null : object.getInt("score");
        summary.sampleCount = object.optInt("sampleCount", 0);
        summary.rawPacketCount = object.optInt("rawPacketCount", 0);
        return summary;
    }

    private ScaleKind protocolKind(ScaleRecording recording) {
        if (recording.device != null) return recording.device.kind;
        if (!recording.samples.isEmpty()) return recording.samples.get(recording.samples.size() - 1).scaleKind;
        return ScaleKind.UNKNOWN;
    }

    private void sort() {
        recordings.sort(Comparator.comparingLong((SavedRecordingSummary saved) -> saved.savedAtMillis).reversed());
    }

    private void deleteQuietly(File file) throws Exception {
        if (file.exists() && !file.delete()) {
            throw new IllegalStateException("Could not delete " + file.getName());
        }
    }

    private String readText(File file) throws Exception {
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
