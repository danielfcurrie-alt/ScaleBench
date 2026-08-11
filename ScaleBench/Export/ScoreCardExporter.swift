import Foundation
import SwiftUI
import UIKit

enum ScoreCardExporter {
    static func officialRecording(from recording: ScaleRecording) -> ScaleRecording {
        var finalized = recording
        finalized.schemaVersion = ScaleRecording.schemaVersion
        finalized.endedAt = finalized.endedAt ?? Date()
        finalized.scoringProfile = .standard
        finalized.metrics = ScaleQualityAnalyzer.analyze(finalized, profile: .standard)
        return finalized
    }

    @MainActor
    static func exportOfficial(_ recording: ScaleRecording) throws -> URL {
        let finalized = officialRecording(from: recording)
        let renderer = ImageRenderer(content: ShareableScoreCard(recording: finalized))
        renderer.scale = 2

        guard let pngData = renderer.uiImage?.pngData() else {
            throw ScoreCardExportError.renderFailed
        }

        let timestamp = ISO8601DateFormatter()
            .string(from: finalized.endedAt ?? Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeName = finalized.device?.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-") ?? "scale"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBench-official-scorecard-\(safeName)-\(timestamp).png")
        try pngData.write(to: url, options: [.atomic])
        return url
    }
}

enum ScoreCardExportError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "Could not render scorecard image"
        }
    }
}

private struct ShareableScoreCard: View {
    let recording: ScaleRecording

    private var metrics: ScaleQualityMetrics { recording.metrics }
    private var protocolName: String {
        recording.device?.kind.displayName ?? recording.samples.last?.scaleKind.displayName ?? "Unknown Scale"
    }
    private var deviceName: String {
        recording.device?.name ?? "Unknown device"
    }
    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: recording.endedAt ?? recording.startedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            HStack(alignment: .lastTextBaseline, spacing: 18) {
                Text(metrics.overallScore.map(String.init) ?? "—")
                    .font(.system(size: 136, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/100")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 14) {
                scorePill(title: "Transport", value: metrics.transportScore)
                scorePill(title: "Stability", value: metrics.stabilityScore)
                scorePill(title: "Metadata", value: metrics.metadataScore)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                metricTile(title: "Sample rate", value: formatRate(metrics.effectiveSampleRateHz))
                metricTile(title: "Interval p95", value: formatMilliseconds(metrics.packetIntervalP95Milliseconds))
                metricTile(title: "Max gap", value: formatMilliseconds(metrics.packetIntervalMaxMilliseconds))
                metricTile(title: "Long gaps", value: "\(metrics.longGapCount)")
                metricTile(title: "Missing seq", value: "\(metrics.missingSequenceCount)")
                metricTile(title: "Rejected", value: "\(metrics.rejectedPacketCount)")
                metricTile(title: "Idle noise", value: metrics.idleNoisePeakToPeakGrams.map { String(format: "%.2f g p-p", $0) } ?? "—")
                metricTile(title: "Bumps", value: "\(metrics.firmwareBumpCount)")
            }

            if !recording.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(recording.notes)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }

            Spacer(minLength: 0)

            Text("Official ScaleBench score. Scored with \(recording.scoringProfile.name). Raw recording export available from ScaleBench.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(54)
        .frame(width: 1080, height: 1350)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ScaleBench Official Score")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Spacer()
                Text("Standard v1")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
            }

            Text("\(protocolName) · \(recording.mode.displayName)")
                .font(.title)
                .foregroundStyle(.secondary)

            Text("\(deviceName) · \(dateString)")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }

    private func scorePill(title: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0)" } ?? "—")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(20)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private func formatRate(_ value: Double?) -> String {
    value.map { String(format: "%.1f Hz", $0) } ?? "—"
}

private func formatMilliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
}
