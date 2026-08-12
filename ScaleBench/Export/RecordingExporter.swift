import Combine
import Foundation

enum RecordingExporter {
    static func export(_ recording: ScaleRecording) throws -> URL {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? Date()
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)

        let data = try SharedRecordingCodec.exportData(from: finalized)
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

            try backupExistingFileIfNeeded(at: url)
            try SharedRecordingCodec.exportData(from: saved.recording).write(to: url, options: [.atomic])

            recordings.removeAll { $0.id == saved.id }
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

            let recordingFiles = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            .filter { $0.pathExtension == "json" }

            var failedFileCount = 0
            let decoded = recordingFiles
            .compactMap { url -> (saved: SavedScaleRecording, url: URL)? in
                guard let saved = Self.decodeSavedRecordingFile(at: url) else {
                    failedFileCount += 1
                    return nil
                }
                return (saved, url)
            }

            var winnersByID: [UUID: (saved: SavedScaleRecording, url: URL)] = [:]
            for entry in decoded {
                if let existing = winnersByID[entry.saved.id], existing.saved.savedAt >= entry.saved.savedAt {
                    continue
                }
                winnersByID[entry.saved.id] = entry
            }

            recordings = winnersByID.values
                .map { $0.saved }
            .sorted { $0.savedAt > $1.savedAt }
            lastErrorMessage = failedFileCount == 0
                ? nil
                : "\(failedFileCount) saved recording file\(failedFileCount == 1 ? "" : "s") could not be read. Files were left in place."
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func delete(_ saved: SavedScaleRecording) {
        do {
            try deleteBackupFiles(for: saved.id)
            let url = fileURL(for: saved.id)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            recordings.removeAll { $0.id == saved.id }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func importRecording(from url: URL) -> SavedScaleRecording? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let imported = try Self.decodeImportedRecording(from: data)
            let embeddedTitle = imported.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = embeddedTitle?.isEmpty == false
                ? embeddedTitle
                : "Imported \(url.deletingPathExtension().lastPathComponent)"
            return save(recording: imported, notes: imported.notes, title: title)
        } catch {
            lastErrorMessage = "Import failed: \(error.localizedDescription)"
            return nil
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

    private var backupDirectoryURL: URL {
        directoryURL.appendingPathComponent(".backups", isDirectory: true)
    }

    private func seedExampleRecordingsIfNeeded() {
        guard seedExamples else { return }
        if fileManager.fileExists(atPath: examplesMarkerURL.path) { return }
        if hasAnyRecordingFiles() {
            return
        }
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

    private func hasAnyRecordingFiles() -> Bool {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return false
        }
        return files.contains { $0.pathExtension == "json" }
    }

    private func backupExistingFileIfNeeded(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = backupDirectoryURL
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(timestamp)")
            .appendingPathExtension(url.pathExtension)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func deleteBackupFiles(for id: UUID) throws {
        guard fileManager.fileExists(atPath: backupDirectoryURL.path) else { return }
        let prefix = "\(id.uuidString)-"
        let backups = try fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        for backup in backups where backup.lastPathComponent.hasPrefix(prefix) {
            try fileManager.removeItem(at: backup)
        }
    }

    private static func savedRecording(from recording: ScaleRecording, savedAt: Date) -> SavedScaleRecording {
        var refreshed = recording
        refreshed.schemaVersion = ScaleRecording.schemaVersion
        refreshed.scoringModelVersion = ScaleRecording.scoringModelVersion
        if refreshed.scoringProfile.name == ScoringProfile.standardBenchmarkName {
            refreshed.scoringProfile = .standard
        }
        refreshed.metrics = ScaleQualityAnalyzer.analyze(refreshed)
        let title = refreshed.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? refreshed.title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : defaultTitle(for: refreshed)
        refreshed.title = title
        return SavedScaleRecording(
            id: refreshed.id,
            savedAt: savedAt,
            title: title,
            notes: refreshed.notes,
            recording: refreshed,
            scoreSnapshot: refreshed.metrics
        )
    }

    private static func decodeSavedRecordingFile(at url: URL) -> SavedScaleRecording? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let recording = try? SharedRecordingCodec.decodeRecording(from: data) else { return nil }
        return savedRecording(from: recording, savedAt: savedAt(for: url))
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ScaleBench", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    private static func decodeImportedRecording(from data: Data) throws -> ScaleRecording {
        try SharedRecordingCodec.decodeRecording(from: data)
    }

    private static func defaultTitle(for recording: ScaleRecording) -> String {
        let protocolName = recording.device?.kind.displayName
            ?? recording.samples.last?.scaleKind.displayName
            ?? "Unknown Scale"
        return "\(protocolName) · \(recording.mode.displayName)"
    }

    private static func savedAt(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }
}
