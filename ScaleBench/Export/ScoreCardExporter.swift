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

    static func officialPayload(from recording: ScaleRecording) -> OfficialScorecardPayload {
        OfficialScorecardPayload.make(from: recording)
    }

    @MainActor
    static func exportOfficial(_ recording: ScaleRecording) throws -> URL {
        let finalized = officialRecording(from: recording)
        guard finalized.metrics.validity?.isValid == true else {
            let reasons = finalized.metrics.validity?.reasons.joined(separator: ", ") ?? "unknown validity error"
            throw ScoreCardExportError.invalidRecording(reasons)
        }
        guard finalized.metrics.overallScore != nil else {
            throw ScoreCardExportError.metricsOnlyMode
        }
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
    case invalidRecording(String)
    case metricsOnlyMode

    var errorDescription: String? {
        switch self {
        case .renderFailed: "Could not render scorecard image"
        case let .invalidRecording(reasons): "This recording is not valid for an official scorecard: \(reasons)"
        case .metricsOnlyMode: "This recording mode reports metrics and does not produce an official 0–100 score."
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
    private var scoreTitle: String {
        recording.mode == .idleStability ? "Idle Stability" : "Delivery"
    }
    private var benchmarkScore: Int? {
        switch recording.mode {
        case .shot, .transportStress:
            metrics.delivery?.deliveryScore
        case .idleStability:
            metrics.stabilityScore
        case .stepResponse, .tareLatency, .batteryStability:
            nil
        }
    }
    private var scoreText: String {
        benchmarkScore.map { "\($0)" } ?? "—"
    }
    private var platformName: String {
        switch recording.platform {
        case "macos-catalyst": "macOS Catalyst"
        case "android": "Android"
        default: "iOS / iPadOS"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scoreTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(scoreText)
                            .font(.system(size: 104, weight: .black, design: .rounded))
                            .monospacedDigit()
                        Text("/100")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text(protocolName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.trailing)
                    Text(recording.mode.displayName)
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: 310, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .padding(28)
            .background(scoreAccentGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 14) {
                if recording.mode == .idleStability {
                    scorePill(title: "Noise", value: metrics.idleNoiseScore)
                    scorePill(title: "Drift", value: metrics.idleDriftScore)
                    valuePill(title: "Analysed", value: metrics.idleAnalysedSampleCount.map { "\($0) frames" } ?? "—")
                } else {
                    valuePill(title: "Delivered", value: deliveredPacketsText)
                    valuePill(title: "Usable", value: usableReadingsText)
                    valuePill(title: "Checks", value: packetChecksText)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                metricTile(title: "Max gap", value: formatMilliseconds(metrics.packetIntervalMaxMilliseconds))
                metricTile(title: "Long gaps", value: "\(metrics.longGapCount)")
                metricTile(title: "p95 interval", value: formatMilliseconds(metrics.packetIntervalP95Milliseconds))
                metricTile(title: "Rejected", value: "\(metrics.rejectedPacketCount)")
            }

            if !recording.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(recording.notes)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if recording.mode == .shot || recording.mode == .transportStress {
                Text(deliveryFormulaText)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 0)

            Text(recording.mode == .idleStability
                ? "Official ScaleBench Standard v1 Idle Stability result. Noise and drift are a separate domain from Delivery. Raw evidence is available in the JSON export."
                : "Official ScaleBench Standard v1 Delivery result. Delivered packets and usable readings create the score; packet checks explain how much the protocol lets ScaleBench verify.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(34)
        .frame(width: 900, height: 900)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.98, blue: 0.98),
                    Color(red: 0.90, green: 0.94, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        HStack(spacing: 16) {
            logoView

            VStack(alignment: .leading, spacing: 5) {
                Text("ScaleBench")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                Text("\(deviceName) · \(platformName) · \(dateString)")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Standard v1")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.04, green: 0.23, blue: 0.31))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(red: 0.39, green: 0.83, blue: 0.76).opacity(0.24), in: Capsule())
        }
    }

    @ViewBuilder
    private var logoView: some View {
        if let image = UIImage(named: "ScorecardLogo")
            ?? UIImage(named: "AppIcon")
            ?? UIImage(named: "AppIcon-1024")
            ?? UIImage(named: "AppIcon-512") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.02, green: 0.13, blue: 0.25))
                Image(systemName: "scalemass")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
        }
    }

    private var scoreAccentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.02, green: 0.13, blue: 0.25),
                Color(red: 0.06, green: 0.45, blue: 0.43)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        .padding(16)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func valuePill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var deliveredPacketsText: String {
        if let served = metrics.servedSlots,
           let total = metrics.slotCount,
           total > 0,
           let coverage = metrics.delivery?.coverage {
            return "\(served)/\(total) (\(formatPercent(coverage)))"
        }
        return metrics.delivery?.coverage.map(formatPercent) ?? "—"
    }

    private var usableReadingsText: String {
        if let usable = metrics.usableSampleCount,
           let total = metrics.relevantWeightFrameCount,
           total > 0,
           let purity = metrics.delivery?.purity {
            return "\(usable)/\(total) (\(formatPercent(purity)))"
        }
        return metrics.delivery?.purity.map(formatPercent) ?? "—"
    }

    private var packetChecksText: String {
        guard let verification = metrics.protocolVerification else { return "—" }
        let total = verification.verifiableClasses.count + verification.unverifiableClasses.count
        guard total > 0 else { return "—" }
        return "\(verification.verifiableClasses.count)/\(total)"
    }

    private var deliveryFormulaText: String {
        guard let score = metrics.delivery?.deliveryScore,
              let coverage = metrics.delivery?.coverage,
              let purity = metrics.delivery?.purity else {
            return "Score needs enough delivered packets and usable readings."
        }
        return "Score: round(100 × \(formatMultiplier(coverage)) × \(formatMultiplier(purity))) = \(score)/100."
    }
}

private func formatRate(_ value: Double?) -> String {
    value.map { String(format: "%.1f Hz", $0) } ?? "—"
}

private func formatMilliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
}

private func formatPercent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
}

private func formatMultiplier(_ value: Double) -> String {
    String(format: "%.3f", value)
}
