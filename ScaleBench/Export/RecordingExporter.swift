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

