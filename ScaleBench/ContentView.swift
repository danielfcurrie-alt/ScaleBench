import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothScaleManager
    @State private var selectedMode: RecordingMode = .idleStability
    @State private var selectedScoringPreset: ScoringPreset = .standard
    @State private var exportURL: URL?

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

                    HStack {
                        Button(bluetooth.isRecording ? "Stop Recording" : "Start Recording") {
                            if bluetooth.isRecording {
                                bluetooth.stopRecording()
                            } else {
                                bluetooth.startRecording(mode: selectedMode, scoringProfile: selectedScoringPreset.profile)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bluetooth.connectedDevice == nil)

                        Button("Export JSON") {
                            exportURL = bluetooth.exportCurrentRecording()
                        }
                        .buttonStyle(.bordered)
                        .disabled(bluetooth.currentRecording.samples.isEmpty && bluetooth.currentRecording.rawPackets.isEmpty)
                    }

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
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
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BluetoothScaleManager.preview)
}
