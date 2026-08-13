import Charts
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothScaleManager
    @EnvironmentObject private var appCommands: AppCommandRouter
    @StateObject private var savedStore = SavedRecordingStore()
    @State private var selectedMode: RecordingMode = .shot
    @State private var recordingNotes = ""
    @State private var exportURL: URL?
    @State private var deviceUtilityReportURL: URL?
    @State private var activeSheet: ActiveSheet?
    @State private var isImportingRecording = false
    @State private var importStatusMessage: String?
    @State private var isRecordingsExpanded = true
    @State private var recordingLibraryMode: RecordingLibraryMode = .date
    @State private var recordingSearchText = ""
    @State private var commandErrorMessage: String?
    @State private var recordingResultSaveStatusMessage = ""
    @ScaledMetric(relativeTo: .body) private var notesMinHeight = 72

    private var filteredRecordings: [SavedScaleRecording] {
        let query = recordingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return savedStore.recordings }
        return savedStore.recordings.filter { saved in
            [
                saved.title,
                saved.notes,
                saved.protocolKind.displayName,
                saved.recording.mode.displayName,
                platformDisplayName(saved.recording.platform),
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScaleBenchBrandHeader(status: bluetooth.statusMessage)
                }
                .listRowBackground(Color.clear)

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
                        .scaleBenchProminentButtonStyle()
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

                    Label("ScaleBench Standard v1", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                        canRecord: bluetooth.isConnectionReady,
                        canExport: !bluetooth.currentRecording.samples.isEmpty || !bluetooth.currentRecording.rawPackets.isEmpty,
                        startOrStop: {
                            if bluetooth.isRecording {
                                stopRecordingAndShowResults()
                            } else {
                                startRecordingAndShowTimer()
                            }
                        },
                        export: {
                            bluetooth.applyScoringProfile(.standard)
                            exportURL = bluetooth.exportCurrentRecording(notes: recordingNotes)
                        }
                    )

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share JSON \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }

                    if let error = savedStore.lastErrorMessage {
                        Text("Save error: \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Live") {
                    let metrics = bluetooth.currentMetrics
                    MetricRow(title: "Weight", value: bluetooth.latestSample.map { String(format: "%.2f g", $0.weightGrams) } ?? "—")
                    MetricRow(title: "Flow", value: bluetooth.latestSample?.flowGramsPerSecond.map { String(format: "%.2f g/s", $0) } ?? "—")
                    MetricRow(title: "Battery", value: bluetooth.latestSample?.batteryPercent.map { "\($0)%" } ?? bluetooth.latestBatteryPercent.map { "\($0)%" } ?? "—")
                    MetricRow(title: "Protocol", value: bluetooth.activeProtocol.displayName)
                    MetricRow(title: "Packets", value: "\(bluetooth.currentRecording.rawPackets.count)")
                    MetricRow(title: "Samples", value: "\(bluetooth.currentRecording.samples.count)")
                    LiveDiagnosticsRows(recording: bluetooth.currentRecording, metrics: metrics)
                }

                Section("Scorecard") {
                    let metrics = bluetooth.currentMetrics
                    BenchmarkScoreRows(mode: bluetooth.currentRecording.mode, metrics: metrics)
                    MetricRow(title: "Effective rate", value: metrics.effectiveSampleRateHz.map { String(format: "%.1f Hz", $0) } ?? "—")
                    MetricRow(title: "Interval p95", value: metrics.packetIntervalP95Milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                    MetricRow(title: "Max gap", value: metrics.packetIntervalMaxMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                    MetricRow(title: "Long gaps", value: "\(metrics.longGapCount)")
                    MetricRow(title: "Missing seq", value: "\(metrics.missingSequenceCount)")
                    MetricRow(title: "Rejected", value: "\(metrics.rejectedPacketCount)")
                    MetricRow(title: "Idle noise", value: metrics.idleNoisePeakToPeakGrams.map { String(format: "%.2f g p-p", $0) } ?? "—")
                    MetricRow(title: "Drift", value: metrics.driftGramsPerMinute.map { String(format: "%.3f g/min", $0) } ?? "—")

                    Text("Delivery, Idle Stability, and Step Response are separate results and are never combined into a weighted overall score.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Recordings") {
                    DisclosureGroup(isExpanded: $isRecordingsExpanded) {
                        let visibleRecordings = filteredRecordings
                        RecordingLibraryControls(
                            count: savedStore.recordings.count,
                            mode: $recordingLibraryMode,
                            importJSON: {
                                startRecordingImport()
                            },
                            loadExamples: {
                                savedStore.loadExampleRecordings()
                            }
                        )

                        if savedStore.recordings.isEmpty {
                            EmptySavedRecordingsView(
                                loadExamples: {
                                    savedStore.loadExampleRecordings()
                                }
                            )
                        } else if visibleRecordings.isEmpty {
                            ContentUnavailableView(
                                "No matching recordings",
                                systemImage: "magnifyingglass",
                                description: Text("Try another scale, protocol, mode, platform, or note.")
                            )
                        } else {
                            RecordingLibrarySummary(mode: recordingLibraryMode, comparison: savedStore.comparison)

                            switch recordingLibraryMode {
                            case .date, .score:
                                let recordings = sortedSavedRecordings(visibleRecordings, mode: recordingLibraryMode)
                                ForEach(recordings) { saved in
                                    NavigationLink {
                                        SavedRecordingDetailView(saved: saved) {
                                            activeSheet = .scoreExplanation(saved.recording)
                                        }
                                    } label: {
                                        SavedRecordingRow(saved: saved)
                                    }
                                    .recordingDeleteAction {
                                        savedStore.delete(saved)
                                    }
                                }
                            case .protocolKind:
                                ForEach(recordingGroups(visibleRecordings, mode: .protocolKind)) { group in
                                    RecordingGroupHeader(title: group.title, count: group.recordings.count)
                                    ForEach(group.recordings) { saved in
                                        NavigationLink {
                                            SavedRecordingDetailView(saved: saved) {
                                                activeSheet = .scoreExplanation(saved.recording)
                                            }
                                        } label: {
                                            SavedRecordingRow(saved: saved)
                                        }
                                        .recordingDeleteAction {
                                            savedStore.delete(saved)
                                        }
                                    }
                                }
                            case .mode:
                                ForEach(recordingGroups(visibleRecordings, mode: .mode)) { group in
                                    RecordingGroupHeader(title: group.title, count: group.recordings.count)
                                    ForEach(group.recordings) { saved in
                                        NavigationLink {
                                            SavedRecordingDetailView(saved: saved) {
                                                activeSheet = .scoreExplanation(saved.recording)
                                            }
                                        } label: {
                                            SavedRecordingRow(saved: saved)
                                        }
                                        .recordingDeleteAction {
                                            savedStore.delete(saved)
                                        }
                                    }
                                }
                            }
                        }

                        if let importStatusMessage {
                            Text(importStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let libraryError = savedStore.lastErrorMessage {
                            Text("Library warning: \(libraryError)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } label: {
                        HStack {
                            Label("Saved shots", systemImage: "tray.full")
                            Spacer()
                            Text("\(savedStore.recordings.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

#if targetEnvironment(macCatalyst)
                Section("Device Utility") {
                    DeviceUtilitySummaryView(
                        connectedDevice: bluetooth.connectedDevice,
                        activeProtocol: bluetooth.activeProtocol,
                        advertisedServices: bluetooth.connectedAdvertisedServices
                    )

                    Button {
                        activeSheet = .deviceUtility
                    } label: {
                        Label("Open Device Utility", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                }
#endif
            }
            .scaleBenchListBackdrop()
            .navigationTitle("ScaleBench")
            .searchable(text: $recordingSearchText, prompt: "Search saved recordings")
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
                        resetCurrentRecording()
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
                    .interactiveDismissDisabled(bluetooth.isRecording)
                case .help:
                    ScaleBenchHelpView()
#if targetEnvironment(macCatalyst)
                case .deviceUtility:
                    DeviceUtilityView(
                        bluetooth: bluetooth,
                        reportURL: $deviceUtilityReportURL
                    )
#endif
                case let .recordingResults(recording):
                    RecordingResultsView(
                        recording: recording,
                        savedStatusMessage: recordingResultSaveStatusMessage,
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
                    ScoreExplanationView(recording: recording)
                case let .shareURL(url):
                    ShareSheet(items: [url])
                }
            }
            .onChange(of: appCommands.helpRequestID) { _, _ in
                activeSheet = .help
            }
            .modifier(AppCommandRequestModifier(
                commands: appCommands,
                startRecording: startRecordingAndShowTimer,
                stopRecording: stopRecordingAndShowResults,
                importRecording: startRecordingImport,
                exportJSON: exportCurrentJSONFromCommand,
                exportScorecard: exportCurrentScorecardFromCommand,
                reset: resetCurrentRecording
            ))
            .modifier(RecordingLifecycleModifier(
                bluetooth: bluetooth,
                recordingCompleted: showCompletedRecording,
                syncCommands: syncAppCommandState
            ))
            .fileImporter(
                isPresented: $isImportingRecording,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    importRecording(from: url)
                case let .failure(error):
                    importStatusMessage = error.localizedDescription
                }
            }
            .alert(
                "Could Not Complete Command",
                isPresented: Binding(
                    get: { commandErrorMessage != nil },
                    set: { if !$0 { commandErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    commandErrorMessage = nil
                }
            } message: {
                Text(commandErrorMessage ?? "Unknown error")
            }
        }
    }

    private func startRecordingAndShowTimer() {
        guard bluetooth.isConnectionReady else { return }
        bluetooth.applyScoringProfile(.standard)
        exportURL = nil
        bluetooth.startRecording(mode: selectedMode, scoringProfile: .standard)
        activeSheet = .recordingTimer
    }

    private func stopRecordingAndShowResults() {
        guard bluetooth.isRecording else {
            showCompletedRecording()
            return
        }
        bluetooth.stopRecording()
    }

    private func showCompletedRecording() {
        guard let snapshot = bluetooth.takeCompletedRecording() else { return }
        if snapshot.samples.isEmpty && snapshot.rawPackets.isEmpty {
            recordingResultSaveStatusMessage = "No saved shot was created because no packets were captured."
            activeSheet = .recordingResults(snapshot)
            return
        }
        if let saved = savedStore.save(recording: snapshot, notes: recordingNotes) {
            recordingResultSaveStatusMessage = "Saved automatically. Detailed charts and packet analysis are ready in Saved shots."
            activeSheet = .recordingResults(saved.recording)
        } else {
            let reason = savedStore.lastErrorMessage ?? "The recording file could not be written."
            recordingResultSaveStatusMessage = "Automatic save failed: \(reason) Use Export JSON below to keep this recording."
            activeSheet = .recordingResults(snapshot)
        }
    }

    private func startRecordingImport() {
        isImportingRecording = true
    }

    private func exportCurrentJSONFromCommand() {
        guard let url = bluetooth.exportCurrentRecording(notes: recordingNotes) else {
            commandErrorMessage = "The current recording could not be exported."
            return
        }
        activeSheet = .shareURL(url)
    }

    private func exportCurrentScorecardFromCommand() {
        do {
            let recording = bluetooth.finalizedCurrentRecording(notes: recordingNotes)
            activeSheet = .shareURL(try ScoreCardExporter.exportOfficial(recording))
        } catch {
            commandErrorMessage = error.localizedDescription
        }
    }

    private func resetCurrentRecording() {
        bluetooth.resetRecording()
        exportURL = nil
        activeSheet = nil
        syncAppCommandState()
    }

    private func syncAppCommandState() {
        let hasRecordingData = !bluetooth.currentRecording.samples.isEmpty
            || !bluetooth.currentRecording.rawPackets.isEmpty
        let canExport = !bluetooth.isRecording && hasRecordingData
        let canExportScorecard = canExport
            && bluetooth.currentMetrics.validity?.isValid == true
            && benchmarkScore(
                mode: bluetooth.currentRecording.mode,
                metrics: bluetooth.currentMetrics
            ) != nil
        appCommands.updateState(
            canStartRecording: bluetooth.isConnectionReady && !bluetooth.isRecording,
            isRecording: bluetooth.isRecording,
            canExport: canExport,
            canExportScorecard: canExportScorecard
        )
    }

    private func importRecording(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let saved = savedStore.importRecording(from: url) {
            importStatusMessage = "Imported \(saved.title)."
        } else {
            importStatusMessage = savedStore.lastErrorMessage ?? "Import failed."
        }
    }
}

private struct AppCommandRequestModifier: ViewModifier {
    @ObservedObject var commands: AppCommandRouter
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let importRecording: () -> Void
    let exportJSON: () -> Void
    let exportScorecard: () -> Void
    let reset: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: commands.startRecordingRequestID) { _, _ in
                if commands.canStartRecording { startRecording() }
            }
            .onChange(of: commands.stopRecordingRequestID) { _, _ in
                if commands.isRecording { stopRecording() }
            }
            .onChange(of: commands.importRecordingRequestID) { _, _ in
                importRecording()
            }
            .onChange(of: commands.exportJSONRequestID) { _, _ in
                if commands.canExport { exportJSON() }
            }
            .onChange(of: commands.exportScorecardRequestID) { _, _ in
                if commands.canExportScorecard { exportScorecard() }
            }
            .onChange(of: commands.resetRequestID) { _, _ in
                reset()
            }
    }
}

private struct RecordingLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var bluetooth: BluetoothScaleManager
    let recordingCompleted: () -> Void
    let syncCommands: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    bluetooth.noteAppBecameForeground()
                case .background:
                    bluetooth.noteAppEnteredBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .onChange(of: bluetooth.isRecording) { _, isRecording in
                RecordingWakeLock.setActive(isRecording)
                syncCommands()
            }
            .onChange(of: bluetooth.completedRecording?.id) { _, completedID in
                if completedID != nil {
                    recordingCompleted()
                }
            }
            .onChange(of: bluetooth.isConnectionReady) { _, _ in
                syncCommands()
            }
            .onChange(of: bluetooth.connectedDevice?.id) { _, _ in
                syncCommands()
            }
            .onChange(of: bluetooth.currentRecording.samples.count) { _, _ in
                syncCommands()
            }
            .onChange(of: bluetooth.currentRecording.rawPackets.count) { _, _ in
                syncCommands()
            }
            .onAppear {
                RecordingWakeLock.setActive(bluetooth.isRecording)
                recordingCompleted()
                syncCommands()
            }
            .onDisappear {
                RecordingWakeLock.setActive(false)
            }
            .sensoryFeedback(trigger: bluetooth.isRecording) { wasRecording, isRecording in
                guard wasRecording != isRecording else { return nil }
                return isRecording ? .start : .stop
            }
    }
}

private struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum ScaleBenchGlass {
    // Rollback switch for the Liquid Glass trial.
    static let isEnabled = true
}

private struct ScaleBenchBrandHeader: View {
    let status: String

    var body: some View {
        HStack(spacing: 14) {
            Image("ScorecardLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("ScaleBench")
                    .font(.title3.weight(.bold))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct ScaleBenchGlassBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.07, blue: 0.11).opacity(0.98),
                    Color(red: 0.00, green: 0.24, blue: 0.25).opacity(0.28),
                    Color(uiColor: .systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { proxy in
                Image("ScorecardLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(proxy.size.width * 0.72, 380))
                    .opacity(0.055)
                    .position(x: proxy.size.width * 0.74, y: proxy.size.height * 0.18)
                    .accessibilityHidden(true)
            }

            if ScaleBenchGlass.isEnabled {
                if #available(iOS 26.0, *), !ProcessInfo.processInfo.isMacCatalystApp {
                    Color.clear
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.08)), in: Rectangle())
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct ScaleBenchGlassSurfaceModifier: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if ScaleBenchGlass.isEnabled {
            if #available(iOS 26.0, *), !ProcessInfo.processInfo.isMacCatalystApp {
                let glass = interactive
                    ? Glass.regular.tint(tint).interactive()
                    : Glass.regular.tint(tint)
                content
                    .glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func scaleBenchListBackdrop() -> some View {
        if ScaleBenchGlass.isEnabled {
            self
                .scrollContentBackground(.hidden)
                .background(ScaleBenchGlassBackdrop())
        } else {
            self
        }
    }

    func scaleBenchGlassSurface(
        tint: Color? = nil,
        interactive: Bool = false,
        cornerRadius: CGFloat = 18
    ) -> some View {
        modifier(ScaleBenchGlassSurfaceModifier(tint: tint, interactive: interactive, cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func scaleBenchProminentButtonStyle() -> some View {
        if ScaleBenchGlass.isEnabled {
            if #available(iOS 26.0, *), !ProcessInfo.processInfo.isMacCatalystApp {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.borderedProminent)
            }
        } else {
            self.buttonStyle(.borderedProminent)
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

private enum ActiveSheet: Identifiable {
    case help
#if targetEnvironment(macCatalyst)
    case deviceUtility
#endif
    case recordingTimer
    case recordingResults(ScaleRecording)
    case scoreExplanation(ScaleRecording)
    case shareURL(URL)

    var id: String {
        switch self {
        case .help: "help"
#if targetEnvironment(macCatalyst)
        case .deviceUtility: "device-utility"
#endif
        case .recordingTimer: "recording-timer"
        case let .recordingResults(recording): "recording-results-\(recording.id.uuidString)"
        case let .scoreExplanation(recording): "score-explanation-\(recording.id.uuidString)"
        case let .shareURL(url): "share-\(url.absoluteString)"
        }
    }
}

private enum RecordingLibraryMode: String, CaseIterable, Identifiable {
    case date
    case score
    case protocolKind
    case mode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .date: "Date"
        case .score: "Score"
        case .protocolKind: "Protocol"
        case .mode: "Mode"
        }
    }
}

private struct RecordingLibraryGroup: Identifiable {
    let id: String
    let title: String
    let recordings: [SavedScaleRecording]
}

private struct RecordingLibraryControls: View {
    let count: Int
    @Binding var mode: RecordingLibraryMode
    let importJSON: () -> Void
    let loadExamples: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count) saved")
                        .font(.headline)
                    Text("Tap a recording to inspect score, charts, packets, and export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("View", selection: $mode) {
                ForEach(RecordingLibraryMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    libraryButtons
                }

                VStack(alignment: .leading, spacing: 10) {
                    libraryButtons
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var libraryButtons: some View {
        Button(action: importJSON) {
            Label("Import JSON", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.bordered)

        if count == 0 {
            Button(action: loadExamples) {
                Label("Examples", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: loadExamples) {
                Label("Add Examples", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct RecordingLibrarySummary: View {
    let mode: RecordingLibraryMode
    let comparison: ProtocolComparison

    var body: some View {
        switch mode {
        case .protocolKind:
            if comparison.rows.count < 2 {
                Text("Save or load two recordings to compare protocols side by side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let best = comparison.bestOverall {
                MetricRow(title: "Best full-detail result", value: "\(best.protocolKind.displayName) · \(best.score.map { "\($0)/100" } ?? "—")")
            }
        case .score:
            Text("Sorted by official comparable score first. Open a recording to see delivered packets, usable readings, and packet checks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mode:
            Text("Grouped by test mode so Shot / Pour, Idle, and Step Response recordings stay together.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .date:
            Text("Newest recordings first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecordingGroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

private func sortedSavedRecordings(
    _ recordings: [SavedScaleRecording],
    mode: RecordingLibraryMode
) -> [SavedScaleRecording] {
    switch mode {
    case .date:
        recordings.sorted { lhs, rhs in
            lhs.savedAt > rhs.savedAt
        }
    case .score:
        recordings.sorted { lhs, rhs in
            let lhsScore = benchmarkScore(mode: lhs.recording.mode, metrics: lhs.scoreSnapshot) ?? -1
            let rhsScore = benchmarkScore(mode: rhs.recording.mode, metrics: rhs.scoreSnapshot) ?? -1
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsUpperBound = lhs.scoreSnapshot.delivery?.purityIsUpperBound == true
            let rhsUpperBound = rhs.scoreSnapshot.delivery?.purityIsUpperBound == true
            if lhsUpperBound != rhsUpperBound { return !lhsUpperBound }
            return lhs.savedAt > rhs.savedAt
        }
    case .protocolKind:
        recordings.sorted { lhs, rhs in
            let lhsProtocol = lhs.protocolKind.displayName
            let rhsProtocol = rhs.protocolKind.displayName
            if lhsProtocol != rhsProtocol { return lhsProtocol < rhsProtocol }
            let lhsScore = benchmarkScore(mode: lhs.recording.mode, metrics: lhs.scoreSnapshot) ?? -1
            let rhsScore = benchmarkScore(mode: rhs.recording.mode, metrics: rhs.scoreSnapshot) ?? -1
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.savedAt > rhs.savedAt
        }
    case .mode:
        recordings.sorted { lhs, rhs in
            if lhs.recording.mode.displayName != rhs.recording.mode.displayName {
                return lhs.recording.mode.displayName < rhs.recording.mode.displayName
            }
            return lhs.savedAt > rhs.savedAt
        }
    }
}

private func recordingGroups(
    _ recordings: [SavedScaleRecording],
    mode: RecordingLibraryMode
) -> [RecordingLibraryGroup] {
    let sorted = sortedSavedRecordings(recordings, mode: mode)
    let pairs: [(id: String, title: String, saved: SavedScaleRecording)] = sorted.map { saved in
        switch mode {
        case .protocolKind:
            let title = saved.protocolKind.displayName
            return (title, title, saved)
        case .mode:
            let title = saved.recording.mode.displayName
            return (title, title, saved)
        case .date, .score:
            return ("all", "All recordings", saved)
        }
    }

    var groups: [RecordingLibraryGroup] = []
    for pair in pairs {
        if let last = groups.last, last.id == pair.id {
            groups[groups.count - 1] = RecordingLibraryGroup(
                id: last.id,
                title: last.title,
                recordings: last.recordings + [pair.saved]
            )
        } else {
            groups.append(RecordingLibraryGroup(id: pair.id, title: pair.title, recordings: [pair.saved]))
        }
    }
    return groups
}

private struct EmptySavedRecordingsView: View {
    let loadExamples: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("No saved recordings")
                    .font(.headline)
                Text("Saved and imported recordings keep the raw packets, score snapshot, scoring profile, and your notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    emptyStateButtons
                }

                VStack(spacing: 10) {
                    emptyStateButtons
                }
            }
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var emptyStateButtons: some View {
        Button(action: loadExamples) {
            Label("Load Examples", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct ScaleBenchHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let content = SharedHelpContent.bundled

    var body: some View {
        NavigationStack {
            List {
                ForEach(content.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            SharedHelpItemRow(item: item)
                        }
                    }
                }
            }
            .navigationTitle(content.title)
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

private struct SharedHelpItemRow: View {
    let item: SharedHelpItem

    var body: some View {
        switch item.type {
        case .step:
            HelpStepRow(
                number: Int(item.number ?? "") ?? 0,
                title: item.title ?? "",
                text: item.text ?? ""
            )
        case .row:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "")
                    .font(.headline)
                Text(item.value ?? item.text ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(item.text ?? "")
                    .foregroundStyle(.secondary)
            }
        case .text:
            Text(item.text ?? "")
                .foregroundStyle(.secondary)
        case .link:
            if let urlText = item.value ?? item.text,
               let url = URL(string: urlText) {
                Link(destination: url) {
                    Label(item.title ?? urlText, systemImage: "link")
                }
            } else {
                Text(item.title ?? item.text ?? item.value ?? "")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceUtilitySummaryView: View {
    let connectedDevice: DiscoveredScale?
    let activeProtocol: ScaleKind
    let advertisedServices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Device Utility", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let connectedDevice {
                MetricRow(title: "Connected", value: connectedDevice.name)
                MetricRow(title: "Protocol", value: activeProtocol.displayName)
                MetricRow(title: "DFU", value: deviceUtilityCapabilityLabel(services: advertisedServices))
            }
        }
        .padding(.vertical, 4)
    }

    private var summaryText: String {
        if connectedDevice == nil {
            return "Inspect BLE or cabled update and backup options."
        }
        return "Export a device report now. Firmware update support depends on the bootloader exposed by the scale."
    }
}

private struct DeviceUtilityView: View {
    @ObservedObject var bluetooth: BluetoothScaleManager
    @Binding var reportURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFirmwareURL: URL?
    @State private var firmwareMessage: String?
    @State private var isShowingFirmwarePicker = false
#if targetEnvironment(macCatalyst)
    @State private var cabledState = scanCabledDeviceUtility()
#endif

    private var advertisedServices: [String] { bluetooth.connectedAdvertisedServices }

    var body: some View {
        NavigationStack {
            List {
                Section("Connected device") {
                    if let device = bluetooth.connectedDevice {
                        MetricRow(title: "Name", value: device.name)
                        MetricRow(title: "Protocol", value: bluetooth.activeProtocol.displayName)
                        MetricRow(title: "Identifier", value: device.id.uuidString)
                        MetricRow(title: "RSSI", value: "\(device.rssi)")
                        MetricRow(title: "DFU capability", value: deviceUtilityCapabilityLabel(services: advertisedServices))
                        if !advertisedServices.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Advertised services")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(advertisedServices.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                            }
                        }
                    } else {
                        ContentUnavailableView("No scale connected", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section("Firmware update") {
                    Text("Android can use Nordic DFU libraries now. Apple OTA support needs a follow-up integration with NordicDFU or McuManager after we confirm the scale bootloader.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        isShowingFirmwarePicker = true
                    } label: {
                        Label("Choose Firmware Package", systemImage: "doc.badge.gearshape")
                    }

                    if let selectedFirmwareURL {
                        MetricRow(title: "Selected", value: selectedFirmwareURL.lastPathComponent)
                    }

                    if let firmwareMessage {
                        Text(firmwareMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

#if targetEnvironment(macCatalyst)
                CabledDeviceUtilitySection(
                    state: cabledState,
                    selectedFirmwareURL: selectedFirmwareURL,
                    refresh: {
                        cabledState = scanCabledDeviceUtility()
                    }
                )
#else
                Section("Cable") {
                    Text("Cabled firmware update is a Mac utility feature. iPhone and iPad stay on BLE because iOS does not provide a general serial/USB flashing path for arbitrary scales.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#endif

                Section("Backup") {
                    Text("Full firmware image backup is usually blocked by the bootloader or flash readout protection. On Mac, DU can suggest cable backup commands for tools it detects, but the exact command depends on the scale's firmware family.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
#if targetEnvironment(macCatalyst)
                        reportURL = makeDeviceUtilityReport(bluetooth: bluetooth, cabledState: cabledState)
#else
                        reportURL = makeDeviceUtilityReport(bluetooth: bluetooth)
#endif
                    } label: {
                        Label("Export Device Report", systemImage: "square.and.arrow.up")
                    }

                    if let reportURL {
                        ShareLink(item: reportURL) {
                            Label("Share \(reportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Device Utility")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isShowingFirmwarePicker,
                allowedContentTypes: [.zip, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    selectedFirmwareURL = urls.first
                    firmwareMessage = "Firmware update on Apple is not enabled yet. Package selection is saved for inspection only."
                case let .failure(error):
                    firmwareMessage = error.localizedDescription
                }
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
private struct CabledDeviceUtilitySection: View {
    let state: CabledDeviceUtilityState
    let selectedFirmwareURL: URL?
    let refresh: () -> Void
    @State private var selectedPortID: String?
    @State private var operationState = EspToolOperationState()
    @State private var flashOffset = "0x10000"

    private var selectedPort: SerialPortOption? {
        if let selectedPortID,
           let port = state.serialPorts.first(where: { $0.id == selectedPortID }) {
            return port
        }
        return state.serialPorts.first
    }

    private var runner: EspToolRunner? {
        espToolRunner(from: state.tools)
    }

    var body: some View {
        Section("Cable") {
            Text("Mac DU can back up and flash ESP32-family scales over USB serial with esptool. Back up before flashing; protected devices may refuse readback.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                refresh()
            } label: {
                Label("Refresh Cable Devices", systemImage: "arrow.clockwise")
            }

            if state.serialPorts.isEmpty {
                ContentUnavailableView("No serial devices", systemImage: "cable.connector", description: Text("Plug in a scale in USB serial or bootloader mode, then refresh."))
            } else {
                ForEach(state.serialPorts) { port in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(port.name)
                            .font(.headline)
                        Text(port.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            if state.serialPorts.count > 1 {
                Picker("Serial port", selection: Binding(
                    get: { selectedPort?.id },
                    set: { selectedPortID = $0 }
                )) {
                    ForEach(state.serialPorts) { port in
                        Text(port.name).tag(Optional(port.id))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Detected tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(state.tools) { tool in
                    MetricRow(title: tool.displayName, value: tool.path ?? "Not installed")
                }
            }

            if let selectedPort {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ESP32 backup and flash")
                        .font(.headline)
                    MetricRow(title: "Port", value: selectedPort.path)
                    MetricRow(title: "esptool", value: runner?.displayPath ?? "Not installed")

                    if let selectedFirmwareURL {
                        MetricRow(title: "Firmware", value: selectedFirmwareURL.lastPathComponent)
                    } else {
                        Text("Choose a firmware `.bin` package above before flashing. ScaleBench flashes app binaries at the offset below; full images need their exact partition offsets.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Flash offset", text: $flashOffset)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ViewThatFits(in: .horizontal) {
                        HStack {
                            espActionButtons(selectedPort: selectedPort)
                        }

                        VStack(alignment: .leading) {
                            espActionButtons(selectedPort: selectedPort)
                        }
                    }

                    if operationState.isRunning {
                        ProgressView(operationState.status)
                    } else {
                        MetricRow(title: "Status", value: operationState.status)
                    }

                    if let backupURL = operationState.backupURL {
                        ShareLink(item: backupURL) {
                            Label("Share \(backupURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }

                    if !operationState.output.isEmpty {
                        Text(operationState.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(10)
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Command templates")
                        .font(.headline)
                    ForEach(cabledCommandTemplates(port: selectedPort, firmwareURL: selectedFirmwareURL, tools: state.tools)) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(command.title, systemImage: command.systemImage)
                                .font(.subheadline.weight(.semibold))
                            Text(command.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(command.command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func espActionButtons(selectedPort: SerialPortOption) -> some View {
        Button {
            startEspBackup(selectedPort: selectedPort)
        } label: {
            Label("Backup ESP32", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .disabled(runner == nil || operationState.isRunning)

        Button {
            startEspFlash(selectedPort: selectedPort)
        } label: {
            Label("Flash ESP32", systemImage: "bolt")
        }
        .buttonStyle(.borderedProminent)
        .disabled(runner == nil || operationState.backupURL == nil || selectedFirmwareURL == nil || operationState.isRunning)
    }

    private func startEspBackup(selectedPort: SerialPortOption) {
        guard let runner else { return }
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBench-ESP32-backup-\(Int(Date().timeIntervalSince1970)).bin")
        operationState = EspToolOperationState(isRunning: true, status: "Backing up 4 MB from ESP32 flash...", output: "", backupURL: nil)
        Task {
            let result = await runEspTool(
                runner: runner,
                arguments: [
                    "--port", selectedPort.path,
                    "--baud", "460800",
                    "--before", "default-reset",
                    "--after", "hard-reset",
                    "read_flash", "0x00000", "0x400000", backupURL.path
                ],
                securityScopedURL: nil
            )
            operationState = EspToolOperationState(
                isRunning: false,
                status: result.succeeded ? "Backup complete" : "Backup failed",
                output: result.output,
                backupURL: result.succeeded ? backupURL : nil
            )
        }
    }

    private func startEspFlash(selectedPort: SerialPortOption) {
        guard let runner, let selectedFirmwareURL else { return }
        operationState = EspToolOperationState(isRunning: true, status: "Flashing ESP32...", output: "", backupURL: operationState.backupURL)
        Task {
            let result = await runEspTool(
                runner: runner,
                arguments: [
                    "--port", selectedPort.path,
                    "--baud", "460800",
                    "--before", "default-reset",
                    "--after", "hard-reset",
                    "--chip", "auto",
                    "write_flash",
                    "-z",
                    "--flash-mode", "dio",
                    "--flash-size", "detect",
                    flashOffset,
                    selectedFirmwareURL.path
                ],
                securityScopedURL: selectedFirmwareURL
            )
            operationState = EspToolOperationState(
                isRunning: false,
                status: result.succeeded ? "Flash complete" : "Flash failed",
                output: result.output,
                backupURL: operationState.backupURL
            )
        }
    }
}

private struct CabledDeviceUtilityState {
    var serialPorts: [SerialPortOption]
    var tools: [CommandLineToolOption]
}

private struct SerialPortOption: Identifiable {
    let path: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

private struct CommandLineToolOption: Identifiable {
    let name: String
    let displayName: String
    let path: String?

    var id: String { name }
    var isInstalled: Bool { path != nil }
}

private struct CabledCommandTemplate: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    let command: String
}

private struct EspToolOperationState {
    var isRunning = false
    var status = "Idle"
    var output = ""
    var backupURL: URL?
}

private struct EspToolRunner {
    let executable: String
    let argumentPrefix: [String]
    let displayPath: String
}

private struct EspToolResult {
    let succeeded: Bool
    let output: String
}

private func scanCabledDeviceUtility() -> CabledDeviceUtilityState {
    CabledDeviceUtilityState(
        serialPorts: scanSerialPorts(),
        tools: [
            detectCommandLineTool(name: "nrfutil", displayName: "Nordic nrfutil"),
            detectCommandLineTool(name: "nrfjprog", displayName: "Nordic nrfjprog"),
            detectCommandLineTool(name: "dfu-util", displayName: "dfu-util"),
            detectCommandLineTool(name: "esptool.py", displayName: "ESP esptool.py"),
            detectCommandLineTool(name: "esptool", displayName: "ESP esptool"),
            detectCommandLineTool(name: "python3", displayName: "Python 3")
        ]
    )
}

private func scanSerialPorts() -> [SerialPortOption] {
    let deviceDirectory = URL(fileURLWithPath: "/dev", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: deviceDirectory.path)) ?? []
    return names
        .filter { name in
            guard name.hasPrefix("cu.") || name.hasPrefix("tty.") else { return false }
            let lowercased = name.lowercased()
            return lowercased.contains("usb")
                || lowercased.contains("modem")
                || lowercased.contains("serial")
                || lowercased.contains("wch")
                || lowercased.contains("slab")
                || lowercased.contains("jlink")
        }
        .sorted()
        .map { SerialPortOption(path: deviceDirectory.appendingPathComponent($0).path) }
}

private func detectCommandLineTool(name: String, displayName: String) -> CommandLineToolOption {
    let candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
        "/bin/\(name)"
    ]
    let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    return CommandLineToolOption(name: name, displayName: displayName, path: path)
}

private func espToolRunner(from tools: [CommandLineToolOption]) -> EspToolRunner? {
    if let esptool = tools.first(where: { $0.name == "esptool" })?.path {
        return EspToolRunner(executable: esptool, argumentPrefix: [], displayPath: esptool)
    }
    if let esptool = tools.first(where: { $0.name == "esptool.py" })?.path {
        return EspToolRunner(executable: esptool, argumentPrefix: [], displayPath: esptool)
    }
    let knownPython = "/private/tmp/frankenbru-esptool-venv/bin/python"
    if FileManager.default.isExecutableFile(atPath: knownPython) {
        return EspToolRunner(executable: knownPython, argumentPrefix: ["-m", "esptool"], displayPath: "\(knownPython) -m esptool")
    }
    if let python = tools.first(where: { $0.name == "python3" })?.path {
        return EspToolRunner(executable: python, argumentPrefix: ["-m", "esptool"], displayPath: "\(python) -m esptool")
    }
    return nil
}

private func runEspTool(
    runner: EspToolRunner,
    arguments: [String],
    securityScopedURL: URL?
) async -> EspToolResult {
    await Task.detached(priority: .userInitiated) {
        let didAccess = securityScopedURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didAccess {
                securityScopedURL?.stopAccessingSecurityScopedResource()
            }
        }

        return runCommand(executable: runner.executable, arguments: runner.argumentPrefix + arguments)
    }.value
}

private func runCommand(executable: String, arguments: [String]) -> EspToolResult {
    var outputPipe: [Int32] = [0, 0]
    guard pipe(&outputPipe) == 0 else {
        return EspToolResult(succeeded: false, output: "Could not create output pipe.")
    }
    defer {
        if outputPipe[0] >= 0 {
            close(outputPipe[0])
        }
        if outputPipe[1] >= 0 {
            close(outputPipe[1])
        }
    }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer {
        posix_spawn_file_actions_destroy(&fileActions)
    }
    posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, outputPipe[0])

    let argvStrings = [executable] + arguments
    let argv = argvStrings.map { strdup($0) } + [nil]
    defer {
        argv.forEach { pointer in
            if let pointer {
                free(pointer)
            }
        }
    }

    var pid: pid_t = 0
    let spawnStatus = posix_spawn(&pid, executable, &fileActions, nil, argv, nil)
    close(outputPipe[1])
    outputPipe[1] = -1
    guard spawnStatus == 0 else {
        return EspToolResult(succeeded: false, output: String(cString: strerror(spawnStatus)))
    }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(outputPipe[0], &buffer, buffer.count)
        if count > 0 {
            output.append(buffer, count: count)
        } else {
            break
        }
    }

    var waitStatus: Int32 = 0
    waitpid(pid, &waitStatus, 0)
    let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return EspToolResult(succeeded: waitStatus == 0, output: text)
}

private func cabledCommandTemplates(
    port: SerialPortOption,
    firmwareURL: URL?,
    tools: [CommandLineToolOption]
) -> [CabledCommandTemplate] {
    let firmwarePath = firmwareURL?.path ?? "/path/to/firmware.zip"
    let nrfutil = tools.first(where: { $0.name == "nrfutil" })?.path ?? "nrfutil"
    let nrfjprog = tools.first(where: { $0.name == "nrfjprog" })?.path ?? "nrfjprog"
    let dfuUtil = tools.first(where: { $0.name == "dfu-util" })?.path ?? "dfu-util"
    let esptool = tools.first(where: { $0.name == "esptool.py" })?.path
        ?? tools.first(where: { $0.name == "esptool" })?.path
        ?? "esptool.py"

    return [
        CabledCommandTemplate(
            title: "Nordic serial DFU update",
            detail: "For nRF5 serial DFU bootloaders that accept a Nordic DFU ZIP over a serial port.",
            systemImage: "arrow.up.doc",
            command: "\(shellEscape(nrfutil)) dfu serial -pkg \(shellEscape(firmwarePath)) -p \(shellEscape(port.path)) -b 115200"
        ),
        CabledCommandTemplate(
            title: "Nordic debug backup",
            detail: "For development boards with an unlocked SWD/J-Link path. This will fail on protected production devices.",
            systemImage: "tray.and.arrow.down",
            command: "\(shellEscape(nrfjprog)) --readcode ScaleBench-backup.hex"
        ),
        CabledCommandTemplate(
            title: "DFU USB update",
            detail: "For devices that enumerate as a USB DFU target rather than a serial port.",
            systemImage: "cable.connector",
            command: "\(shellEscape(dfuUtil)) -D \(shellEscape(firmwarePath))"
        ),
        CabledCommandTemplate(
            title: "ESP app flash",
            detail: "For ESP32 app binaries. ScaleBench's button uses the same defaults and requires a backup first.",
            systemImage: "bolt",
            command: "\(shellEscape(esptool)) --port \(shellEscape(port.path)) --baud 460800 --before default-reset --after hard-reset --chip auto write_flash -z --flash-mode dio --flash-size detect 0x10000 \(shellEscape(firmwarePath))"
        ),
        CabledCommandTemplate(
            title: "ESP flash backup",
            detail: "For ESP-based scales in serial bootloader mode. Flash size/address may need to be adjusted per board.",
            systemImage: "externaldrive",
            command: "\(shellEscape(esptool)) --port \(shellEscape(port.path)) read_flash 0x00000 0x400000 ScaleBench-backup.bin"
        )
    ]
}

private func shellEscape(_ value: String) -> String {
    if value.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
#endif

private func deviceUtilityCapabilityLabel(services: [String]) -> String {
    let normalized = services.map { $0.uppercased() }
    if normalized.contains(where: { $0.contains("FE59") }) {
        return "Nordic DFU advertised"
    }
    if normalized.contains(where: { $0.contains("8D53DC1D") }) {
        return "SMP / McuManager advertised"
    }
    return "Not advertised"
}

#if targetEnvironment(macCatalyst)
private func makeDeviceUtilityReport(bluetooth: BluetoothScaleManager, cabledState: CabledDeviceUtilityState) -> URL? {
    makeDeviceUtilityReport(
        bluetooth: bluetooth,
        cabledUtility: [
            "serialPorts": cabledState.serialPorts.map { ["name": $0.name, "path": $0.path] },
            "tools": cabledState.tools.map {
                [
                    "name": $0.name,
                    "displayName": $0.displayName,
                    "path": jsonValue($0.path),
                    "isInstalled": $0.isInstalled
                ]
            },
            "note": "ScaleBench prepares cabled command templates on Mac; update and backup behavior depends on the target bootloader and installed tools."
        ]
    )
}
#endif

private func makeDeviceUtilityReport(bluetooth: BluetoothScaleManager) -> URL? {
    makeDeviceUtilityReport(bluetooth: bluetooth, cabledUtility: nil)
}

private func makeDeviceUtilityReport(bluetooth: BluetoothScaleManager, cabledUtility: [String: Any]?) -> URL? {
    let device = bluetooth.connectedDevice
    var utility: [String: Any] = [
        "dfuCapability": deviceUtilityCapabilityLabel(services: bluetooth.connectedAdvertisedServices),
        "firmwareBackupSupported": false,
        "backupNote": "Full firmware image backup requires firmware or bootloader readback support."
    ]
    if let cabledUtility {
        utility["cabled"] = cabledUtility
    }

    let report: [String: Any] = [
        "schemaVersion": 1,
        "kind": "ScaleBenchDeviceUtilityReport",
        "createdAt": ISO8601DateFormatter().string(from: Date()),
        "appName": "ScaleBench",
        "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        "platform": ScaleRecording.empty().platform,
        "device": [
            "connected": device != nil,
            "name": jsonValue(device?.name),
            "identifier": jsonValue(device?.id.uuidString),
            "protocol": bluetooth.activeProtocol.displayName,
            "rssi": jsonValue(device?.rssi),
            "advertisedServices": bluetooth.connectedAdvertisedServices
        ],
        "latestTelemetry": [
            "weightGrams": jsonValue(bluetooth.latestSample?.weightGrams),
            "batteryPercent": jsonValue(bluetooth.latestSample?.batteryPercent ?? bluetooth.latestBatteryPercent),
            "flowGramsPerSecond": jsonValue(bluetooth.latestSample?.flowGramsPerSecond)
        ],
        "utility": utility
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let safeName = (device?.name ?? "cabled-device")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleBench-DU-\(safeName)-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url, options: [.atomic])
        return url
    } catch {
        return nil
    }
}

private func jsonValue<T>(_ value: T?) -> Any {
    value ?? NSNull()
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
#if targetEnvironment(macCatalyst)
                recordingList(now: context.date, includesStopAction: true)
#else
                recordingList(now: context.date, includesStopAction: false)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        stopAction
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                    }
#endif
            }
            .navigationTitle("Recording")
        }
    }

    private func recordingList(now: Date, includesStopAction: Bool) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Recording", systemImage: "record.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text(formatDuration(recordingDuration(bluetooth.currentRecording, now: now)))
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
                let metrics = bluetooth.currentMetrics
                MetricRow(title: "Samples", value: "\(bluetooth.currentRecording.samples.count)")
                MetricRow(title: "Packets", value: "\(bluetooth.currentRecording.rawPackets.count)")
                MetricRow(title: "Weight", value: bluetooth.latestSample.map { String(format: "%.2f g", $0.weightGrams) } ?? "—")
                MetricRow(title: "Flow", value: bluetooth.latestSample?.flowGramsPerSecond.map { String(format: "%.2f g/s", $0) } ?? "—")
                MetricRow(title: "Battery", value: bluetooth.latestSample?.batteryPercent.map { "\($0)%" } ?? bluetooth.latestBatteryPercent.map { "\($0)%" } ?? "—")
                LiveDiagnosticsRows(recording: bluetooth.currentRecording, metrics: metrics)
            }

            if includesStopAction {
                Section {
                    stopAction
                }
            }
        }
        .scaleBenchListBackdrop()
    }

    private var stopAction: some View {
        Button(role: .destructive, action: stop) {
            Label("Stop and View Results", systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .scaleBenchProminentButtonStyle()
        .tint(.red)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct RecordingResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let recording: ScaleRecording
    let savedStatusMessage: String
    let exportJSON: (ScaleRecording) -> URL?
    let exportScorecard: (ScaleRecording) throws -> URL
    let explain: (ScaleRecording) -> Void

    @State private var jsonURL: URL?
    @State private var scoreCardShareItem: ShareSheetItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScoreHero(mode: recording.mode, metrics: recording.metrics)
                    Text(resultNarrative(for: recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Recording summary") {
                    RecordingSummaryRows(recording: recording, metrics: recording.metrics)
                }

                Section("How it was calculated") {
                    ScoreBreakdownView(recording: recording, metrics: recording.metrics)
                }

                Section {
                    Label(savedStatusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }

                Section("Actions") {
                    Button {
                        jsonURL = exportJSON(recording)
                        errorMessage = jsonURL == nil ? "JSON export failed." : nil
                    } label: {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        do {
                            scoreCardShareItem = ShareSheetItem(url: try exportScorecard(recording))
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
            }
            .scaleBenchListBackdrop()
            .navigationTitle("Results")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $scoreCardShareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }
}

private struct SavedRecordingDetailView: View {
    let saved: SavedScaleRecording
    let explain: () -> Void
    @State private var jsonURL: URL?
    @State private var scoreCardShareItem: ShareSheetItem?
    @State private var exportErrorMessage: String?

    private var recording: ScaleRecording { saved.recording }
    private var metrics: ScaleQualityMetrics { saved.scoreSnapshot }

    var body: some View {
        List {
            Section {
                ScoreHero(mode: recording.mode, metrics: metrics)
                Text(resultNarrative(for: recording))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording summary") {
                RecordingSummaryRows(recording: recording, metrics: metrics)
                MetricRow(title: "Saved", value: saved.savedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("How it was calculated") {
                ScoreBreakdownView(recording: recording, metrics: metrics)
            }

            Section("Packet visualizer") {
                RecordingVisualizerView(recording: recording, metrics: metrics)
            }

            Section("Score") {
                Button(action: explain) {
                    Label("Explain This Score", systemImage: "questionmark.circle")
                }
                BenchmarkScoreRows(mode: recording.mode, metrics: metrics)
            }

            Section("Export") {
                Button {
                    do {
                        jsonURL = try RecordingExporter.export(recording)
                        exportErrorMessage = nil
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }

                Button {
                    do {
                        scoreCardShareItem = ShareSheetItem(url: try ScoreCardExporter.exportOfficial(recording))
                        exportErrorMessage = nil
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export Official Scorecard", systemImage: "photo")
                }

                if let jsonURL {
                    ShareLink(item: jsonURL) {
                        Label("Share JSON \(jsonURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }

                if let exportErrorMessage {
                    Text(exportErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !saved.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Notes") {
                    Text(saved.notes)
                }
            }
        }
        .scaleBenchListBackdrop()
        .navigationTitle(saved.title)
        .sheet(item: $scoreCardShareItem) { item in
            ShareSheet(items: [item.url])
        }
    }
}

private struct ScoreHero: View {
    let mode: RecordingMode
    let metrics: ScaleQualityMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(benchmarkScoreTitle(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(benchmarkScoreDisplay(mode: mode, metrics: metrics))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Standard v1")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .scaleBenchGlassSurface(tint: .accentColor.opacity(0.16), cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingSummaryRows: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics

    var body: some View {
        MetricRow(title: "Mode", value: recording.mode.displayName)
        MetricRow(title: "Scoring", value: "ScaleBench Standard v1")
        MetricRow(title: "Model", value: metrics.scoringModelVersion ?? ScaleRecording.scoringModelVersion)
        MetricRow(title: "Duration", value: recordingDurationDisplay(recording: recording, metrics: metrics))
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

private struct BenchmarkScoreRows: View {
    let mode: RecordingMode
    let metrics: ScaleQualityMetrics

    var body: some View {
        MetricRow(title: "Benchmark", value: "ScaleBench Standard v1")
        MetricRow(title: benchmarkScoreTitle(mode), value: benchmarkScoreDisplay(mode: mode, metrics: metrics))

        if let validity = metrics.validity {
            MetricRow(title: "Validity", value: validity.isValid ? "Valid" : "Not valid")
        }

        if mode == .shot || mode == .transportStress {
            MetricRow(title: "Delivered", value: deliveredUpdatesDisplay(metrics))
            MetricRow(title: "Usable readings", value: usableReadingsDisplay(metrics))
        } else if mode == .idleStability {
            MetricRow(title: "Noise component", value: metrics.idleNoiseScore.map { "\($0)/100" } ?? "—")
            MetricRow(title: "Drift component", value: metrics.idleDriftScore.map { "\($0)/100" } ?? "—")
        } else if mode == .stepResponse, let step = metrics.stepResponse {
            MetricRow(title: "Step detected", value: step.stepDetected ? "Yes" : "No")
            MetricRow(title: "10–90% rise", value: step.riseTime10To90Seconds.map(formatSeconds) ?? "—")
            MetricRow(title: "Settling time", value: step.settlingTimeSeconds.map(formatSeconds) ?? "—")
            MetricRow(title: "Overshoot", value: step.overshootPercent.map { String(format: "%.1f%%", $0) } ?? "—")
        }
    }
}

private struct ScoreBreakdownView: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics

    var body: some View {
        if let validity = metrics.validity, !validity.isValid {
            Text(invalidScoreSummary(recording: recording, metrics: metrics))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(validity.reasons, id: \.self) { reason in
                Label(validityReasonLabel(reason), systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
        }

        switch recording.mode {
        case .shot, .transportStress:
            ScoreExplanationLines(lines: deliveryScoreExplanation(recording: recording, metrics: metrics))
            ScoreInfoButtons()
            Text("Delivery score uses delivered packets and usable readings. The formula is shown above so the score is auditable without opening the JSON.")
                .font(.caption)
                .foregroundStyle(.secondary)
            BenchmarkScoreRows(mode: recording.mode, metrics: metrics)
            PacketCheckStatusRows(metrics: metrics)
            Text("Telemetry available")
                .font(.headline)
            Text("Telemetry is extra protocol data ScaleBench records when the scale exposes it. It is useful for diagnosis, but it is not a separate score term.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TelemetryAvailabilityRows(recording: recording, metrics: metrics)
            FrameClassificationRows(metrics: metrics)

        case .idleStability:
            Text("Idle Stability combines detrended residual noise and drift with an equal-weight geometric mean. It is separate from Delivery.")
                .font(.caption)
                .foregroundStyle(.secondary)
            BenchmarkScoreRows(mode: recording.mode, metrics: metrics)
            MetricRow(title: "Residual std dev", value: metrics.idleNoiseStandardDeviationGrams.map { String(format: "%.3f g", $0) } ?? "—")
            MetricRow(title: "Residual p-p", value: metrics.idleNoisePeakToPeakGrams.map { String(format: "%.3f g", $0) } ?? "—")
            MetricRow(title: "Drift", value: metrics.driftGramsPerMinute.map { String(format: "%.3f g/min", $0) } ?? "—")
            MetricRow(title: "Resolution", value: metrics.idleResolutionGrams.map { String(format: "%.3f g", $0) } ?? "—")
            MetricRow(title: "Analysed frames", value: metrics.idleAnalysedSampleCount.map(String.init) ?? "—")

        case .stepResponse:
            Text("Step Response reports lag and settling metrics. Standard v1 does not turn them into a 0–100 score.")
                .font(.caption)
                .foregroundStyle(.secondary)
            BenchmarkScoreRows(mode: recording.mode, metrics: metrics)

        case .tareLatency:
            Text("Tare Latency is metrics-only in Standard v1; it does not produce a 0–100 score.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .batteryStability:
            Text("Battery Logging records telemetry only; it does not produce a 0–100 score.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScoreExplanationLines: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ScoreInfoButtons: View {
    @State private var selectedTopic: ScoreHelpTopic?

    var body: some View {
        HStack(spacing: 14) {
            Text("Help")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(ScoreHelpTopic.allCases) { topic in
                Button {
                    selectedTopic = topic
                } label: {
                    Image(systemName: "info.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(topic.title)
                .accessibilityHint(topic.message)
            }
            Spacer(minLength: 0)
        }
        .alert(item: $selectedTopic) { topic in
            Alert(
                title: Text(topic.title),
                message: Text(topic.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private enum ScoreHelpTopic: String, CaseIterable, Identifiable {
    case delivered
    case usable
    case checks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .delivered: "Delivered"
        case .usable: "Usable"
        case .checks: "Checks"
        }
    }

    var message: String {
        switch self {
        case .delivered:
            "Shot / Pour expects one usable weight update every 50 ms, or 20 per second. Missing updates reduce this part of the score."
        case .usable:
            "This counts how many received weight readings were usable for scoring. Unreadable, stale, implausible, or repeated readings reduce this part."
        case .checks:
            "Some scales expose more packet details than others. More checks make it easier for ScaleBench to prove what happened, but the main score still comes from delivered updates and usable readings."
        }
    }
}

private struct FrameClassificationRows: View {
    let metrics: ScaleQualityMetrics

    var body: some View {
        if let frames = metrics.frameClassification {
            MetricRow(title: "Usable frames", value: "\(frames.usable)")
            MetricRow(title: "Unreadable packets", value: "\(frames.parseFailure)")
            MetricRow(title: "Out of order", value: "\(frames.outOfOrder)")
            MetricRow(title: "Stale readings", value: "\(frames.stale)")
            MetricRow(title: "Implausible readings", value: "\(frames.implausible)")
            if frames.implausible > 0 {
                Text("Implausible readings are weight samples that failed a Shot / Pour physics check, such as an isolated spike compared with neighboring samples. They appear in Packet inspector -> Bad only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MetricRow(title: "Repeated readings", value: "\(frames.duplicate)")
        }
    }
}

private struct RecordingVisualizerView: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics
    private let analysis: ChartAnalysis
    @State private var selectedPacketID: UUID?
    @State private var packetInspectorFilter: PacketInspectorFilter = .all

    init(recording: ScaleRecording, metrics: ScaleQualityMetrics) {
        self.recording = recording
        self.metrics = metrics
        analysis = ChartAnalysis.make(recording: recording, metrics: metrics)
    }

    private var timeline: PacketTimeline {
        analysis.packetTimeline
    }

    private var selectedEntry: PacketTimelineEntry? {
        let entries = inspectorEntries
        if let selectedPacketID,
           let selected = entries.first(where: { $0.id == selectedPacketID }) {
            return selected
        }
        return entries.first(where: { $0.severity == .penalty })
            ?? entries.first(where: { $0.severity == .warning })
            ?? entries.first
    }

    private var inspectorEntries: [PacketTimelineEntry] {
        switch packetInspectorFilter {
        case .all:
            timeline.entries
        case .badOnly:
            timeline.entries.filter(\.isBadForInspector)
        }
    }

    private func drillIntoEvidence(_ target: PacketEvidenceTarget) {
        packetInspectorFilter = target == .all ? .all : .badOnly
        if let match = timeline.entries.first(where: { $0.matchesEvidenceTarget(target) }) {
            selectedPacketID = match.id
        } else if target == .longestOutage,
                  let match = timeline.entries.first(where: \.isBadForInspector) {
            selectedPacketID = match.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PacketEvidenceSummary(
                metrics: metrics,
                timeline: timeline,
                mode: recording.mode,
                onDrillDown: drillIntoEvidence
            )

            if !analysis.signalDiagnostics.isEmpty {
                SignalDiagnosticsSection(diagnostics: analysis.signalDiagnostics)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Weight stream", systemImage: "waveform.path.ecg")
                    .font(.headline)
                WeightStreamChart(recording: recording, timeline: timeline)
                    .frame(height: 180)
                Text("Parsed weight samples over the full recording. Red markers frame missing-update gaps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !analysis.problemWindows.isEmpty {
                ProblemAreasSection(analysis: analysis)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Packet cadence", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                PacketIntervalChart(timeline: timeline)
                    .frame(height: 170)
                Text("Dashed line is the gap threshold, not an observed gap. Only parsed sample bars crossing it count as long-gap deductions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Packet timeline", systemImage: "timeline.selection")
                    .font(.headline)
                PacketTimelineStats(timeline: timeline)
                PacketTimelineCanvas(
                    timeline: timeline,
                    selectedPacketID: selectedEntry?.id,
                    onSelect: { entry in
                        selectedPacketID = entry.id
                    }
                )
                    .frame(height: 116)
                PacketLegend(timeline: timeline)
                Text("Tap a tick to inspect the raw packet below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !timeline.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Packet inspector", systemImage: "scope")
                        .font(.headline)
                    HStack(spacing: 8) {
                        ForEach(PacketInspectorFilter.allCases) { filter in
                            Button(filter.label) {
                                packetInspectorFilter = filter
                            }
                            .buttonStyle(.bordered)
                            .tint(packetInspectorFilter == filter ? .accentColor : .secondary)
                        }
                    }
                    if inspectorEntries.isEmpty {
                        Text("No bad raw packets in this recording. Delivered packets, usable readings, and packet checks are explained in the Score section.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(inspectorEntries.prefix(120)) { entry in
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

                        if inspectorEntries.count > 120 {
                            Text("\(inspectorEntries.count - 120) more \(packetInspectorFilter.summaryName) are included in the JSON export.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if packetInspectorFilter == .badOnly {
                            Text("Showing \(inspectorEntries.count) of \(timeline.entries.count) packets.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let selectedEntry {
                            RawPacketRow(entry: selectedEntry)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct SignalDiagnosticsSection: View {
    let diagnostics: SignalDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Signal diagnostics", systemImage: "waveform.path.ecg.rectangle")
                .font(.headline)

            if let flow = diagnostics.flowValidation {
                MetricRow(
                    title: "Reported flow error",
                    value: String(format: "%.2f g/s median", flow.medianAbsoluteErrorGramsPerSecond)
                )
                if let lag = flow.lagMilliseconds {
                    MetricRow(title: "Reported flow timing", value: flowLagDescription(lag))
                }
                Text("Compared \(flow.sampleCount) reported flow values with weight change measured across a centered 1-second window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let clock = diagnostics.clockSkew {
                MetricRow(title: "Scale clock drift", value: clockSkewDescription(clock.skewPartsPerMillion))
                Text("Compared the scale's free-running clock with the phone or Mac clock across \(clock.sampleCount) updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let packet = diagnostics.packetCoalescing {
                MetricRow(
                    title: "Frames per occupied slot",
                    value: String(format: "%.2fx", packet.framesPerServedSlot)
                )
                Text("Average weight frames received in each occupied 50 ms scoring slot. Values above 1 mean extra updates arrived together or faster than 20 Hz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func flowLagDescription(_ milliseconds: Double) -> String {
        if abs(milliseconds) < 25 { return "Aligned with weight" }
        return String(format: "%.0f ms %@ weight", abs(milliseconds), milliseconds > 0 ? "behind" : "ahead of")
    }

    private func clockSkewDescription(_ ppm: Double) -> String {
        let secondsPerHour = ppm * 3_600 / 1_000_000
        return String(
            format: "%+.0f ppm (%+.2f s/hour)",
            ppm,
            secondsPerHour
        )
    }
}

private enum PacketInspectorFilter: String, CaseIterable, Identifiable {
    case all
    case badOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .badOnly: "Bad only"
        }
    }

    var summaryName: String {
        switch self {
        case .all: "packets"
        case .badOnly: "bad packets"
        }
    }
}

private enum PacketEvidenceTarget {
    case all
    case parseFailure
    case outOfOrder
    case stale
    case implausible
    case duplicate
    case longestOutage
}

private extension PacketTimelineEntry {
    var isBadForInspector: Bool {
        severity == .warning || severity == .penalty
    }

    func matchesEvidenceTarget(_ target: PacketEvidenceTarget) -> Bool {
        switch target {
        case .all:
            true
        case .parseFailure:
            evidence.contains { $0.localizedCaseInsensitiveContains("unreadable") }
        case .outOfOrder:
            evidence.contains { $0.localizedCaseInsensitiveContains("out of order") }
        case .stale:
            evidence.contains { $0.localizedCaseInsensitiveContains("stale") }
        case .implausible:
            evidence.contains { $0.localizedCaseInsensitiveContains("implausible") }
        case .duplicate:
            evidence.contains { $0.localizedCaseInsensitiveContains("repeated") }
        case .longestOutage:
            hasLongGapBefore
        }
    }
}

private struct PacketEvidenceSummary: View {
    let metrics: ScaleQualityMetrics
    let timeline: PacketTimeline
    let mode: RecordingMode
    let onDrillDown: (PacketEvidenceTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Score evidence", systemImage: "exclamationmark.magnifyingglass")
                .font(.headline)

            Text(scoreEvidenceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                EvidencePill(title: "Parse failed", value: "\(metrics.frameClassification?.parseFailure ?? 0)", severity: classificationSeverity(metrics.frameClassification?.parseFailure), action: drillAction(.parseFailure, count: metrics.frameClassification?.parseFailure))
                EvidencePill(title: "Out of order", value: "\(metrics.frameClassification?.outOfOrder ?? 0)", severity: classificationSeverity(metrics.frameClassification?.outOfOrder), action: drillAction(.outOfOrder, count: metrics.frameClassification?.outOfOrder))
                EvidencePill(title: "Stale", value: "\(metrics.frameClassification?.stale ?? 0)", severity: classificationSeverity(metrics.frameClassification?.stale), action: drillAction(.stale, count: metrics.frameClassification?.stale))
                EvidencePill(title: "Implausible", value: "\(metrics.frameClassification?.implausible ?? 0)", severity: classificationSeverity(metrics.frameClassification?.implausible), action: drillAction(.implausible, count: metrics.frameClassification?.implausible))
                EvidencePill(title: "Duplicates", value: "\(metrics.frameClassification?.duplicate ?? 0)", severity: classificationSeverity(metrics.frameClassification?.duplicate), action: drillAction(.duplicate, count: metrics.frameClassification?.duplicate))
                EvidencePill(
                    title: "Longest outage",
                    value: formatMilliseconds(metrics.longestUnservedRunMilliseconds),
                    severity: timeline.scoringGaps.isEmpty ? .normal : .warning,
                    action: timeline.scoringGaps.isEmpty ? nil : { onDrillDown(.longestOutage) }
                )
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var scoreEvidenceSummary: String {
        if let validity = metrics.validity, !validity.isValid {
            return "This recording is not valid for an official score. Diagnostics and frame classifications remain available."
        }
        if mode == .shot || mode == .transportStress,
           metrics.delivery != nil {
            let delivered = deliveredUpdatesDisplay(metrics)
            let usable = usableReadingsDisplay(metrics)
            return "Delivery multiplies delivered packets (\(delivered)) by usable readings (\(usable)). Tap a chip to inspect the packets behind it."
        }
        if mode == .idleStability {
            return "Idle Stability uses detrended residual noise and drift; packet classifications remain diagnostic evidence."
        }
        return "This mode reports diagnostics without a 0–100 score."
    }

    private func classificationSeverity(_ count: Int?) -> PacketSeverity {
        (count ?? 0) > 0 ? .penalty : .normal
    }

    private func drillAction(_ target: PacketEvidenceTarget, count: Int?) -> (() -> Void)? {
        guard (count ?? 0) > 0 else { return nil }
        return { onDrillDown(target) }
    }
}

private struct ProblemAreasSection: View {
    let analysis: ChartAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Problem areas", systemImage: "scope")
                .font(.headline)
            Text("Zoomed windows around the first scoring gaps or packet penalties.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(analysis.problemWindows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    MetricRow(
                        title: window.title,
                        value: "\(formatSeconds(window.startSeconds))-\(formatSeconds(window.endSeconds))"
                    )
                    ProblemAreaWeightChart(points: analysis.weightPoints, window: window)
                        .frame(height: 150)
                }
                .padding(10)
                .background(window.severity.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

private struct ProblemAreaWeightChart: View {
    let points: [ChartPoint]
    let window: ChartProblemWindow

    private var visiblePoints: [ChartPoint] {
        let visible = points.filter { $0.seconds >= window.startSeconds && $0.seconds <= window.endSeconds }
        if visible.count >= 2 { return visible }
        let before = points.last { $0.seconds < window.startSeconds }
        let after = points.first { $0.seconds > window.endSeconds }
        let fallback = [before, after].compactMap(\.self)
        return fallback.count >= 2 ? fallback : Array(points.prefix(2))
    }

    var body: some View {
        if visiblePoints.count >= 2 {
            Chart {
                ForEach(visiblePoints) { point in
                    LineMark(
                        x: .value("Seconds", point.seconds),
                        y: .value("Weight", point.value)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(.blue)
                }
                RuleMark(x: .value("Start", window.startSeconds))
                    .foregroundStyle(window.severity.color.opacity(0.35))
                RuleMark(x: .value("End", window.endSeconds))
                    .foregroundStyle(window.severity.color.opacity(0.35))
            }
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("grams")
        } else {
            EmptyVisualizerChart(message: "No zoomable weight stream.")
        }
    }
}

private struct EvidencePill: View {
    let title: String
    let value: String
    let severity: PacketSeverity
    let action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
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
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(severity.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel("\(title), \(value). Show matching packets.")
    }
}

private struct WeightStreamChart: View {
    let recording: ScaleRecording
    let timeline: PacketTimeline
    @State private var selectedSeconds: Double?

    private var samples: [ScaleSample] {
        recording.samples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
    }

    private var referenceTime: Double? {
        recording.recordingStartMonotonicSeconds ?? samples.first?.monotonicSeconds
    }

    private var selectedSample: ScaleSample? {
        guard let selectedSeconds, let referenceTime else { return nil }
        return samples.min { lhs, rhs in
            abs((lhs.monotonicSeconds - referenceTime) - selectedSeconds)
                < abs((rhs.monotonicSeconds - referenceTime) - selectedSeconds)
        }
    }

    var body: some View {
        if samples.count >= 2, let referenceTime {
            let chart = Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("Seconds", sample.monotonicSeconds - referenceTime),
                        y: .value("Weight", sample.weightGrams)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)

                    if sample.diagnosticFlags?.recentBump == true {
                        PointMark(
                            x: .value("Seconds", sample.monotonicSeconds - referenceTime),
                            y: .value("Weight", sample.weightGrams)
                        )
                        .foregroundStyle(.yellow)
                        .symbolSize(45)
                    }
                }

                ForEach(timeline.scoringGaps) { gap in
                    RuleMark(x: .value("Gap start", gap.startRelativeSeconds))
                        .foregroundStyle(.red.opacity(0.55))
                    RuleMark(x: .value("Gap end", gap.endRelativeSeconds))
                        .foregroundStyle(.red.opacity(0.55))
                }

                if let selectedSample {
                    let seconds = selectedSample.monotonicSeconds - referenceTime
                    RuleMark(x: .value("Selected time", seconds))
                        .foregroundStyle(.secondary.opacity(0.6))
                    PointMark(
                        x: .value("Selected time", seconds),
                        y: .value("Selected weight", selectedSample.weightGrams)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(55)
                    .annotation(position: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatSeconds(seconds))
                            Text(String(format: "%.2f g", selectedSample.weightGrams))
                        }
                        .font(.caption2.monospacedDigit())
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .chartXScale(domain: 0...max(timeline.durationSeconds, 0.001))
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("grams")
            .chartXSelection(value: $selectedSeconds)

            if recording.mode == .transportStress, timeline.durationSeconds > 30 {
                chart
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 30)
            } else {
                chart
            }
        } else {
            EmptyVisualizerChart(message: "No parsed weight stream.")
        }
    }
}

private struct PacketIntervalChart: View {
    let timeline: PacketTimeline

    var body: some View {
        let intervalEntries = timeline.sampleIntervals
        let hasLongGaps = !timeline.scoringGaps.isEmpty
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
                    .foregroundStyle(hasLongGaps ? .red.opacity(0.70) : .secondary.opacity(0.55))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(hasLongGaps ? "long-gap threshold" : "gap threshold")
                            .font(.caption2)
                            .foregroundStyle(hasLongGaps ? .red : .secondary)
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

private struct PacketTimelineStats: View {
    let timeline: PacketTimeline

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statChips
            }

            VStack(alignment: .leading, spacing: 6) {
                statChips
            }
        }
        .font(.caption2)
    }

    @ViewBuilder
    private var statChips: some View {
        TimelineStatChip(title: "Packets", value: "\(timeline.entries.count)")
        TimelineStatChip(title: "Scoring gaps", value: "\(timeline.scoringGaps.count)")
        TimelineStatChip(title: "Gap threshold", value: formatMilliseconds(timeline.longGapThresholdMilliseconds))
    }
}

private struct TimelineStatChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
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
                        SpatialTapGesture()
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
    let timeline: PacketTimeline

    var body: some View {
        Text(summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        let warningCount = timeline.entries.filter { $0.severity == .warning }.count
        let penaltyCount = timeline.entries.filter { $0.severity == .penalty }.count
        let metadataCount = timeline.entries.filter { $0.packet.role != .weight }.count
        var parts = ["Blue ticks are weight packets."]
        if metadataCount > 0 {
            parts.append("Other colors are metadata or unknown packets.")
        }
        if warningCount > 0 || penaltyCount > 0 {
            parts.append("Orange/red ticks need attention.")
        }
        if !timeline.scoringGaps.isEmpty {
            parts.append("Red bands are scoring gaps.")
        }
        return parts.joined(separator: " ")
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
    private var fields: [PacketFieldAnnotation] { PacketFieldDecoder.annotations(for: packet) }

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
            Text(annotatedHex)
                .font(.caption2.monospaced())
                .textSelection(.enabled)

            if !fields.isEmpty {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(fields) { field in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(field.semantic.color)
                                .frame(width: 7, height: 7)
                            Text(field.label)
                                .font(.caption2.weight(.semibold))
                            Text(field.decodedValue)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(entry.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var annotatedHex: AttributedString {
        guard let bytes = PacketFieldDecoder.bytes(fromHex: packet.bytesHex) else {
            return AttributedString(packet.bytesHex)
        }
        var result = AttributedString()
        for (index, byte) in bytes.enumerated() {
            var component = AttributedString(String(format: "%02X", byte))
            component.foregroundColor = fields.first(where: {
                $0.startByte <= index && index < $0.endByteExclusive
            })?.semantic.color ?? .gray
            result.append(component)
            if index < bytes.count - 1 {
                result.append(AttributedString((index + 1).isMultiple(of: 10) ? "\n" : " "))
            }
        }
        return result
    }
}

private extension PacketFieldSemantic {
    var color: Color {
        switch self {
        case .header: .blue
        case .timestamp: .cyan
        case .weight: .green
        case .flow: .mint
        case .battery: .yellow
        case .sequence: .purple
        case .status: .orange
        case .quality: .indigo
        case .sampleRate: .teal
        case .checksum: .red
        case .unit: .pink
        case .payload: .gray
        }
    }
}

private struct ScoreExplanationView: View {
    @Environment(\.dismiss) private var dismiss
    let recording: ScaleRecording

    private var metrics: ScaleQualityMetrics { recording.metrics }

    var body: some View {
        NavigationStack {
            List {
                Section("This recording") {
                    ScoreHero(mode: recording.mode, metrics: metrics)
                    Text(resultNarrative(for: recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RecordingSummaryRows(recording: recording, metrics: metrics)
                }

                Section("Standard v1") {
                    ScoreBreakdownView(recording: recording, metrics: metrics)
                }

                if let verification = metrics.protocolVerification,
                   recording.mode == .shot || recording.mode == .transportStress {
                    Section("Packet checks") {
                        PacketCheckStatusRows(verification: verification)
                        Text(packetChecksExplanation(verification))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Diagnostics") {
                    MetricRow(title: "Relevant frames", value: metrics.relevantWeightFrameCount.map(String.init) ?? "—")
                    MetricRow(title: "Excluded frames", value: metrics.excludedFrameCount.map(String.init) ?? "—")
                    MetricRow(title: "Usable rate", value: formatRate(metrics.usableRateHz))
                    MetricRow(title: "Frame rate", value: formatRate(metrics.frameRateHz))
                    MetricRow(title: "p50 interval", value: formatMilliseconds(metrics.packetIntervalP50Milliseconds))
                    MetricRow(title: "p95 interval", value: formatMilliseconds(metrics.packetIntervalP95Milliseconds))
                    MetricRow(title: "Longest outage", value: formatMilliseconds(metrics.longestUnservedRunMilliseconds))
                    MetricRow(title: "Disconnects", value: metrics.disconnectCount.map(String.init) ?? "0")
                    MetricRow(title: "Resolution estimate", value: metrics.estimatedResolutionGrams.map { String(format: "%.3f g", $0) } ?? "—")
                }
            }
            .navigationTitle("Explain Result")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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

private struct LiveDiagnosticsRows: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics

    var body: some View {
        MetricRow(title: "Effective rate", value: formatRate(metrics.effectiveSampleRateHz))
        MetricRow(title: "Resolution", value: resolutionDisplay(metrics))
        MetricRow(title: "Bad packets", value: "\(badPacketCount(metrics))")
        MetricRow(title: "Long gaps", value: "\(metrics.longGapCount)")
    }
}

private struct TelemetryAvailabilityRows: View {
    let recording: ScaleRecording
    let metrics: ScaleQualityMetrics

    var body: some View {
        ForEach(telemetryStatuses(recording: recording, metrics: metrics), id: \.name) { status in
            LabeledContent {
                Label(status.isAvailable ? "Available" : "Not seen",
                      systemImage: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(status.isAvailable ? .green : .secondary)
            } label: {
                Text(status.name)
            }
        }
    }
}

private struct PacketCheckStatusRows: View {
    let verification: ProtocolVerificationMetrics?

    init(metrics: ScaleQualityMetrics) {
        verification = metrics.protocolVerification
    }

    init(verification: ProtocolVerificationMetrics) {
        self.verification = verification
    }

    var body: some View {
        if let verification {
            ForEach(packetCheckStatuses(verification), id: \.name) { status in
                LabeledContent {
                    Label(status.isAvailable ? "Available" : "Not available",
                          systemImage: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(status.isAvailable ? .green : .secondary)
                } label: {
                    Text(status.name)
                }
            }
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
            Text("\(row.protocolKind.displayName) · \(row.mode.displayName) · \(platformDisplayName(row.platform))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(row.sampleCount) samples · \(formatRate(row.sampleRateHz)) · p95 \(formatMilliseconds(row.p95IntervalMilliseconds)) · max \(formatMilliseconds(row.maxGapMilliseconds))")
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
                Text(benchmarkScoreDisplay(mode: saved.recording.mode, metrics: saved.scoreSnapshot))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("\(saved.protocolKind.displayName) · \(platformDisplayName(saved.recording.platform)) · \(recordingDurationDisplay(recording: saved.recording, metrics: saved.scoreSnapshot))")
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

private extension View {
    func recordingDeleteAction(_ delete: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive, action: delete) {
                Label("Delete Recording", systemImage: "trash")
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
            .scaleBenchProminentButtonStyle()
            .disabled(!canRecord && !isRecording)

        Button("Export JSON", action: export)
            .buttonStyle(.bordered)
            .disabled(!canExport)
    }
}

private extension SampleIntervalEntry {
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

private extension PacketTimelineEntry {
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

private extension PacketSeverity {
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

private func formatScorePercent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

private func formatSeconds(_ value: Double) -> String {
    String(format: "%.2fs", value)
}

private func recordingDuration(_ recording: ScaleRecording, now: Date = Date()) -> TimeInterval {
    let end = recording.endedAt ?? now
    return max(0, end.timeIntervalSince(recording.startedAt))
}

private func recordingDurationDisplay(recording: ScaleRecording, metrics: ScaleQualityMetrics) -> String {
    let hasData = !recording.samples.isEmpty || !recording.rawPackets.isEmpty || (metrics.relevantWeightFrameCount ?? 0) > 0
    let missingBoundaries = metrics.validity?.reasons.contains("recordingBoundariesMissing") == true

    if let span = metrics.recordingSpanSeconds, span > 0 {
        return formatDuration(span)
    }
    if missingBoundaries || !hasData {
        return "—"
    }
    return formatDuration(recordingDuration(recording))
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

private func benchmarkScoreTitle(_ mode: RecordingMode) -> String {
    switch mode {
    case .shot, .transportStress: "Delivery score"
    case .idleStability: "Idle Stability score"
    case .stepResponse: "Step Response"
    case .tareLatency: "Tare Latency"
    case .batteryStability: "Battery Logging"
    }
}

private func platformDisplayName(_ platform: String) -> String {
    switch platform {
    case "ios": "iOS / iPadOS"
    case "macos-catalyst": "macOS Catalyst"
    case "android": "Android"
    default: "Unknown platform"
    }
}

private func benchmarkScore(mode: RecordingMode, metrics: ScaleQualityMetrics) -> Int? {
    switch mode {
    case .shot, .transportStress: metrics.delivery?.deliveryScore
    case .idleStability: metrics.stabilityScore
    case .stepResponse, .tareLatency, .batteryStability: nil
    }
}

private func benchmarkScoreDisplay(mode: RecordingMode, metrics: ScaleQualityMetrics) -> String {
    guard let score = benchmarkScore(mode: mode, metrics: metrics) else {
        return mode == .stepResponse || mode == .tareLatency || mode == .batteryStability ? "Metrics only" : "—"
    }
    return "\(score)/100"
}

private func deliveredUpdatesDisplay(_ metrics: ScaleQualityMetrics) -> String {
    if let served = metrics.servedSlots,
       let total = metrics.slotCount,
       total > 0,
       let coverage = metrics.delivery?.coverage {
        return "\(served)/\(total) (\(formatScorePercent(coverage)))"
    }
    return metrics.delivery?.coverage.map(formatScorePercent) ?? "—"
}

private func usableReadingsDisplay(_ metrics: ScaleQualityMetrics) -> String {
    if let usable = metrics.usableSampleCount,
       let total = metrics.relevantWeightFrameCount,
       total > 0,
       let purity = metrics.delivery?.purity {
        return "\(usable)/\(total) (\(formatScorePercent(purity)))"
    }
    return metrics.delivery?.purity.map(formatScorePercent) ?? "—"
}

private func deliveryScoreExplanation(recording: ScaleRecording, metrics: ScaleQualityMetrics) -> [String] {
    guard let delivery = metrics.delivery,
          let score = delivery.deliveryScore,
          let coverage = delivery.coverage,
          let purity = delivery.purity else {
        return ["Delivery score needs a valid recording plus enough packet evidence to compute coverage and purity."]
    }

    let coverageScore = 100 * coverage
    let finalScore = coverageScore * purity
    let coverageCost = max(0, 100 - coverageScore)
    let frameCost = max(0, coverageScore - finalScore)
    var lines: [String] = []

    if let servedSlots = metrics.servedSlots,
       let slotCount = metrics.slotCount,
       slotCount > 0 {
        lines.append("Delivered packets: \(servedSlots)/\(slotCount) expected (\(formatScorePercent(coverage))).")
    } else if let rate = metrics.effectiveSampleRateHz {
        lines.append("Delivered packets: \(formatScorePercent(coverage)). Effective rate was \(String(format: "%.1f Hz", rate)); Shot / Pour expects 20 per second.")
    }

    if let usable = metrics.usableSampleCount,
       let total = metrics.relevantWeightFrameCount,
       total > 0 {
        lines.append("Usable readings: \(usable)/\(total) (\(formatScorePercent(purity))).")
    } else {
        lines.append("Usable readings: \(formatScorePercent(purity)).")
    }

    lines.append("Score: round(100 × \(formatMultiplier(coverage)) × \(formatMultiplier(purity))) = \(score)/100.")
    lines.append("Biggest deduction: delivered packets cost \(formatPointValue(coverageCost)); unusable or repeated readings cost \(formatPointValue(frameCost)).")

    var drivers: [String] = []
    if metrics.longGapCount > 0 {
        drivers.append("\(metrics.longGapCount) long \(metrics.longGapCount == 1 ? "gap" : "gaps")")
    }
    if let longest = metrics.longestUnservedRunMilliseconds, longest >= 100 {
        drivers.append("longest empty run \(formatMilliseconds(longest))")
    }
    if metrics.rejectedPacketCount > 0 {
        drivers.append("\(metrics.rejectedPacketCount) rejected \(metrics.rejectedPacketCount == 1 ? "packet" : "packets")")
    }
    if let frames = metrics.frameClassification {
        if frames.parseFailure > 0 { drivers.append("\(frames.parseFailure) unreadable \(frames.parseFailure == 1 ? "packet" : "packets")") }
        if frames.outOfOrder > 0 { drivers.append("\(frames.outOfOrder) out-of-order") }
        if frames.stale > 0 { drivers.append("\(frames.stale) stale \(frames.stale == 1 ? "reading" : "readings")") }
        if frames.implausible > 0 { drivers.append("\(frames.implausible) implausible \(frames.implausible == 1 ? "reading" : "readings")") }
        if frames.duplicate > 0 { drivers.append("\(frames.duplicate) repeated \(frames.duplicate == 1 ? "reading" : "readings")") }
    }
    if metrics.missingSequenceCount > 0 {
        drivers.append("\(metrics.missingSequenceCount) missing sequence \(metrics.missingSequenceCount == 1 ? "step" : "steps")")
    }

    if drivers.isEmpty {
        lines.append("Packet inspector: no bad packets found. The score dropped because too few updates arrived.")
    } else {
        lines.append("Other issues found: \(drivers.joined(separator: ", ")).")
    }

    if let verification = metrics.protocolVerification, !verification.unverifiableClasses.isEmpty {
        lines.append(packetChecksExplanation(verification))
    }
    return lines
}

private func formatPointValue(_ value: Double) -> String {
    String(format: "%.0f points", value)
}

private func formatMultiplier(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func packetCheckListDisplay(_ checks: [String]) -> String {
    let labels = checks.map(packetCheckDisplayName).sorted()
    return labels.isEmpty ? "None" : labels.joined(separator: ", ")
}

private func packetCheckStatuses(_ verification: ProtocolVerificationMetrics) -> [(name: String, isAvailable: Bool)] {
    let verifiable = Set(verification.verifiableClasses)
    let unverifiable = Set(verification.unverifiableClasses)
    let orderedKnown = ["parseFailure", "outOfOrder", "stale", "duplicate", "implausible"]
    let extras = (verifiable.union(unverifiable).subtracting(orderedKnown)).sorted()

    return (orderedKnown + extras)
        .filter { verifiable.contains($0) || unverifiable.contains($0) }
        .map { (packetCheckDisplayName($0), verifiable.contains($0)) }
}

private func telemetryStatuses(recording: ScaleRecording, metrics: ScaleQualityMetrics) -> [(name: String, isAvailable: Bool)] {
    let capabilities = recording.protocolCapabilities
    let hasBattery = metrics.batteryMinPercent != nil
        || metrics.batteryMaxPercent != nil
        || !recording.batteryEvents.isEmpty
        || recording.samples.contains { $0.batteryPercent != nil }
    let hasFlow = recording.samples.contains { $0.flowGramsPerSecond != nil }
    let hasClock = capabilities?.hasDeviceClock == true
        || recording.samples.contains { $0.deviceTimestampMilliseconds != nil }
        || recording.rawPackets.contains { $0.deviceTimestampMilliseconds != nil }
    let hasSequence = capabilities?.hasSequence == true
        || recording.samples.contains { $0.sequence != nil }
        || recording.rawPackets.contains { $0.sequence != nil }
    let hasChecksum = capabilities?.hasChecksum == true
    let hasFirmwareQuality = metrics.firmwareQualityAverage != nil
        || recording.samples.contains { $0.firmwareQualityScore != nil }

    return [
        ("Battery", hasBattery),
        ("Flow", hasFlow),
        ("Device clock", hasClock),
        ("Sequence number", hasSequence),
        ("Checksum / CRC", hasChecksum),
        ("Firmware quality", hasFirmwareQuality)
    ]
}

private func packetChecksExplanation(_ verification: ProtocolVerificationMetrics) -> String {
    if verification.unverifiableClasses.isEmpty {
        return "This scale exposes all packet checks ScaleBench uses for this mode."
    }
    return "ScaleBench can prove \(packetCheckListDisplay(verification.verifiableClasses).lowercased()), but cannot prove \(packetCheckListDisplay(verification.unverifiableClasses).lowercased()) from this protocol."
}

private func packetCheckDisplayName(_ check: String) -> String {
    switch check {
    case "parseFailure": "unreadable packets"
    case "outOfOrder": "out-of-order packets"
    case "stale": "stale readings"
    case "duplicate": "repeated readings"
    case "implausible": "implausible readings"
    default: check
    }
}

private func resolutionDisplay(_ metrics: ScaleQualityMetrics) -> String {
    if let resolution = metrics.estimatedResolutionGrams ?? metrics.idleResolutionGrams {
        return String(format: "%.3f g", resolution)
    }
    return "—"
}

private func badPacketCount(_ metrics: ScaleQualityMetrics) -> Int {
    let frames = metrics.frameClassification
    return metrics.rejectedPacketCount
        + (frames?.parseFailure ?? 0)
        + (frames?.outOfOrder ?? 0)
        + (frames?.stale ?? 0)
        + (frames?.duplicate ?? 0)
        + (frames?.implausible ?? 0)
}

private func validityReasonLabel(_ reason: String) -> String {
    switch reason {
    case "recordingBoundariesMissing": "Recording was not started and stopped cleanly"
    case "durationBelowMinimum": "Recording is shorter than the required duration"
    case "usableFrameCountBelowMinimum": "Too few usable weight frames"
    case "idleAnalysedFrameCountBelowMinimum": "Too few idle frames remain after settling"
    case "stepBaselineFrameCountBelowMinimum": "Too few baseline frames for Step Response"
    case "stepFinalFrameCountBelowMinimum": "Too few final-window frames for Step Response"
    case "disconnectDuringRecording": "The scale disconnected during the recording"
    case "appLeftForeground": "ScaleBench left the foreground during the recording"
    case "unknownMode": "The recording mode is unknown"
    default: reason
    }
}

private func invalidScoreSummary(recording: ScaleRecording, metrics: ScaleQualityMetrics) -> String {
    let reasons = metrics.validity?.reasons ?? []
    if recording.samples.isEmpty && recording.rawPackets.isEmpty {
        return "No official score was produced because this recording has no usable scale data."
    }
    if reasons.contains("recordingBoundariesMissing") {
        return "No official score was produced because ScaleBench could not find a clean recording start and stop."
    }
    return "No official score was produced because this recording did not meet the Standard v1 requirements."
}

private func resultNarrative(for recording: ScaleRecording) -> String {
    let metrics = recording.metrics
    if let validity = metrics.validity, !validity.isValid {
        let reasons = validity.reasons.map(validityReasonLabel).joined(separator: "; ")
        return "\(invalidScoreSummary(recording: recording, metrics: metrics)) \(reasons). Diagnostics are still available."
    }

    if recording.mode == .stepResponse {
        guard let step = metrics.stepResponse, step.stepDetected else {
            return "No valid mass step was detected. Step Response needs a settled baseline, a single increase of at least 5 g, and a settled final window."
        }
        var parts = ["Step Response is metrics-only in Standard v1."]
        if let rise = step.riseTime10To90Seconds { parts.append("10–90% rise was \(formatSeconds(rise)).") }
        if let settling = step.settlingTimeSeconds { parts.append("Settling took \(formatSeconds(settling)).") }
        if let overshoot = step.overshootPercent { parts.append("Overshoot was \(String(format: "%.1f%%", overshoot)).") }
        return parts.joined(separator: " ")
    }

    if recording.mode == .tareLatency || recording.mode == .batteryStability {
        return "This mode reports metrics only and does not produce a Standard v1 score."
    }

    guard let score = benchmarkScore(mode: recording.mode, metrics: metrics) else {
        return "No score is available for this recording."
    }

    var parts: [String] = []
    switch score {
    case 90...100:
        parts.append(recording.mode == .idleStability ? "Excellent idle stability." : "Excellent delivery.")
    case 75..<90:
        parts.append("Good result with some measurable imperfections.")
    case 50..<75:
        parts.append("Usable result, but measured defects are affecting the score.")
    default:
        parts.append(recording.mode == .shot || recording.mode == .transportStress ? "Poor Delivery result." : "Poor result. This recording has significant measured defects.")
    }

    if recording.mode == .shot || recording.mode == .transportStress,
       let delivery = metrics.delivery,
       let coverage = delivery.coverage,
       let purity = delivery.purity {
        let coverageCost = max(0, 100 - (100 * coverage))
        let frameCost = max(0, (100 * coverage) - (100 * coverage * purity))
        if coverageCost >= frameCost {
            parts.append("The largest deduction was delivered packets: \(deliveredUpdatesDisplay(metrics)).")
        } else {
            parts.append("The largest deduction was usable readings: \(usableReadingsDisplay(metrics)).")
        }
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
        parts.append("\(metrics.firmwareBumpCount) bump/disturbance event\(metrics.firmwareBumpCount == 1 ? " was" : "s were") detected.")
    }

    return parts.joined(separator: " ")
}

@MainActor
private enum RecordingWakeLock {
    static func setActive(_ active: Bool) {
        UIApplication.shared.isIdleTimerDisabled = active
    }
}

#Preview {
    ContentView()
        .environmentObject(BluetoothScaleManager.preview)
}
