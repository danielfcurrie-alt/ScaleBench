import SwiftUI

final class AppCommandRouter: ObservableObject {
    @Published var helpRequestID = UUID()
    @Published var startRecordingRequestID = UUID()
    @Published var stopRecordingRequestID = UUID()
    @Published var importRecordingRequestID = UUID()
    @Published var exportJSONRequestID = UUID()
    @Published var exportScorecardRequestID = UUID()
    @Published var resetRequestID = UUID()
    @Published private(set) var canStartRecording = false
    @Published private(set) var isRecording = false
    @Published private(set) var canExport = false
    @Published private(set) var canExportScorecard = false

    func showHelp() {
        helpRequestID = UUID()
    }

    func updateState(
        canStartRecording: Bool,
        isRecording: Bool,
        canExport: Bool,
        canExportScorecard: Bool
    ) {
        if self.canStartRecording != canStartRecording {
            self.canStartRecording = canStartRecording
        }
        if self.isRecording != isRecording {
            self.isRecording = isRecording
        }
        if self.canExport != canExport {
            self.canExport = canExport
        }
        if self.canExportScorecard != canExportScorecard {
            self.canExportScorecard = canExportScorecard
        }
    }
}

@main
struct ScaleBenchApp: App {
    @StateObject private var bluetooth = BluetoothScaleManager()
    @StateObject private var appCommands = AppCommandRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(appCommands)
        }
        .commands {
#if targetEnvironment(macCatalyst)
            CommandGroup(after: .newItem) {
                Button("Import Recording...") {
                    appCommands.importRecordingRequestID = UUID()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Export Current JSON...") {
                    appCommands.exportJSONRequestID = UUID()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!appCommands.canExport)

                Button("Export Official Scorecard...") {
                    appCommands.exportScorecardRequestID = UUID()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!appCommands.canExportScorecard)
            }

            CommandMenu("Recording") {
                Button("Start Recording") {
                    appCommands.startRecordingRequestID = UUID()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!appCommands.canStartRecording)

                Button("Stop and Save Recording") {
                    appCommands.stopRecordingRequestID = UUID()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!appCommands.isRecording)

                Divider()

                Button("Reset Current Recording") {
                    appCommands.resetRequestID = UUID()
                }
            }
#endif

            CommandGroup(replacing: .help) {
                Button("ScaleBench Help") {
                    appCommands.showHelp()
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }
    }
}
