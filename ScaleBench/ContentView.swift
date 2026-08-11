import Charts
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
                        Button {
                            activeSheet = .help
                        } label: {
                            Label("Open Full Help", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(.bordered)
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
                        Text(selectedScoringProfile.isStandardBenchmark
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
                    MetricRow(title: "Benchmark", value: bluetooth.currentRecording.scoringProfile.isStandardBenchmark ? "Standard v1" : "Custom")
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
                        ContentUnavailableView {
                            Label("No saved recordings", systemImage: "tray")
                        } description: {
                            Text("Saved recordings keep the raw packets, score snapshot, scoring profile, and your notes.")
                        } actions: {
                            Button {
                                savedStore.loadExampleRecordings()
                            } label: {
                                Label("Load Example Recordings", systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button {
                            savedStore.loadExampleRecordings()
                        } label: {
                            Label("Load Example Recordings", systemImage: "sparkles")
                        }

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
                ToolbarItem(placement: helpToolbarPlacement) {
                    Button {
                        activeSheet = .help
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                }

                ToolbarItem(placement: resetToolbarPlacement) {
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
                case .help:
                    ScaleBenchHelpView()
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
    case help
    case recordingTimer
    case recordingResults(ScaleRecording)
    case scoreExplanation(ScaleRecording)
    case scoringEditor(CustomScoringProfile?)

    var id: String {
        switch self {
        case .help: "help"
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

private struct ScaleBenchHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Quick start") {
                    HelpStepRow(number: 1, title: "Scan and connect", text: "Power on a supported Bluetooth scale, tap Scan, then select the scale.")
                    HelpStepRow(number: 2, title: "Choose a mode", text: "Use Shot / Pour for normal public comparisons. Use the other modes only when testing a specific behavior.")
                    HelpStepRow(number: 3, title: "Record", text: "Tap Start Recording. A timer sheet stays open so it is obvious that capture is running.")
                    HelpStepRow(number: 4, title: "Stop, inspect, save", text: "Tap Stop and View Results, then save the recording, export JSON, or make an official scorecard.")
                }

                Section("Modes") {
                    ForEach(RecordingMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.displayName)
                                .font(.headline)
                            Text(mode.shortDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(mode.suggestedDuration)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Score") {
                    Text("ScaleBench Standard v1 combines transport quality, stability, and metadata coverage into a 0–100 score. Shot / Pour mode does not punish the normal rising beverage weight as idle drift.")
                    Text("Red evidence means a direct score penalty, such as a rejected packet, missing sequence, or parsed-sample long gap. Yellow/orange means warning context.")
                        .foregroundStyle(.secondary)
                }

                Section("Visualizer") {
                    Text("Weight stream shows parsed samples. Packet cadence uses the same parsed sample intervals used by scoring. Packet timeline keeps raw packets for forensic inspection and overlays score-impacting gaps separately.")
                    Text("Open a saved recording to inspect packets, intervals, raw bytes, notes, and the score explanation for that specific capture.")
                        .foregroundStyle(.secondary)
                }

                Section("Examples") {
                    Text("Synthetic examples are bundled so new users can inspect the app without owning a scale yet. They are marked as examples in the title and notes.")
                }
            }
            .navigationTitle("ScaleBench Help")
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

private struct HelpStepRow: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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
                    ScoreHero(metrics: recording.metrics, profile: recording.scoringProfile)
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
                ScoreHero(metrics: metrics, profile: recording.scoringProfile)
                Text(resultNarrative(for: recording))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording summary") {
                RecordingSummaryRows(recording: recording, metrics: metrics)
                MetricRow(title: "Saved", value: saved.savedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Packet visualizer") {
                RecordingVisualizerView(recording: recording, metrics: metrics)
            }

            Section("Score") {
                Button(action: explain) {
                    Label("Explain This Score", systemImage: "questionmark.circle")
                }
                MetricRow(title: "Transport", value: metrics.transportScore.map { "\($0)/100" } ?? "—")
                MetricRow(title: "Stability", value: metrics.stabilityScore.map { "\($0)/100" } ?? "—")
                MetricRow(title: "Metadata", value: metrics.metadataScore.map { "\($0)/100" } ?? "—")
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
    let profile: ScoringProfile

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.isStandardBenchmark ? "Official score" : "Custom score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metrics.overallScore.map { "\($0)" } ?? "—")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            Spacer()

            Text(profile.isStandardBenchmark ? "Standard v1" : "Custom")
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
        MetricRow(title: "Scoring", value: recording.scoringProfile.name)
        MetricRow(title: "Duration", value: formatDuration(recordingDuration(recording)))
        MetricRow(title: "Protocol", value: recording.device?.kind.displayName ?? recording.samples.last?.scaleKind.displayName ?? "—")
        MetricRow(title: "Samples", value: "\(recording.samples.count)")
        MetricRow(title: "Packets", value: "\(recording.rawPackets.count)")
        if !recording.batteryEvents.isEmpty {
            MetricRow(title: "Battery events", value: "\(recording.batteryEvents.count)")
        }
        MetricRow(title: "Effective rate", value: formatRate(metrics.effectiveSampleRateHz))
        MetricRow(title: "p95 interval", value: formatMilliseconds(metrics.packetIntervalP95Milliseconds))
        MetricRow(title: "Max gap", value: formatMilliseconds(metrics.packetIntervalMaxMilliseconds))
        MetricRow(title: "Long gaps", value: "\(metrics.longGapCount)")
        MetricRow(title: "Rejected packets", value: "\(metrics.rejectedPacketCount)")
    }
}

private struct RecordingVisualizerView: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics
    @State private var selectedPacketID: UUID?

    private var timeline: PacketTimeline {
        PacketTimeline.make(recording: recording, metrics: metrics)
    }

    private var selectedEntry: PacketTimelineEntry? {
        let entries = timeline.entries
        if let selectedPacketID,
           let selected = entries.first(where: { $0.id == selectedPacketID }) {
            return selected
        }
        return entries.first(where: { $0.severity == .penalty })
            ?? entries.first(where: { $0.severity == .warning })
            ?? entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PacketEvidenceSummary(metrics: metrics, timeline: timeline, mode: recording.mode)

            VStack(alignment: .leading, spacing: 8) {
                Label("Weight stream", systemImage: "waveform.path.ecg")
                    .font(.headline)
                WeightStreamChart(recording: recording)
                    .frame(height: 180)
                Text("Parsed weight samples over recording time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Packet cadence", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                PacketIntervalChart(timeline: timeline)
                    .frame(height: 170)
                Text("Each bar is a parsed sample interval, matching the scoring calculation. Bars above the threshold line are score-impacting long gaps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Packet timeline", systemImage: "timeline.selection")
                    .font(.headline)
                PacketTimelineCanvas(
                    timeline: timeline,
                    selectedPacketID: selectedEntry?.id,
                    onSelect: { entry in
                        selectedPacketID = entry.id
                    }
                )
                    .frame(height: 116)
                PacketLegend()
                Text("Dense raw packet raster. Click or hover a tick to inspect it below. Red packet ticks are parser rejections; translucent red bands are parsed-sample gaps that directly affect the score.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !timeline.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Packet inspector", systemImage: "scope")
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(timeline.entries.prefix(120)) { entry in
                                PacketChip(
                                    entry: entry,
                                    isSelected: selectedEntry?.id == entry.id
                                ) {
                                    selectedPacketID = entry.id
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if timeline.entries.count > 120 {
                        Text("\(timeline.entries.count - 120) more packets are included in the JSON export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let selectedEntry {
                        RawPacketRow(entry: selectedEntry)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct PacketEvidenceSummary: View {
    let metrics: ScaleQualityMetrics
    let timeline: PacketTimeline
    let mode: RecordingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Score evidence", systemImage: "exclamationmark.magnifyingglass")
                .font(.headline)

            Text(scoreEvidenceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                EvidencePill(title: "Rejected", value: "\(metrics.rejectedPacketCount)", severity: metrics.rejectedPacketCount > 0 ? .penalty : .normal)
                EvidencePill(title: "Long gaps", value: "\(metrics.longGapCount)", severity: metrics.longGapCount > 0 ? .penalty : .normal)
                EvidencePill(title: "Missing seq", value: "\(metrics.missingSequenceCount)", severity: metrics.missingSequenceCount > 0 ? .penalty : .normal)
                EvidencePill(title: "Timestamp", value: "\(metrics.duplicateOrOutOfOrderTimestampCount)", severity: metrics.duplicateOrOutOfOrderTimestampCount > 0 ? .penalty : .normal)
                EvidencePill(title: "Bumps", value: "\(metrics.firmwareBumpCount)", severity: bumpSeverity)
                EvidencePill(title: "Near gaps", value: "\(timeline.warningIntervalCount)", severity: timeline.warningIntervalCount > 0 ? .warning : .normal)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var scoreEvidenceSummary: String {
        let dynamicBumps = mode == .idleStability ? 0 : metrics.firmwareBumpCount
        let directIssues = metrics.rejectedPacketCount
            + metrics.longGapCount
            + metrics.missingSequenceCount
            + metrics.duplicateOrOutOfOrderTimestampCount
            + dynamicBumps
        if directIssues == 0 {
            if metrics.firmwareBumpCount > 0 {
                return "No direct score penalties are visible. Firmware bump flags are warning context in Idle Stability mode."
            }
            return "No direct score penalties are visible in this recording. The score is mostly driven by cadence, stability, and metadata coverage."
        }

        var parts: [String] = []
        if metrics.longGapCount > 0 {
            parts.append("\(metrics.longGapCount) long gap\(metrics.longGapCount == 1 ? "" : "s")")
        }
        if metrics.rejectedPacketCount > 0 {
            parts.append("\(metrics.rejectedPacketCount) rejected packet\(metrics.rejectedPacketCount == 1 ? "" : "s")")
        }
        if metrics.missingSequenceCount > 0 {
            parts.append("\(metrics.missingSequenceCount) missing sequence step\(metrics.missingSequenceCount == 1 ? "" : "s")")
        }
        if metrics.duplicateOrOutOfOrderTimestampCount > 0 {
            parts.append("\(metrics.duplicateOrOutOfOrderTimestampCount) timestamp issue\(metrics.duplicateOrOutOfOrderTimestampCount == 1 ? "" : "s")")
        }
        if dynamicBumps > 0 {
            parts.append("\(metrics.firmwareBumpCount) bump flag\(metrics.firmwareBumpCount == 1 ? "" : "s")")
        }
        return "Score-impacting evidence: \(parts.joined(separator: ", "))."
    }

    private var bumpSeverity: PacketSeverity {
        guard metrics.firmwareBumpCount > 0 else { return .normal }
        return mode == .idleStability ? .warning : .penalty
    }
}

private struct EvidencePill: View {
    let title: String
    let value: String
    let severity: PacketSeverity

    var body: some View {
        HStack {
            Circle()
                .fill(severity.color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(severity.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WeightStreamChart: View {
    let recording: ScaleRecording

    var body: some View {
        if recording.samples.count >= 2, let firstTime = recording.samples.first?.monotonicSeconds {
            Chart(recording.samples) { sample in
                LineMark(
                    x: .value("Seconds", sample.monotonicSeconds - firstTime),
                    y: .value("Weight", sample.weightGrams)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue)

                if sample.diagnosticFlags?.recentBump == true {
                    PointMark(
                        x: .value("Seconds", sample.monotonicSeconds - firstTime),
                        y: .value("Weight", sample.weightGrams)
                    )
                    .foregroundStyle(.yellow)
                    .symbolSize(45)
                }
            }
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("grams")
        } else {
            EmptyVisualizerChart(message: "No parsed weight stream.")
        }
    }
}

private struct PacketIntervalChart: View {
    let timeline: PacketTimeline

    var body: some View {
        let intervalEntries = timeline.sampleIntervals
        if intervalEntries.isEmpty {
            EmptyVisualizerChart(message: "No parsed sample intervals.")
        } else {
            Chart {
                ForEach(intervalEntries) { entry in
                    BarMark(
                        x: .value("Seconds", entry.relativeSeconds),
                        y: .value("Interval", entry.intervalMilliseconds)
                    )
                    .foregroundStyle(entry.color)
                }

                RuleMark(y: .value("Long gap threshold", timeline.longGapThresholdMilliseconds))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(.red.opacity(0.65))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("long gap")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
            }
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("ms")
        }
    }
}

private struct EmptyVisualizerChart: View {
    let message: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PacketTimelineCanvas: View {
    let timeline: PacketTimeline
    let selectedPacketID: UUID?
    let onSelect: (PacketTimelineEntry) -> Void
    @State private var hoveredPacketID: UUID?

    private var hoveredEntry: PacketTimelineEntry? {
        guard let hoveredPacketID else { return nil }
        return timeline.entries.first { $0.id == hoveredPacketID }
    }

    var body: some View {
        Canvas { context, size in
            guard !timeline.entries.isEmpty else {
                drawEmptyTimeline(context: &context, size: size)
                return
            }

            let layout = TimelineCanvasLayout(size: size)
            let rect = layout.rect
            let laneHeight = layout.laneHeight
            let duration = max(timeline.durationSeconds, 0.001)

            for lane in PacketLane.allCases {
                let y = rect.minY + laneHeight * (CGFloat(lane.index) + 0.5)
                var lanePath = Path()
                lanePath.move(to: CGPoint(x: rect.minX, y: y))
                lanePath.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(lanePath, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
            }

            for gap in timeline.scoringGaps {
                let previousX = rect.minX + rect.width * CGFloat(max(0, gap.startRelativeSeconds) / duration)
                let currentX = rect.minX + rect.width * CGFloat(max(0, gap.endRelativeSeconds) / duration)
                let bandRect = CGRect(
                    x: min(previousX, currentX),
                    y: rect.minY,
                    width: max(2, abs(currentX - previousX)),
                    height: rect.height
                )
                context.fill(Path(bandRect), with: .color(.red.opacity(0.12)))
            }

            for entry in timeline.entries {
                let x = rect.minX + rect.width * CGFloat(entry.relativeSeconds / duration)
                let lane = entry.lane
                let y = rect.minY + laneHeight * (CGFloat(lane.index) + 0.5)
                let isSelected = entry.id == selectedPacketID
                let isHovered = entry.id == hoveredPacketID
                let tickHeight = laneHeight * (entry.severity == .penalty ? 0.82 : 0.60)

                if isSelected || isHovered {
                    let markerRect = CGRect(
                        x: x - 6,
                        y: y - tickHeight / 2 - 4,
                        width: 12,
                        height: tickHeight + 8
                    )
                    context.fill(Path(roundedRect: markerRect, cornerRadius: 5), with: .color(entry.color.opacity(isSelected ? 0.26 : 0.16)))
                    context.stroke(Path(roundedRect: markerRect, cornerRadius: 5), with: .color(entry.color), lineWidth: isSelected ? 2 : 1)
                }

                var tick = Path()
                tick.move(to: CGPoint(x: x, y: y - tickHeight / 2))
                tick.addLine(to: CGPoint(x: x, y: y + tickHeight / 2))
                context.stroke(tick, with: .color(entry.color), lineWidth: entry.severity == .penalty ? 3 : 2)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard let entry = hitTestEntry(at: value.location, size: proxy.size) else { return }
                                onSelect(entry)
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hoveredPacketID = hitTestEntry(at: location, size: proxy.size)?.id
                        case .ended:
                            hoveredPacketID = nil
                        }
                    }
                    .hoverEffect(.highlight)
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(timeline.entries.count) packets · \(timeline.scoringGaps.count) scoring gaps · threshold \(formatMilliseconds(timeline.longGapThresholdMilliseconds))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            if let hoveredEntry {
                Text("\(formatSeconds(hoveredEntry.relativeSeconds)) · \(hoveredEntry.packet.role.rawValue)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(hoveredEntry.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Packet timeline")
        .accessibilityHint("Tap or hover a packet tick to inspect its raw packet details.")
    }

    private func drawEmptyTimeline(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
    }

    private func hitTestEntry(at location: CGPoint, size: CGSize) -> PacketTimelineEntry? {
        guard !timeline.entries.isEmpty else { return nil }

        let layout = TimelineCanvasLayout(size: size)
        let rect = layout.rect
        guard rect.insetBy(dx: -10, dy: -10).contains(location) else { return nil }

        let duration = max(timeline.durationSeconds, 0.001)
        let laneHeight = layout.laneHeight
        let horizontalTolerance = max(12, min(28, rect.width / CGFloat(max(timeline.entries.count, 1)) * 2.5))
        let verticalTolerance = max(12, laneHeight * 0.48)

        let candidates = timeline.entries.compactMap { entry -> (entry: PacketTimelineEntry, distance: CGFloat)? in
            let x = rect.minX + rect.width * CGFloat(entry.relativeSeconds / duration)
            let y = rect.minY + laneHeight * (CGFloat(entry.lane.index) + 0.5)
            let dx = abs(location.x - x)
            let dy = abs(location.y - y)
            guard dx <= horizontalTolerance, dy <= verticalTolerance else { return nil }

            let severityBias: CGFloat = entry.severity == .penalty ? -6 : 0
            return (entry, dx * dx + dy * dy + severityBias)
        }

        return candidates.min { $0.distance < $1.distance }?.entry
    }
}

private struct TimelineCanvasLayout {
    var rect: CGRect
    var laneHeight: CGFloat

    init(size: CGSize) {
        let inset: CGFloat = 10
        rect = CGRect(
            x: inset,
            y: inset,
            width: max(1, size.width - inset * 2),
            height: max(1, size.height - inset * 2)
        )
        laneHeight = rect.height / CGFloat(PacketLane.allCases.count)
    }
}

private struct PacketLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                legendItems
            }
            VStack(alignment: .leading, spacing: 6) {
                legendItems
            }
        }
        .font(.caption2)
    }

    @ViewBuilder
    private var legendItems: some View {
        LegendItem(color: .blue, title: "weight")
        LegendItem(color: .green, title: "battery")
        LegendItem(color: .purple, title: "control")
        LegendItem(color: .orange, title: "warning")
        LegendItem(color: .red, title: "penalty")
        LegendItem(color: .gray, title: "unknown")
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PacketChip: View {
    let entry: PacketTimelineEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Capsule()
                    .fill(entry.color)
                    .frame(width: 8, height: entry.severity == .penalty ? 28 : 20)
                Text(formatSeconds(entry.relativeSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isSelected ? entry.color.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? entry.color : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Packet at \(formatSeconds(entry.relativeSeconds)), \(entry.severity.label)")
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
    let entry: PacketTimelineEntry

    private var packet: RawScalePacket { entry.packet }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(packet.role.rawValue, systemImage: entry.severity.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.color)
                Spacer()
                Text(formatSeconds(entry.relativeSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !entry.evidence.isEmpty {
                ForEach(entry.evidence, id: \.self) { evidence in
                    Text(evidence)
                        .font(.caption)
                        .foregroundStyle(entry.severity == .penalty ? .red : .orange)
                }
            }

            if let interval = entry.intervalMilliseconds {
                MetricRow(title: "Interval before", value: formatMilliseconds(interval))
            }

            Text(packet.characteristicUUID)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(packet.bytesHex)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
        .padding(10)
        .background(entry.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    ScoreHero(metrics: metrics, profile: profile)
                    Text(resultNarrative(for: recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RecordingSummaryRows(recording: recording, metrics: metrics)
                }

                Section("Benchmark identity") {
                    MetricRow(title: "Profile", value: profile.name)
                    MetricRow(title: "Comparable badge", value: profile.isStandardBenchmark ? "ScaleBench Standard v1" : "Custom")
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
            copy.name = baseProfile.isStandardBenchmark
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
                    MetricRow(title: "Normalized total", value: draftWeightTotal > 0 ? "100%" : "Invalid")
                    if draftWeightTotal <= 0 {
                        Text("At least one weight must be above zero.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
                    .disabled(!canSave)
                }
            }
        }
    }

    private var draftWeightTotal: Double {
        draft.transportWeight + draft.stabilityWeight + draft.metadataWeight
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftWeightTotal > 0
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

private var helpToolbarPlacement: ToolbarItemPlacement {
#if os(macOS)
    .automatic
#else
    .topBarLeading
#endif
}

private var resetToolbarPlacement: ToolbarItemPlacement {
#if os(macOS)
    .automatic
#else
    .topBarTrailing
#endif
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
                Text(row.title)
                    .font(.headline)
                Spacer()
                Text(row.score.map { "\($0)/100" } ?? "—")
                    .monospacedDigit()
            }
            Text("\(row.protocolKind.displayName) · \(row.mode.displayName) · \(row.sampleCount) samples · \(formatRate(row.sampleRateHz)) · p95 \(formatMilliseconds(row.p95IntervalMilliseconds))")
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

private struct PacketTimeline: Equatable {
    var entries: [PacketTimelineEntry]
    var sampleIntervals: [SampleIntervalEntry]
    var scoringGaps: [ScoringGap]
    var longGapThresholdMilliseconds: Double

    var durationSeconds: Double {
        let rawEnd = entries.last?.relativeSeconds ?? 0
        let sampleEnd = sampleIntervals.last?.relativeSeconds ?? 0
        return max(0, rawEnd, sampleEnd)
    }

    var warningIntervalCount: Int {
        sampleIntervals.filter { $0.severity == .warning }.count
    }

    static func make(recording: ScaleRecording, metrics _: ScaleQualityMetrics) -> PacketTimeline {
        let packets = recording.rawPackets.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
        let firstReferenceTime = packets.first?.monotonicSeconds ?? recording.samples.first?.monotonicSeconds ?? 0
        let threshold = packetLongGapThresholdMilliseconds(recording: recording)
        let sampleIntervals = sampleIntervalEntries(
            samples: recording.samples,
            firstReferenceTime: firstReferenceTime,
            thresholdMilliseconds: threshold
        )
        let scoringGaps = sampleIntervals.compactMap { entry -> ScoringGap? in
            guard entry.severity == .penalty else { return nil }
            return ScoringGap(
                id: entry.index,
                startRelativeSeconds: entry.previousRelativeSeconds,
                endRelativeSeconds: entry.relativeSeconds,
                intervalMilliseconds: entry.intervalMilliseconds
            )
        }

        guard !packets.isEmpty else {
            return PacketTimeline(
                entries: [],
                sampleIntervals: sampleIntervals,
                scoringGaps: scoringGaps,
                longGapThresholdMilliseconds: threshold
            )
        }

        var entries: [PacketTimelineEntry] = []
        var previousPacket: RawScalePacket?
        for packet in packets {
            let interval = previousPacket.map { max(0, packet.monotonicSeconds - $0.monotonicSeconds) * 1_000 }
            let relative = packet.monotonicSeconds - firstReferenceTime
            let previousRelative = previousPacket.map { $0.monotonicSeconds - firstReferenceTime }
            let severity = packetSeverity(packet: packet, intervalMilliseconds: interval, longGapThresholdMilliseconds: threshold)
            let evidence = packetEvidence(packet: packet, intervalMilliseconds: interval, longGapThresholdMilliseconds: threshold)

            entries.append(
                PacketTimelineEntry(
                    id: packet.id,
                    packet: packet,
                    relativeSeconds: relative,
                    previousRelativeSeconds: previousRelative,
                    intervalMilliseconds: interval,
                    severity: severity,
                    evidence: evidence
                )
            )
            previousPacket = packet
        }

        return PacketTimeline(
            entries: entries,
            sampleIntervals: sampleIntervals,
            scoringGaps: scoringGaps,
            longGapThresholdMilliseconds: threshold
        )
    }
}

private struct SampleIntervalEntry: Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var previousRelativeSeconds: Double
    var relativeSeconds: Double
    var intervalMilliseconds: Double
    var severity: PacketSeverity

    var color: Color {
        switch severity {
        case .penalty:
            .red
        case .warning:
            .orange
        case .info, .normal:
            .blue.opacity(0.65)
        }
    }
}

private struct ScoringGap: Identifiable, Equatable {
    var id: Int
    var startRelativeSeconds: Double
    var endRelativeSeconds: Double
    var intervalMilliseconds: Double
}

private struct PacketTimelineEntry: Identifiable, Equatable {
    var id: UUID
    var packet: RawScalePacket
    var relativeSeconds: Double
    var previousRelativeSeconds: Double?
    var intervalMilliseconds: Double?
    var severity: PacketSeverity
    var evidence: [String]

    var hasLongGapBefore: Bool {
        guard intervalMilliseconds != nil else { return false }
        return severity == .penalty && evidence.contains { $0.localizedCaseInsensitiveContains("long gap") }
    }

    var lane: PacketLane {
        if severity == .penalty { return .penalty }
        switch packet.role {
        case .weight:
            return .weight
        case .battery:
            return .metadata
        case .capabilities, .commandAck:
            return .control
        case .unknown:
            return .unknown
        }
    }

    var color: Color {
        switch severity {
        case .penalty:
            .red
        case .warning:
            .orange
        case .info:
            switch packet.role {
            case .battery:
                .green
            case .capabilities, .commandAck:
                .purple
            case .unknown:
                .gray
            case .weight:
                .blue
            }
        case .normal:
            switch packet.role {
            case .weight:
                .blue
            case .battery:
                .green
            case .capabilities, .commandAck:
                .purple
            case .unknown:
                .gray
            }
        }
    }

    var intervalColor: Color {
        guard intervalMilliseconds != nil else { return Color.clear }
        switch severity {
        case .penalty:
            return Color.red
        case .warning:
            return Color.orange
        case .info:
            return Color.gray.opacity(0.55)
        case .normal:
            return Color.blue.opacity(0.55)
        }
    }
}

private enum PacketSeverity: Int, Equatable {
    case normal
    case info
    case warning
    case penalty

    var color: Color {
        switch self {
        case .normal:
            .blue
        case .info:
            .green
        case .warning:
            .orange
        case .penalty:
            .red
        }
    }

    var label: String {
        switch self {
        case .normal:
            "normal"
        case .info:
            "metadata or control"
        case .warning:
            "warning"
        case .penalty:
            "score penalty"
        }
    }

    var systemImage: String {
        switch self {
        case .normal:
            "checkmark.circle"
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .penalty:
            "xmark.octagon"
        }
    }
}

private enum PacketLane: CaseIterable {
    case weight
    case metadata
    case control
    case penalty
    case unknown

    var index: Int {
        switch self {
        case .weight:
            0
        case .metadata:
            1
        case .control:
            2
        case .penalty:
            3
        case .unknown:
            4
        }
    }
}

private func packetLongGapThresholdMilliseconds(recording: ScaleRecording) -> Double {
    let intervals = ScaleQualityAnalyzer.sampleIntervalsMilliseconds(recording.samples)
    let typicalInterval = percentile(intervals, 0.50)
    return ScaleQualityAnalyzer.longGapThresholdMilliseconds(
        forTypicalIntervalMilliseconds: typicalInterval,
        profile: recording.scoringProfile.normalized
    )
}

private func sampleIntervalEntries(
    samples inputSamples: [ScaleSample],
    firstReferenceTime: Double,
    thresholdMilliseconds: Double
) -> [SampleIntervalEntry] {
    let intervals = ScaleQualityAnalyzer.sampleIntervalsMilliseconds(inputSamples)
    guard intervals.count == inputSamples.count - 1 else { return [] }

    return intervals.enumerated().map { index, interval in
        let previous = inputSamples[index]
        let current = inputSamples[index + 1]
        let severity: PacketSeverity
        if interval >= thresholdMilliseconds {
            severity = .penalty
        } else if interval >= thresholdMilliseconds * 0.66 {
            severity = .warning
        } else {
            severity = .normal
        }
        return SampleIntervalEntry(
            index: index,
            previousRelativeSeconds: previous.monotonicSeconds - firstReferenceTime,
            relativeSeconds: current.monotonicSeconds - firstReferenceTime,
            intervalMilliseconds: interval,
            severity: severity
        )
    }
}

private func packetSeverity(
    packet: RawScalePacket,
    intervalMilliseconds: Double?,
    longGapThresholdMilliseconds: Double
) -> PacketSeverity {
    if packet.rejectionReason != nil {
        return .penalty
    }
    if let intervalMilliseconds, intervalMilliseconds >= longGapThresholdMilliseconds * 0.66 {
        return .warning
    }
    switch packet.role {
    case .unknown:
        return .warning
    case .battery, .capabilities, .commandAck:
        return .info
    case .weight:
        return .normal
    }
}

private func packetEvidence(
    packet: RawScalePacket,
    intervalMilliseconds: Double?,
    longGapThresholdMilliseconds: Double
) -> [String] {
    var evidence: [String] = []
    if let rejectionReason = packet.rejectionReason {
        evidence.append("Rejected by parser: \(rejectionReason.rawValue). This directly lowers transport quality.")
    }
    if let intervalMilliseconds, intervalMilliseconds >= longGapThresholdMilliseconds {
        evidence.append("Raw packet interval before this packet: \(formatMilliseconds(intervalMilliseconds)). Scoring uses parsed sample intervals; see the cadence chart for direct gap penalties.")
    } else if let intervalMilliseconds, intervalMilliseconds >= longGapThresholdMilliseconds * 0.66 {
        evidence.append("Near-threshold raw packet interval before this packet: \(formatMilliseconds(intervalMilliseconds)). Warning only.")
    }
    if packet.role == .unknown {
        evidence.append("Unknown packet role. Kept for diagnostics; may indicate unsupported protocol traffic.")
    }
    if packet.role == .battery {
        evidence.append("Battery/metadata packet. This can improve metadata coverage when parsed.")
    }
    if packet.role == .capabilities {
        evidence.append("Capability packet. Useful context for WMB+ features and parser behavior.")
    }
    if packet.role == .commandAck {
        evidence.append("Command acknowledgement packet. Useful context around tare/start/stop actions.")
    }
    if evidence.isEmpty {
        evidence.append("Normal parsed packet. No direct score penalty attached.")
    }
    return evidence
}

private func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * p))))
    return sorted[index]
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

private func formatSeconds(_ value: Double) -> String {
    String(format: "%.2fs", value)
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
