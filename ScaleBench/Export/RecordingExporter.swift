import Combine
import Foundation

enum RecordingExporter {
    static func export(_ recording: ScaleRecording) throws -> URL {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? Date()
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized)

        let data = try SharedRecordingCodec.gzipExportData(from: finalized, recalculateMetrics: false)
        let timestamp = ISO8601DateFormatter()
            .string(from: finalized.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let safeName = finalized.device?.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-") ?? "scale"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBench-\(safeName)-\(timestamp).json.gz")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

struct RecordingImportDataItem {
    let data: Data
    let fallbackTitle: String
}

struct RecordingImportURLItem {
    let url: URL
    let fallbackTitle: String
}

struct RecordingImportBatchResult {
    let imported: [SavedScaleRecording]
    let failures: [String]
}

final class SavedRecordingStore: ObservableObject {
    @Published private(set) var recordings: [SavedScaleRecording] = []
    @Published private(set) var lastErrorMessage: String?

    private let directoryURL: URL
    private let fileManager: FileManager
    private let seedExamples: Bool
    private let workQueue = DispatchQueue(label: "app.scalebench.saved-recordings", qos: .userInitiated)

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        seedExamples: Bool? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        let usesDefaultDirectory = directoryURL == nil
        self.seedExamples = seedExamples ?? usesDefaultDirectory
        if usesDefaultDirectory {
            loadInBackground(seedWhenFinished: true)
        } else {
            load()
            seedExampleRecordingsIfNeeded()
        }
    }

    @discardableResult
    func save(
        recording: ScaleRecording,
        notes: String,
        title: String? = nil,
        metricsAreCurrent: Bool = false
    ) -> SavedScaleRecording? {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let saved = SavedScaleRecording.make(
                recording: recording,
                title: title,
                notes: notes,
                recalculateMetrics: !metricsAreCurrent
            )
            let url = fileURL(for: saved.id)

            try backupExistingFileIfNeeded(at: url)
            try SharedRecordingCodec.storageData(
                from: saved.recording,
                recalculateMetrics: false
            ).write(to: url, options: [.atomic])

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

    func saveInBackground(
        recording: ScaleRecording,
        notes: String,
        title: String? = nil,
        metricsAreCurrent: Bool = false,
        completion: @escaping (Result<SavedScaleRecording, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            do {
                let saved = SavedScaleRecording.make(
                    recording: recording,
                    title: title,
                    notes: notes,
                    recalculateMetrics: !metricsAreCurrent
                )
                guard let self else { return }
                try self.persistPreparedRecording(saved)
                DispatchQueue.main.async {
                    self.insertPreparedRecording(saved)
                    self.lastErrorMessage = nil
                    completion(.success(saved))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.lastErrorMessage = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    func load() {
        let result = Self.loadRecordings(from: directoryURL, fileManager: fileManager)
        recordings = result.recordings
        lastErrorMessage = result.errorMessage
    }

    private func loadInBackground(seedWhenFinished: Bool) {
        let directoryURL = directoryURL
        let fileManager = fileManager
        workQueue.async { [weak self] in
            let result = Self.loadRecordings(from: directoryURL, fileManager: fileManager)
            DispatchQueue.main.async {
                guard let self else { return }
                self.recordings = result.recordings
                self.lastErrorMessage = result.errorMessage
                if seedWhenFinished {
                    self.seedExampleRecordingsIfNeeded()
                }
            }
        }
    }

    private static func loadRecordings(
        from directoryURL: URL,
        fileManager: FileManager
    ) -> (recordings: [SavedScaleRecording], errorMessage: String?) {
        do {
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return ([], nil)
            }

            let recordingFiles = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            .filter { Self.isRecordingStorageFile($0) }

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

            let recordings = winnersByID.values
                .map { $0.saved }
            .sorted { $0.savedAt > $1.savedAt }
            let errorMessage = failedFileCount == 0
                ? nil
                : "\(failedFileCount) saved recording file\(failedFileCount == 1 ? "" : "s") could not be read. Files were left in place."
            return (recordings, errorMessage)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    func delete(_ saved: SavedScaleRecording) {
        do {
            try deleteBackupFiles(for: saved.id)
            let url = fileURL(for: saved.id)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            let legacyURL = legacyFileURL(for: saved.id)
            if fileManager.fileExists(atPath: legacyURL.path) {
                try fileManager.removeItem(at: legacyURL)
            }
            recordings.removeAll { $0.id == saved.id }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func importRecording(from url: URL) -> SavedScaleRecording? {
        do {
            return try importRecordingOrThrow(from: url)
        } catch {
            lastErrorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importRecordingOrThrow(from url: URL) throws -> SavedScaleRecording {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        return try importRecordingDataOrThrow(
            data,
            fallbackTitle: "Imported \(url.deletingPathExtension().lastPathComponent)"
        )
    }

    @discardableResult
    func importRecordingData(_ data: Data, fallbackTitle: String) -> SavedScaleRecording? {
        do {
            return try importRecordingDataOrThrow(data, fallbackTitle: fallbackTitle)
        } catch {
            lastErrorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importRecordingDataOrThrow(_ data: Data, fallbackTitle: String) throws -> SavedScaleRecording {
        let saved = try Self.preparedImportedRecording(from: data, fallbackTitle: fallbackTitle)
        try persistPreparedRecording(saved)
        insertPreparedRecording(saved)
        lastErrorMessage = nil
        return saved
    }

    func importRecordingInBackground(
        from url: URL,
        completion: @escaping (Result<SavedScaleRecording, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                guard let self else { return }
                try self.importPreparedRecordingInBackground(
                    data,
                    fallbackTitle: "Imported \(url.deletingPathExtension().lastPathComponent)",
                    completion: completion
                )
            } catch {
                DispatchQueue.main.async {
                    self?.lastErrorMessage = "Import failed: \(error.localizedDescription)"
                    completion(.failure(error))
                }
            }
        }
    }

    func importRecordingDataInBackground(
        _ data: Data,
        fallbackTitle: String,
        completion: @escaping (Result<SavedScaleRecording, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            do {
                guard let self else { return }
                try self.importPreparedRecordingInBackground(
                    data,
                    fallbackTitle: fallbackTitle,
                    completion: completion
                )
            } catch {
                DispatchQueue.main.async {
                    self?.lastErrorMessage = "Import failed: \(error.localizedDescription)"
                    completion(.failure(error))
                }
            }
        }
    }

    func importRecordingDataBatchInBackground(
        _ items: [RecordingImportDataItem],
        completion: @escaping (RecordingImportBatchResult) -> Void
    ) {
        guard !items.isEmpty else {
            completion(RecordingImportBatchResult(imported: [], failures: ["No files were selected."]))
            return
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            var imported: [SavedScaleRecording] = []
            var failures: [String] = []

            for item in items {
                do {
                    let saved = try Self.preparedImportedRecording(
                        from: item.data,
                        fallbackTitle: item.fallbackTitle
                    )
                    try self.persistPreparedRecording(saved)
                    imported.append(saved)
                } catch {
                    failures.append("\(item.fallbackTitle): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for saved in imported {
                    self.insertPreparedRecording(saved)
                }
                self.lastErrorMessage = failures.isEmpty
                    ? nil
                    : "Import failed for \(failures.count) file(s)."
                completion(RecordingImportBatchResult(imported: imported, failures: failures))
            }
        }
    }

    func importRecordingURLBatchInBackground(
        _ items: [RecordingImportURLItem],
        completion: @escaping (RecordingImportBatchResult) -> Void
    ) {
        guard !items.isEmpty else {
            completion(RecordingImportBatchResult(imported: [], failures: ["No files were selected."]))
            return
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            var imported: [SavedScaleRecording] = []
            var failures: [String] = []

            for item in items {
                do {
                    let saved = try Self.preparedImportedRecording(
                        from: item.url,
                        fallbackTitle: item.fallbackTitle
                    )
                    try self.persistPreparedRecording(saved)
                    imported.append(saved)
                } catch {
                    failures.append("\(item.fallbackTitle): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for saved in imported {
                    self.insertPreparedRecording(saved)
                }
                self.lastErrorMessage = failures.isEmpty
                    ? nil
                    : "Import failed for \(failures.count) file(s)."
                completion(RecordingImportBatchResult(imported: imported, failures: failures))
            }
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
        directoryURL.appendingPathComponent("\(id.uuidString).json.z")
    }

    private func legacyFileURL(for id: UUID) -> URL {
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
        return files.contains(where: Self.isRecordingStorageFile)
    }

    private func backupExistingFileIfNeeded(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let recordingID = url.lastPathComponent.split(separator: ".", maxSplits: 1).first.map(String.init)
            ?? url.deletingPathExtension().lastPathComponent
        let backupURL = backupDirectoryURL
            .appendingPathComponent("\(recordingID)-\(timestamp).bak")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func deleteBackupFiles(for id: UUID) throws {
        guard fileManager.fileExists(atPath: backupDirectoryURL.path) else { return }
        let prefixes = ["\(id.uuidString)-", "\(id.uuidString).json-"]
        let backups = try fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        for backup in backups where prefixes.contains(where: { backup.lastPathComponent.hasPrefix($0) }) {
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

    private static func preparedImportedRecording(from data: Data, fallbackTitle: String) throws -> SavedScaleRecording {
        let imported = try decodeImportedRecording(from: data)
        let embeddedTitle = imported.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = embeddedTitle?.isEmpty == false ? embeddedTitle : fallbackTitle
        return SavedScaleRecording.make(
            recording: imported,
            title: title,
            notes: imported.notes,
            recalculateMetrics: true
        )
    }

    private static func preparedImportedRecording(from url: URL, fallbackTitle: String) throws -> SavedScaleRecording {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try preparedImportedRecording(from: data, fallbackTitle: fallbackTitle)
    }

    private func importPreparedRecordingInBackground(
        _ data: Data,
        fallbackTitle: String,
        completion: @escaping (Result<SavedScaleRecording, Error>) -> Void
    ) throws {
        let saved = try Self.preparedImportedRecording(from: data, fallbackTitle: fallbackTitle)
        try persistPreparedRecording(saved)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.insertPreparedRecording(saved)
            self.lastErrorMessage = nil
            completion(.success(saved))
        }
    }

    private func persistPreparedRecording(_ saved: SavedScaleRecording) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = fileURL(for: saved.id)
        try backupExistingFileIfNeeded(at: url)
        try backupExistingFileIfNeeded(at: legacyFileURL(for: saved.id))
        try SharedRecordingCodec.storageData(
            from: saved.recording,
            recalculateMetrics: false
        ).write(to: url, options: [.atomic])
        let legacyURL = legacyFileURL(for: saved.id)
        if fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.removeItem(at: legacyURL)
        }
    }

    private func insertPreparedRecording(_ saved: SavedScaleRecording) {
        recordings.removeAll { $0.id == saved.id }
        recordings.insert(saved, at: 0)
        recordings = recordings.sorted { $0.savedAt > $1.savedAt }
    }

    private static func decodeSavedRecordingFile(at url: URL) -> SavedScaleRecording? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let recording = try? SharedRecordingCodec.decodeRecording(from: data) else { return nil }
        return savedRecording(from: recording, savedAt: savedAt(for: url))
    }

    private static func isRecordingStorageFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".json") || name.hasSuffix(".json.z") || name.hasSuffix(".json.gz")
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

enum SavedRecordingImportError: LocalizedError {
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case let .saveFailed(message):
            return message
        }
    }
}
