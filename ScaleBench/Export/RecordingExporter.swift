import Combine
import Foundation

enum RecordingExporter {
    static func export(_ recording: ScaleRecording) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? Date()
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)

        let data = try encoder.encode(finalized)
        let timestamp = ISO8601DateFormatter()
            .string(from: finalized.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let safeName = finalized.device?.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-") ?? "scale"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBench-\(safeName)-\(timestamp).json")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

final class SavedRecordingStore: ObservableObject {
    @Published private(set) var recordings: [SavedScaleRecording] = []
    @Published private(set) var lastErrorMessage: String?

    private let directoryURL: URL
    private let fileManager: FileManager
    private let seedExamples: Bool

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        seedExamples: Bool? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.seedExamples = seedExamples ?? (directoryURL == nil)
        load()
        seedExampleRecordingsIfNeeded()
    }

    @discardableResult
    func save(recording: ScaleRecording, notes: String, title: String? = nil) -> SavedScaleRecording? {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let saved = SavedScaleRecording.make(recording: recording, title: title, notes: notes)
            let url = fileURL(for: saved.id)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(saved).write(to: url, options: [.atomic])

            recordings.insert(saved, at: 0)
            recordings = recordings.sorted { $0.savedAt > $1.savedAt }
            lastErrorMessage = nil
            return saved
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func load() {
        do {
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                recordings = []
                lastErrorMessage = nil
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recordings = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                try? decoder.decode(SavedScaleRecording.self, from: Data(contentsOf: url))
            }
            .map(Self.migratingScoreIfNeeded)
            .sorted { $0.savedAt > $1.savedAt }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func delete(_ saved: SavedScaleRecording) {
        do {
            try fileManager.removeItem(at: fileURL(for: saved.id))
            recordings.removeAll { $0.id == saved.id }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func loadExampleRecordings() {
        for example in SampleRecordingFactory.examples where !recordings.contains(where: { $0.title == example.title }) {
            save(recording: example.recording, notes: example.notes, title: example.title)
        }
        markExamplesSeeded()
    }

    var comparison: ProtocolComparison {
        ProtocolComparison.make(from: recordings)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private var examplesMarkerURL: URL {
        directoryURL.appendingPathComponent(".examples-seeded-v1")
    }

    private func seedExampleRecordingsIfNeeded() {
        guard seedExamples else { return }
        if fileManager.fileExists(atPath: examplesMarkerURL.path) { return }
        guard recordings.isEmpty else {
            markExamplesSeeded()
            return
        }
        loadExampleRecordings()
    }

    private func markExamplesSeeded() {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data("seeded\n".utf8).write(to: examplesMarkerURL, options: [.atomic])
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func migratingScoreIfNeeded(_ saved: SavedScaleRecording) -> SavedScaleRecording {
        guard saved.recording.schemaVersion < ScaleRecording.schemaVersion else { return saved }
        var migrated = saved
        migrated.recording.schemaVersion = ScaleRecording.schemaVersion
        if migrated.recording.scoringProfile.name == ScoringProfile.standardBenchmarkName {
            migrated.recording.scoringProfile = .standard
        }
        migrated.recording.metrics = ScaleQualityAnalyzer.analyze(migrated.recording)
        migrated.scoreSnapshot = migrated.recording.metrics
        return migrated
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ScaleBench", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}
