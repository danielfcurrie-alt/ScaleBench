import Combine
import Foundation

enum RecordingExporter {
    static func export(_ recording: ScaleRecording) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var finalized = recording
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

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        load()
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

    var comparison: ProtocolComparison {
        ProtocolComparison.make(from: recordings)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ScaleBench", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}
