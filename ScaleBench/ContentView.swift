import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothScaleManager
    @StateObject private var savedStore = SavedRecordingStore()
    @StateObject private var scoringStore = CustomScoringProfileStore()
    @State private var selectedMode: RecordingMode = .shot
    @State private var selectedScoringProfileID = ScoringProfileOption.builtIn(.standard).id
    @State private var recordingNotes = ""
    @State private var exportURL: URL?
    @State private var scoreCardURL: URL?
    @State private var scoreCardErrorMessage: String?
    @State private var activeSheet: ActiveSheet?
    @ScaledMetric(relativeTo: .body) private var notesMinHeight = 72

    var body: some View {
        NavigationStack {
            List {
                Section("Bluetooth") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(bluetooth.bluetoothStateTitle)
                            Text(bluetooth.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(bluetooth.isScanning ? "Stop" : "Scan") {
                            bluetooth.isScanning ? bluetooth.stopScanning() : bluetooth.startScanning()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("Scales") {
                    if bluetooth.discoveredScales.isEmpty {
                        ContentUnavailableView("No scales yet", systemImage: "antenna.radiowaves.left.and.right", description: Text("Start scanning and power on a supported Bluetooth scale."))
                    } else {
                        ForEach(bluetooth.discoveredScales) { device in
                            Button {
                                bluetooth.connect(to: device)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name)
                                            .font(.headline)
                                        Text("\(device.kind.displayName) · RSSI \(device.rssi)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if bluetooth.connectedDevice?.id == device.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityLabel("Connected")
                                    }
                                }
                                .contentShape(Rectangle())
                                .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Recording") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("How to use ScaleBench", systemImage: "list.number")
                            .font(.headline)
                        Text("Connect a scale, choose what you are testing, start recording, then stop and save/export. Official share cards always use ScaleBench Standard v1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Mode", selection: $selectedMode) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    ModeHelpCard(mode: selectedMode)

                    Picker("Scoring", selection: $selectedScoringProfileID) {
                        ForEach(scoringOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .onChange(of: selectedScoringProfileID) { _, _ in
                        bluetooth.applyScoringProfile(selectedScoringProfile)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedScoringProfile.name == ScoringProfile.standardBenchmarkName
                            ? "Official comparable benchmark profile. Use this for public tester score claims."
                            : "Custom profile. Useful for experiments, but not comparable to Standard v1 scores.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ViewThatFits(in: .horizontal) {
                            HStack {
                                scoringButtons
                            }

                            VStack(alignment: .leading) {
                                scoringButtons
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $recordingNotes)
                            .frame(minHeight: notesMinHeight)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary)
                            }
                    }

                    RecordingActionButtons(
                        isRecording: bluetooth.isRecording,
                        canRecord: bluetooth.connectedDevice != nil,
                        canExport: !bluetooth.currentRecording.samples.isEmpty || !bluetooth.currentRecording.rawPackets.isEmpty,
                        startOrStop: {
                            if bluetooth.isRecording {
                                stopRecordingAndShowResults()
                            } else {
                                startRecordingAndShowTimer()
                            }
                        },
                        export: {
                            bluetooth.applyScoringProfile(selectedScoringProfile)
                            exportURL = bluetooth.exportCurrentRecording(notes: recordingNotes)
                        }
                    )

                    Button {
                        bluetooth.applyScoringProfile(selectedScoringProfile)
                        let snapshot = bluetooth.finalizedCurrentRecording(notes: recordingNotes)
                        _ = savedStore.save(recording: snapshot, notes: recordingNotes)
                    } label: {
                        Label("Save Recording", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.isRecording || (bluetooth.currentRecording.samples.isEmpty && bluetooth.currentRecording.rawPackets.isEmpty))

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share JSON \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }

                    if let scoreCardURL {
                        ShareLink(item: scoreCardURL) {
                            Label("Share Official Scorecard \(scoreCardURL.lastPathComponent)", systemImage: "photo")
                        }
                    }

                    if let error = savedStore.lastErrorMessage {
                        Text("Save error: \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Live") {
                    MetricRow(title: "Weight", value: bluetooth.latestSample.map { String(format: "%.2f g", $0.weightGrams) } ?? "—")
                    MetricRow(title: "Flow", value: bluetooth.latestSample?.flowGramsPerSecond.map { String(format: "%.2f g/s", $0) } ?? "—")
                    MetricRow(title: "Battery", value: bluetooth.latestSample?.batteryPercent.map { "\($0)%" } ?? bluetooth.latestBatteryPercent.map { "\($0)%" } ?? "—")
                    MetricRow(title: "Protocol", value: bluetooth.activeProtocol.displayName)
                    MetricRow(title: "Packets", value: "\(bluetooth.currentRecording.rawPackets.count)")
                    MetricRow(title: "Samples", value: "\(bluetooth.currentRecording.samples.count)")
                }

                Section("Scorecard") {
                    let metrics = bluetooth.currentMetrics
                    MetricRow(title: "Scoring", value: bluetooth.currentRecording.scoringProfile.name)
                    MetricRow(title: "Benchmark", value: bluetooth.currentRecording.scoringProfile.name == ScoringProfile.standardBenchmarkName ? "Standard v1" : "Custom")
                    MetricRow(title: "Overall", value: metrics.overallScore.map { "\($0)/100" } ?? "—")
                    MetricRow(title: "Transport", value: metrics.transportScore.map { "\($0)/100" } ?? "—")
                    MetricRow(title: "Stability", value: metrics.stabilityScore.map { "\($0)/100" } ?? "—")
                    MetricRow(title: "Effective rate", value: metrics.effectiveSampleRateHz.map { String(format: "%.1f Hz", $0) } ?? "—")
                    MetricRow(title: "Interval p95", value: metrics.packetIntervalP95Milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                    MetricRow(title: "Max gap", value: metrics.packetIntervalMaxMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                    MetricRow(title: "Long gaps", value: "\(metrics.longGapCount)")
                    MetricRow(title: "Missing seq", value: "\(metrics.missingSequenceCount)")
                    MetricRow(title: "Rejected", value: "\(metrics.rejectedPacketCount)")
                    MetricRow(title: "Idle noise", value: metrics.idleNoisePeakToPeakGrams.map { String(format: "%.2f g p-p", $0) } ?? "—")
                    MetricRow(title: "Drift", value: metrics.driftGramsPerMinute.map { String(format: "%.3f g/min", $0) } ?? "—")

                    ViewThatFits(in: .horizontal) {
                        HStack {
                            scorecardButtons
                        }

                        VStack(alignment: .leading) {
                            scorecardButtons
                        }
                    }

                    Text("Shared scorecards always use ScaleBench Standard v1, even if a custom scoring profile is selected for analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let scoreCardErrorMessage {
                        Text("Scorecard error: \(scoreCardErrorMessage)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Protocol comparison") {
                    let comparison = savedStore.comparison
                    if comparison.rows.count < 2 {
                        ContentUnavailableView("Save two recordings", systemImage: "chart.bar.xaxis", description: Text("Record WMB, WMB+, BooKoo standard, or native BooKoo sessions, then compare their scores side by side."))
                    } else {
                        if let best = comparison.bestOverall {
                            MetricRow(title: "Best overall", value: "\(best.protocolKind.displayName) · \(best.score.map { "\($0)" } ?? "—")")
                        }
                        ForEach(comparison.rows) { row in
                            ComparisonRow(row: row)
                        }
                    }
                }

                Section("Saved recordings") {
                    if savedStore.recordings.isEmpty {
                        ContentUnavailableView("No saved recordings", systemImage: "tray", description: Text("Saved recordings keep the raw packets, score snapshot, scoring profile, and your notes."))
                    } else {
                        ForEach(savedStore.recordings) { saved in
                            NavigationLink {
                                SavedRecordingDetailView(saved: saved) {
                                    activeSheet = .scoreExplanation(saved.recording)
                                }
                            } label: {
                                SavedRecordingRow(saved: saved)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { savedStore.recordings[$0] }.forEach(savedStore.delete)
                        }
                    }
                }
            }
            .navigationTitle("ScaleBench")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") {
                        bluetooth.resetRecording()
                        exportURL = nil
                        scoreCardURL = nil
                        scoreCardErrorMessage = nil
                        activeSheet = nil
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .recordingTimer:
                    RecordingTimerView(bluetooth: bluetooth) {
                        stopRecordingAndShowResults()
                    }
                    .presentationDetents([.medium])
                case let .recordingResults(recording):
                    RecordingResultsView(
                        recording: recording,
                        save: { recording in
                            savedStore.save(recording: recording, notes: recording.notes)
                        },
                        exportJSON: { recording in
                            try? RecordingExporter.export(recording)
                        },
                        exportScorecard: { recording in
                            try ScoreCardExporter.exportOfficial(recording)
                        },
                        explain: { recording in
                            activeSheet = .scoreExplanation(recording)
                        }
                    )
                    .presentationDetents([.large])
                case let .scoreExplanation(recording):
                    ScoreExplanationView(recording: recording, profile: recording.scoringProfile)
                case let .scoringEditor(customProfile):
                    ScoringProfileEditorView(
                        customProfile: customProfile,
                        baseProfile: selectedScoringProfile
                    ) { profile, id in
                        if let saved = scoringStore.save(profile: profile, id: id) {
                            selectedScoringProfileID = ScoringProfileOption.custom(saved).id
                            bluetooth.applyScoringProfile(saved.profile)
                        }
                    }
                }
            }
        }
    }

    private func startRecordingAndShowTimer() {
        bluetooth.applyScoringProfile(selectedScoringProfile)
        exportURL = nil
        scoreCardURL = nil
        scoreCardErrorMessage = nil
        bluetooth.startRecording(mode: selectedMode, scoringProfile: selectedScoringProfile)
        activeSheet = .recordingTimer
    }

    private func stopRecordingAndShowResults() {
        if bluetooth.isRecording {
            bluetooth.stopRecording()
        }
        let snapshot = bluetooth.finalizedCurrentRecording(notes: recordingNotes)
        activeSheet = .recordingResults(snapshot)
    }

    private var scoringOptions: [ScoringProfileOption] {
        ScoringPreset.allCases.map(ScoringProfileOption.builtIn)
            + scoringStore.profiles.map(ScoringProfileOption.custom)
    }

    private var selectedScoringProfile: ScoringProfile {
        scoringOptions.first { $0.id == selectedScoringProfileID }?.profile ?? .standard
    }

    private var selectedCustomScoringProfile: CustomScoringProfile? {
        scoringStore.profiles.first { ScoringProfileOption.custom($0).id == selectedScoringProfileID }
    }

    @ViewBuilder
    private var scoringButtons: some View {
        Button {
            activeSheet = .scoringEditor(nil)
        } label: {
            Label("New Custom Profile", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)

        if let selectedCustomScoringProfile {
            Button {
                activeSheet = .scoringEditor(selectedCustomScoringProfile)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                scoringStore.delete(selectedCustomScoringProfile)
                selectedScoringProfileID = ScoringProfileOption.builtIn(.standard).id
                bluetooth.applyScoringProfile(.standard)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var scorecardButtons: some View {
        Button {
            bluetooth.applyScoringProfile(selectedScoringProfile)
            let snapshot = bluetooth.finalizedCurrentRecording(notes: recordingNotes)
            activeSheet = .scoreExplanation(snapshot)
        } label: {
            Label("Explain Score", systemImage: "questionmark.circle")
        }
        .buttonStyle(.bordered)

        Button {
            bluetooth.applyScoringProfile(selectedScoringProfile)
            do {
                let finalized = bluetooth.finalizedCurrentRecording(notes: recordingNotes)
                scoreCardURL = try ScoreCardExporter.exportOfficial(finalized)
                scoreCardErrorMessage = nil
            } catch {
                scoreCardErrorMessage = error.localizedDescription
            }
        } label: {
            Label("Export Official Scorecard", systemImage: "photo")
        }
        .buttonStyle(.borderedProminent)
        .disabled(bluetooth.currentRecording.samples.isEmpty && bluetooth.currentRecording.rawPackets.isEmpty)
    }
}

private enum ActiveSheet: Identifiable {
    case recordingTimer
    case recordingResults(ScaleRecording)
    case scoreExplanation(ScaleRecording)
    case scoringEditor(CustomScoringProfile?)

    var id: String {
        switch self {
        case .recordingTimer: "recording-timer"
        case let .recordingResults(recording): "recording-results-\(recording.id.uuidString)"
        case let .scoreExplanation(recording): "score-explanation-\(recording.id.uuidString)"
        case let .scoringEditor(profile): "scoring-editor-\(profile?.id.uuidString ?? "new")"
        }
    }
}

private struct ScoringProfileOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let profile: ScoringProfile

    static func builtIn(_ preset: ScoringPreset) -> ScoringProfileOption {
        ScoringProfileOption(
            id: "built-in-\(preset.rawValue)",
            displayName: preset.displayName,
            profile: preset.profile
        )
    }

    static func custom(_ custom: CustomScoringProfile) -> ScoringProfileOption {
        ScoringProfileOption(
            id: "custom-\(custom.id.uuidString)",
            displayName: custom.profile.name,
            profile: custom.profile
        )
    }
}

private struct ModeHelpCard: View {
    let mode: RecordingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode.shortDescription)
            Text(mode.suggestedDuration)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingTimerView: View {
    @ObservedObject var bluetooth: BluetoothScaleManager
    let stop: () -> Void

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Recording", systemImage: "record.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.red)

                            Text(formatDuration(recordingDuration(bluetooth.currentRecording, now: context.date)))
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .monospacedDigit()

                            Text(bluetooth.currentRecording.mode.shortDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }

                    Section("Live capture") {
                        MetricRow(title: "Samples", value: "\(bluetooth.currentRecording.samples.count)")
                        MetricRow(title: "Packets", value: "\(bluetooth.currentRecording.rawPackets.count)")
                        MetricRow(title: "Weight", value: bluetooth.latestSample.map { String(format: "%.2f g", $0.weightGrams) } ?? "—")
                        MetricRow(title: "Flow", value: bluetooth.latestSample?.flowGramsPerSecond.map { String(format: "%.2f g/s", $0) } ?? "—")
                        MetricRow(title: "Battery", value: bluetooth.latestSample?.batteryPercent.map { "\($0)%" } ?? bluetooth.latestBatteryPercent.map { "\($0)%" } ?? "—")
                    }

                    Section {
                        Button(role: .destructive, action: stop) {
                            Label("Stop and View Results", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Recording")
        }
    }
}

private struct RecordingResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let recording: ScaleRecording
    let save: (ScaleRecording) -> SavedScaleRecording?
    let exportJSON: (ScaleRecording) -> URL?
    let exportScorecard: (ScaleRecording) throws -> URL
    let explain: (ScaleRecording) -> Void

    @State private var didSave = false
    @State private var jsonURL: URL?
    @State private var scorecardURL: URL?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScoreHero(metrics: recording.metrics)
                    Text(resultNarrative(for: recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Recording summary") {
                    RecordingSummaryRows(recording: recording, metrics: recording.metrics)
                }

                Section("Actions") {
                    Button {
                        if save(recording) != nil {
                            didSave = true
                            statusMessage = "Recording saved."
                            errorMessage = nil
                        } else {
                            errorMessage = "Save failed."
                        }
                    } label: {
                        Label(didSave ? "Saved" : "Save Recording", systemImage: didSave ? "checkmark.circle.fill" : "tray.and.arrow.down")
                    }
                    .disabled(didSave)

                    Button {
                        jsonURL = exportJSON(recording)
                        errorMessage = jsonURL == nil ? "JSON export failed." : nil
                    } label: {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        do {
                            scorecardURL = try exportScorecard(recording)
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Label("Export Official Scorecard", systemImage: "photo")
                    }

                    Button {
                        explain(recording)
                    } label: {
                        Label("Explain This Score", systemImage: "questionmark.circle")
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let jsonURL {
                    ShareLink(item: jsonURL) {
                        Label("Share JSON \(jsonURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }

                if let scorecardURL {
                    ShareLink(item: scorecardURL) {
                        Label("Share Official Scorecard \(scorecardURL.lastPathComponent)", systemImage: "photo")
                    }
                }
            }
            .navigationTitle("Results")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SavedRecordingDetailView: View {
    let saved: SavedScaleRecording
    let explain: () -> Void

    private var recording: ScaleRecording { saved.recording }
    private var metrics: ScaleQualityMetrics { saved.scoreSnapshot }

    var body: some View {
        List {
            Section {
                ScoreHero(metrics: metrics)
                Text(resultNarrative(for: recording))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording summary") {
                RecordingSummaryRows(recording: recording, metrics: metrics)
                MetricRow(title: "Saved", value: saved.savedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Stream visualizer") {
                RecordingStreamChart(recording: recording)
                    .frame(height: 180)
                    .padding(.vertical, 8)
                Text("Weight stream over recording time. This is a compact visual sanity check; packet-level inspection is below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Score") {
                Button(action: explain) {
                    Label("Explain This Score", systemImage: "questionmark.circle")
                }
                MetricRow(title: "Transport", value: metrics.transportScore.map { "\($0)/100" } ?? "—")
                MetricRow(title: "Stability", value: metrics.stabilityScore.map { "\($0)/100" } ?? "—")
                MetricRow(title: "Metadata", value: metrics.metadataScore.map { "\($0)/100" } ?? "—")
            }

            Section("Raw packet preview") {
                if recording.rawPackets.isEmpty {
                    Text("No raw packets captured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recording.rawPackets.prefix(24)) { packet in
                        RawPacketRow(packet: packet)
                    }
                    if recording.rawPackets.count > 24 {
                        Text("\(recording.rawPackets.count - 24) more packets in JSON export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !saved.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Notes") {
                    Text(saved.notes)
                }
            }
        }
        .navigationTitle(saved.title)
    }
}

private struct ScoreHero: View {
    let metrics: ScaleQualityMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Official score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metrics.overallScore.map { "\($0)" } ?? "—")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            Spacer()

            Text("Standard v1")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingSummaryRows: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics

    var body: some View {
        MetricRow(title: "Mode", value: recording.mode.displayName)
        MetricRow(title: "Duration", value: formatDuration(recordingDuration(recording)))
        MetricRow(title: "Protocol", value: recording.device?.kind.displayName ?? recording.samples.last?.scaleKind.displayName ?? "—")
        MetricRow(title: "Samples", value: "\(recording.samples.count)")
        MetricRow(title: "Packets", value: "\(recording.rawPackets.count)")
        MetricRow(title: "Effective rate", value: formatRate(metrics.effectiveSampleRateHz))
        MetricRow(title: "p95 interval", value: formatMilliseconds(metrics.packetIntervalP95Milliseconds))
        MetricRow(title: "Max gap", value: formatMilliseconds(metrics.packetIntervalMaxMilliseconds))
        MetricRow(title: "Long gaps", value: "\(metrics.longGapCount)")
        MetricRow(title: "Rejected packets", value: "\(metrics.rejectedPacketCount)")
    }
}

private struct RecordingStreamChart: View {
    let recording: ScaleRecording

    var body: some View {
        Canvas { context, size in
            let samples = recording.samples
            guard samples.count >= 2,
                  let firstTime = samples.first?.monotonicSeconds,
                  let lastTime = samples.last?.monotonicSeconds else {
                drawEmptyChart(in: &context, size: size)
                return
            }

            let weights = samples.map(\.weightGrams)
            guard let minimumWeight = weights.min(),
                  let maximumWeight = weights.max() else {
                drawEmptyChart(in: &context, size: size)
                return
            }

            let timeSpan = max(lastTime - firstTime, 0.001)
            let weightSpan = max(maximumWeight - minimumWeight, 0.001)
            let inset: CGFloat = 8
            let chartRect = CGRect(
                x: inset,
                y: inset,
                width: max(1, size.width - inset * 2),
                height: max(1, size.height - inset * 2)
            )

            var path = Path()
            for (index, sample) in samples.enumerated() {
                let x = chartRect.minX + chartRect.width * CGFloat((sample.monotonicSeconds - firstTime) / timeSpan)
                let normalizedWeight = (sample.weightGrams - minimumWeight) / weightSpan
                let y = chartRect.maxY - chartRect.height * CGFloat(normalizedWeight)
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: chartRect.minX, y: chartRect.maxY))
            baseline.addLine(to: CGPoint(x: chartRect.maxX, y: chartRect.maxY))

            context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text(weightRangeLabel(recording))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func drawEmptyChart(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
    }
}

private struct RawPacketRow: View {
    let packet: RawScalePacket

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(packet.role.rawValue)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let rejectionReason = packet.rejectionReason {
                    Text(rejectionReason.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Text(packet.characteristicUUID)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(packet.bytesHex)
                .font(.caption2.monospaced())
                .lineLimit(2)
        }
    }
}

private struct ScoreExplanationView: View {
    @Environment(\.dismiss) private var dismiss
    let recording: ScaleRecording
    let profile: ScoringProfile

    private var metrics: ScaleQualityMetrics { recording.metrics }
    private var normalizedProfile: ScoringProfile { profile.normalized }

    var body: some View {
        NavigationStack {
            List {
                Section("This recording") {
                    ScoreHero(metrics: metrics)
                    Text(resultNarrative(for: recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RecordingSummaryRows(recording: recording, metrics: metrics)
                }

                Section("Benchmark identity") {
                    MetricRow(title: "Profile", value: profile.name)
                    MetricRow(title: "Comparable badge", value: profile.name == ScoringProfile.standardBenchmarkName ? "ScaleBench Standard v1" : "Custom")
                    Text("Use ScaleBench Standard v1 when publishing tester scores. Custom profiles are saved into JSON exports, but they are not directly comparable to Standard v1 results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Formula") {
                    Text("Overall score is the weighted sum of transport, stability, and metadata scores.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MetricRow(title: "Transport weight", value: formatPercent(normalizedProfile.transportWeight))
                    MetricRow(title: "Stability weight", value: formatPercent(normalizedProfile.stabilityWeight))
                    MetricRow(title: "Metadata weight", value: formatPercent(normalizedProfile.metadataWeight))
                    MetricRow(title: "Overall", value: metrics.overallScore.map { "\($0)/100" } ?? "—")
                }

                Section("Transport") {
                    MetricRow(title: "Score", value: metrics.transportScore.map { "\($0)/100" } ?? "—")
                    MetricRow(title: "Effective rate", value: formatRate(metrics.effectiveSampleRateHz))
                    MetricRow(title: "p50 interval", value: formatMilliseconds(metrics.packetIntervalP50Milliseconds))
                    MetricRow(title: "p95 interval", value: formatMilliseconds(metrics.packetIntervalP95Milliseconds))
                    MetricRow(title: "Max gap", value: formatMilliseconds(metrics.packetIntervalMaxMilliseconds))
                    MetricRow(title: "Long gaps", value: "\(metrics.longGapCount)")
                    MetricRow(title: "Missing sequence", value: "\(metrics.missingSequenceCount)")
                    MetricRow(title: "Timestamp issues", value: "\(metrics.duplicateOrOutOfOrderTimestampCount)")
                    MetricRow(title: "Rejected packets", value: "\(metrics.rejectedPacketCount)")
                    MetricRow(title: "Long-gap floor", value: formatMilliseconds(profile.minimumLongGapMilliseconds))
                    MetricRow(title: "Long-gap multiplier", value: String(format: "%.2fx", profile.longGapMultiplier))
                }

                Section("Stability") {
                    MetricRow(title: "Score", value: metrics.stabilityScore.map { "\($0)/100" } ?? "—")
                    MetricRow(title: "Idle noise", value: metrics.idleNoisePeakToPeakGrams.map { String(format: "%.3f g p-p", $0) } ?? "—")
                    MetricRow(title: "Idle std dev", value: metrics.idleNoiseStandardDeviationGrams.map { String(format: "%.3f g", $0) } ?? "—")
                    MetricRow(title: "Drift", value: metrics.driftGramsPerMinute.map { String(format: "%.3f g/min", $0) } ?? "—")
                    MetricRow(title: "Bump count", value: "\(metrics.firmwareBumpCount)")
                }

                Section("Metadata") {
                    MetricRow(title: "Score", value: metrics.metadataScore.map { "\($0)/100" } ?? "—")
                    MetricRow(title: "Battery range", value: batteryRange(metrics))
                    MetricRow(title: "Firmware quality", value: metrics.firmwareQualityAverage.map { String(format: "%.1f/100", $0) } ?? "—")
                    Text("Metadata rewards protocols that expose device timestamps, sequence numbers, battery, and firmware-side quality. It is intentionally modest in Standard v1 so good legacy scales are not crushed just for having a simpler packet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Explain Score")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func batteryRange(_ metrics: ScaleQualityMetrics) -> String {
        switch (metrics.batteryMinPercent, metrics.batteryMaxPercent) {
        case let (.some(minimum), .some(maximum)) where minimum == maximum:
            "\(minimum)%"
        case let (.some(minimum), .some(maximum)):
            "\(minimum)-\(maximum)%"
        default:
            "—"
        }
    }
}

private struct ScoringProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScoringProfile
    let existingID: UUID?
    let onSave: (ScoringProfile, UUID?) -> Void

    init(
        customProfile: CustomScoringProfile?,
        baseProfile: ScoringProfile,
        onSave: @escaping (ScoringProfile, UUID?) -> Void
    ) {
        let initialProfile: ScoringProfile
        if let customProfile {
            initialProfile = customProfile.profile
        } else {
            var copy = baseProfile
            copy.name = baseProfile.name == ScoringProfile.standardBenchmarkName
                ? "Custom Standard v1"
                : "\(baseProfile.name) Copy"
            initialProfile = copy
        }

        _draft = State(initialValue: initialProfile)
        existingID = customProfile?.id
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Profile name", text: $draft.name)
                    Text("Custom profiles are stored locally and embedded in JSON exports. Use ScaleBench Standard v1 for public apples-to-apples comparisons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Weights") {
                    DoubleSettingRow(
                        title: "Transport",
                        value: $draft.transportWeight,
                        range: 0...1,
                        step: 0.01,
                        format: formatPercent
                    )
                    DoubleSettingRow(
                        title: "Stability",
                        value: $draft.stabilityWeight,
                        range: 0...1,
                        step: 0.01,
                        format: formatPercent
                    )
                    DoubleSettingRow(
                        title: "Metadata",
                        value: $draft.metadataWeight,
                        range: 0...1,
                        step: 0.01,
                        format: formatPercent
                    )
                    MetricRow(title: "Normalized total", value: "100%")
                }

                Section("Transport penalties") {
                    DoubleSettingRow(
                        title: "Minimum long gap",
                        value: $draft.minimumLongGapMilliseconds,
                        range: 50...1_000,
                        step: 10,
                        format: { String(format: "%.0f ms", $0) }
                    )
                    DoubleSettingRow(
                        title: "Gap multiplier",
                        value: $draft.longGapMultiplier,
                        range: 1...8,
                        step: 0.25,
                        format: { String(format: "%.2fx", $0) }
                    )
                    IntSettingRow(title: "Long gap penalty", value: $draft.longGapPenalty, range: 0...25)
                    IntSettingRow(title: "Missing seq penalty", value: $draft.missingSequencePenalty, range: 0...25)
                    IntSettingRow(title: "Timestamp penalty", value: $draft.timestampIssuePenalty, range: 0...25)
                    DoubleSettingRow(
                        title: "Rejected packet scale",
                        value: $draft.rejectedPacketRatePenaltyScale,
                        range: 0...300,
                        step: 5,
                        format: { String(format: "%.0f", $0) }
                    )
                }

                Section("Stability penalties") {
                    DoubleSettingRow(
                        title: "Free p-p noise",
                        value: $draft.idleNoiseFreePeakToPeakGrams,
                        range: 0...1,
                        step: 0.01,
                        format: { String(format: "%.2f g", $0) }
                    )
                    DoubleSettingRow(
                        title: "p-p penalty scale",
                        value: $draft.idleNoisePeakToPeakPenaltyScale,
                        range: 0...50,
                        step: 1,
                        format: { String(format: "%.0f", $0) }
                    )
                    DoubleSettingRow(
                        title: "Free std dev",
                        value: $draft.idleStandardDeviationFreeGrams,
                        range: 0...0.5,
                        step: 0.01,
                        format: { String(format: "%.2f g", $0) }
                    )
                    DoubleSettingRow(
                        title: "Std dev penalty scale",
                        value: $draft.idleStandardDeviationPenaltyScale,
                        range: 0...150,
                        step: 1,
                        format: { String(format: "%.0f", $0) }
                    )
                    DoubleSettingRow(
                        title: "Drift penalty scale",
                        value: $draft.driftPenaltyScale,
                        range: 0...20,
                        step: 0.5,
                        format: { String(format: "%.1f", $0) }
                    )
                }
            }
            .navigationTitle(existingID == nil ? "New Scoring Profile" : "Edit Scoring Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft, existingID)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct DoubleSettingRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct IntSettingRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
        }
    }
}

private struct ComparisonRow: View {
    let row: ProtocolComparisonRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.protocolKind.displayName)
                    .font(.headline)
                Spacer()
                Text(row.score.map { "\($0)/100" } ?? "—")
                    .monospacedDigit()
            }
            Text("\(row.mode.displayName) · \(row.sampleCount) samples · \(formatRate(row.sampleRateHz)) · p95 \(formatMilliseconds(row.p95IntervalMilliseconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("gaps \(row.longGapCount) · rejected \(row.rejectedPacketCount) · max \(formatMilliseconds(row.maxGapMilliseconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SavedRecordingRow: View {
    let saved: SavedScaleRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(saved.title)
                    .font(.headline)
                Spacer()
                Text(saved.scoreSnapshot.overallScore.map { "\($0)/100" } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("\(saved.protocolKind.displayName) · \(formatDuration(recordingDuration(saved.recording))) · \(saved.recording.samples.count) samples · \(formatRate(saved.scoreSnapshot.effectiveSampleRateHz))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !saved.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(saved.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecordingActionButtons: View {
    let isRecording: Bool
    let canRecord: Bool
    let canExport: Bool
    let startOrStop: () -> Void
    let export: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                buttons
            }

            VStack(alignment: .leading) {
                buttons
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(isRecording ? "Stop Recording" : "Start Recording", action: startOrStop)
            .buttonStyle(.borderedProminent)
            .disabled(!canRecord)

        Button("Export JSON", action: export)
            .buttonStyle(.bordered)
            .disabled(!canExport)
    }
}

private func formatRate(_ value: Double?) -> String {
    value.map { String(format: "%.1f Hz", $0) } ?? "—"
}

private func formatMilliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
}

private func formatMilliseconds(_ value: Double) -> String {
    String(format: "%.0f ms", value)
}

private func formatPercent(_ value: Double) -> String {
    String(format: "%.0f%%", value * 100)
}

private func recordingDuration(_ recording: ScaleRecording, now: Date = Date()) -> TimeInterval {
    let end = recording.endedAt ?? now
    return max(0, end.timeIntervalSince(recording.startedAt))
}

private func formatDuration(_ value: TimeInterval) -> String {
    let totalSeconds = max(0, Int(value.rounded()))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return "\(hours)h \(minutes)m \(seconds)s"
    }
    if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
}

private func weightRangeLabel(_ recording: ScaleRecording) -> String {
    let weights = recording.samples.map(\.weightGrams)
    guard let minimum = weights.min(), let maximum = weights.max() else {
        return "No weight samples"
    }
    return String(format: "%.2f–%.2f g", minimum, maximum)
}

private func resultNarrative(for recording: ScaleRecording) -> String {
    let metrics = recording.metrics
    guard let score = metrics.overallScore else {
        return "No score yet. A recording needs at least two parsed samples before ScaleBench can calculate transport and stability metrics."
    }

    var parts: [String] = []
    switch score {
    case 90...100:
        parts.append("Excellent capture.")
    case 75..<90:
        parts.append("Good capture with some measurable imperfections.")
    case 50..<75:
        parts.append("Usable capture, but quality issues are affecting the score.")
    default:
        parts.append("Poor capture. This recording has significant transport, parsing, or stability issues.")
    }

    if let rate = metrics.effectiveSampleRateHz {
        parts.append("Effective cadence was \(String(format: "%.1f Hz", rate)).")
    }
    if metrics.longGapCount > 0 {
        parts.append("\(metrics.longGapCount) long gap\(metrics.longGapCount == 1 ? "" : "s") were detected.")
    }
    if metrics.rejectedPacketCount > 0 {
        parts.append("\(metrics.rejectedPacketCount) packet\(metrics.rejectedPacketCount == 1 ? "" : "s") were rejected by the parser.")
    }
    if metrics.missingSequenceCount > 0 {
        parts.append("\(metrics.missingSequenceCount) missing sequence step\(metrics.missingSequenceCount == 1 ? "" : "s") were inferred.")
    }
    if recording.mode == .idleStability {
        if let noise = metrics.idleNoisePeakToPeakGrams {
            parts.append("Idle noise was \(String(format: "%.2f g peak-to-peak", noise)).")
        }
        if let drift = metrics.driftGramsPerMinute {
            parts.append("Drift was \(String(format: "%.3f g/min", drift)).")
        }
    }
    if metrics.firmwareBumpCount > 0 {
        parts.append("Firmware reported \(metrics.firmwareBumpCount) bump/disturbance event\(metrics.firmwareBumpCount == 1 ? "" : "s").")
    }

    return parts.joined(separator: " ")
}

#Preview {
    ContentView()
        .environmentObject(BluetoothScaleManager.preview)
}
