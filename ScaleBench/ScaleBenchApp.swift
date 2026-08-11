import SwiftUI

final class AppCommandRouter: ObservableObject {
    @Published var helpRequestID = UUID()

    func showHelp() {
        helpRequestID = UUID()
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
            CommandGroup(replacing: .help) {
                Button("ScaleBench Help") {
                    appCommands.showHelp()
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }
    }
}
