import SwiftUI
import AppKit

/// Keeps the app alive without a window, so the widget carries on updating after the
/// window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Clicking the Dock icon after closing the window brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        !hasVisibleWindows
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = UsageMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Claude Usage", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 420, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .onChange(of: scenePhase) { _, phase in
            // Picking the window back up should show current numbers immediately.
            if phase == .active { monitor.refresh(force: true) }
        }
    }
}
