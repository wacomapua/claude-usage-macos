import Foundation
import Combine
import WidgetKit

/// Watches the Claude Code config files and republishes a snapshot for the widget.
///
/// Polling beats file-system events here: the files are rewritten atomically (which
/// invalidates a `DispatchSource` watcher and forces a re-arm dance), a `stat` of two
/// files every few seconds costs nothing, and WidgetKit throttles refreshes anyway.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var lastWriteSucceeded = true
    @Published private(set) var configDirectories: [URL] = []
    @Published private(set) var snapshotPaths: [String] = []

    private var timer: Timer?
    private var fingerprint: String = ""

    private let pollInterval: TimeInterval = 15

    init() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    /// Rebuilds the snapshot if any watched file changed (or `force` is set).
    func refresh(force: Bool = false) {
        let dirs = ClaudeConfigReader.discoverConfigDirectories()
        configDirectories = dirs

        // macOS recreates an extension's container the first time it registers the
        // widget, which wipes whatever we put there. Without this check the snapshot
        // would stay missing until a config file happened to change.
        let snapshotMissing = SnapshotStore.writtenPaths().isEmpty

        let current = Self.fingerprint(of: dirs)
        guard force || snapshotMissing || current != fingerprint else { return }
        fingerprint = current

        snapshot = ClaudeConfigReader.buildSnapshot()
        lastWriteSucceeded = SnapshotStore.write(snapshot)
        snapshotPaths = SnapshotStore.writtenPaths()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Cheap change-detector: size + mtime of each account's config file.
    private static func fingerprint(of dirs: [URL]) -> String {
        dirs.map { dir -> String in
            let path = dir.appendingPathComponent(".claude.json").path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            return "\(path):\(modified):\(size)"
        }
        .joined(separator: "|")
    }
}
