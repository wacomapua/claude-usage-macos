import Foundation
import Combine
import WidgetKit

/// Holds the per-account transcript scanners. Confined to `UsageMonitor.scanQueue`;
/// keeping them out of the main-actor class is what makes that confinement checkable
/// rather than a comment.
private final class ScannerBox: @unchecked Sendable {
    private var scanners: [String: TranscriptScanner] = [:]

    func scanner(for id: String) -> TranscriptScanner {
        if let existing = scanners[id] { return existing }
        let created = TranscriptScanner()
        scanners[id] = created
        return created
    }
}

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

    /// Transcript scanning is far heavier than reading two JSON files, so it runs
    /// off the main thread and on a slower cadence. Scanners are stateful (they
    /// remember byte offsets per file), so one is kept per account for the life of
    /// the app — after the first pass each rescan reads only what was appended.
    private let scanQueue = DispatchQueue(label: "com.wacomapua.claudeusage.scan", qos: .utility)
    /// Owned by `scanQueue` alone — never touched from the main actor.
    private let scanners = ScannerBox()
    private var lastScan: Date = .distantPast
    private var scanInFlight = false
    private let scanInterval: TimeInterval = 60

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

        // Carry the previous scan's token stats forward so rebuilding from the
        // config files doesn't blank them out until the next scan lands.
        var rebuilt = ClaudeConfigReader.buildSnapshot()
        let existing = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0.stats) })
        for index in rebuilt.accounts.indices {
            rebuilt.accounts[index].stats = existing[rebuilt.accounts[index].id] ?? nil
        }
        publish(rebuilt)

        scanTranscripts(force: force)
    }

    private func publish(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        lastWriteSucceeded = SnapshotStore.write(snapshot)
        snapshotPaths = SnapshotStore.writtenPaths()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Rescans the transcripts for token counts, cost, burn history and model mix.
    private func scanTranscripts(force: Bool) {
        guard !scanInFlight else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastScan) >= scanInterval else { return }
        scanInFlight = true
        lastScan = now

        let targets = snapshot.accounts.map { account in
            (id: account.id,
             directory: FileManager.default.homeDirectoryForCurrentUser
                 .appendingPathComponent(account.id, isDirectory: true),
             windowStart: account.sessionWindowStart(now: now))
        }

        scanQueue.async { [weak self] in
            guard let self else { return }
            var results: [String: TokenStats] = [:]
            for target in targets {
                let scanner = self.scanners.scanner(for: target.id)
                results[target.id] = scanner.scan(
                    configDir: target.directory,
                    sessionWindowStart: target.windowStart,
                    now: now
                )
            }

            Task { @MainActor in
                var updated = self.snapshot
                for index in updated.accounts.indices {
                    if let stats = results[updated.accounts[index].id] {
                        updated.accounts[index].stats = stats
                    }
                }
                self.publish(updated)
                self.scanInFlight = false
            }
        }
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
