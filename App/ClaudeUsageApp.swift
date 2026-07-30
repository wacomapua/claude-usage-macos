import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var monitor = UsageMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Claude Usage", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 380, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .onChange(of: scenePhase) { _, phase in
            // Picking the window back up should show current numbers immediately.
            if phase == .active { monitor.refresh(force: true) }
        }
    }
}
