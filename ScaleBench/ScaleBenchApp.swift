import SwiftUI

@main
struct ScaleBenchApp: App {
    @StateObject private var bluetooth = BluetoothScaleManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
        }
    }
}

