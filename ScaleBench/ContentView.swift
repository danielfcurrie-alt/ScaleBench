import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothScaleManager
    @StateObject private var savedStore = SavedRecordingStore()
    @State private var selectedMode: RecordingMode = .idleStability
    @State private var selectedScoringPreset: ScoringPreset = .standard
    @State private var recordingNotes = ""
    @State private var exportURL: URL?
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
                            }
                        }
                    }
                }

                Section("Recording") {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("Scoring", selection: $selectedScoringPreset) {
                        ForEach(ScoringPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
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
                                bluetooth.stopRecording()
                            } else {
                                bluetooth.startRecording(mode: selectedMode, scoringProfile: selectedScoringPreset.profile)
                            }
                        },
                        export: {
                            exportURL = bluetooth.exportCurrentRecording(notes: recordingNotes)
                        }
                    )

                    Button {
                        let snapshot = bluetooth.finalizedCurrentRecording(notes: recordingNotes)
                        _ = savedStore.save(recording: snapshot, notes: recordingNotes)
                    } label: {
                        Label("Save Recording", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.isRecording || (bluetooth.currentRecording.samples.isEmpty && bluetooth.currentRecording.rawPackets.isEmpty))

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
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
                            SavedRecordingRow(saved: saved)
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
                    }
                }
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
            Text("\(saved.protocolKind.displayName) · \(saved.recording.samples.count) samples · \(formatRate(saved.scoreSnapshot.effectiveSampleRateHz))")
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

#Preview {
    ContentView()
        .environmentObject(BluetoothScaleManager.preview)
}
