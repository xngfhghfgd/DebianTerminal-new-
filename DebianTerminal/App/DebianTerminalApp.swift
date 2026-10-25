import SwiftUI

@main
struct DebianTerminalApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .tint(.indigo)
        }
    }
}
