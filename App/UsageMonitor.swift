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
/// Three loops, each on its own cadence because they cost wildly different amounts:
///
/// | Loop | Every | Cost |
/// | --- | --- | --- |
/// | Config poll | 15s | two `stat` calls |
/// | Transcript scan | 60s | incremental read, off the main thread |
/// | Live usage fetch | 5min | one HTTPS request per account |
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var lastWriteSucceeded = true
    @Published private(set) var locations: [AccountLocation] = []
    @Published private(set) var snapshotPaths: [String] = []
    /// Per-account failure text from the last live fetch, if any.
    @Published private(set) var liveErrors: [String: String] = [:]

    /// Live fetch needs Keychain access, which prompts the user, so it's opt-in.
    @Published var liveEnabled: Bool = UserDefaults.standard.bool(forKey: "liveEnabled") {
        didSet {
            UserDefaults.standard.set(liveEnabled, forKey: "liveEnabled")
            if liveEnabled { fetchLive(force: true) } else { liveErrors = [:] }
        }
    }

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

    /// Claude Code throttles writes to *its own cache* every 5 minutes, but that says
    /// nothing about how often we may ask the API ourselves. A minute is ~1,440
    /// requests a day per account.
    ///
    /// The endpoint is undocumented, so its rate limit is unknown — `liveBackoff`
    /// doubles the interval on each 429 or 5xx (to a 30-minute ceiling) and resets on
    /// the first success. An aggressive setting degrades instead of hammering.
    private var lastLiveFetch: Date = .distantPast
    private var liveInFlight = false
    private let liveInterval: TimeInterval = 60
    private let liveBackoffCeiling: TimeInterval = 1800
    private var liveBackoff: TimeInterval = 0

    init() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    /// Rebuilds the snapshot if any watched file changed (or `force` is set).
    func refresh(force: Bool = false) {
        locations = AccountLocation.discoverAll()

        // macOS recreates an extension's container the first time it registers the
        // widget, which wipes whatever we put there. Without this check the snapshot
        // would stay missing until a config file happened to change.
        let snapshotMissing = SnapshotStore.writtenPaths().isEmpty

        let current = Self.fingerprint(of: locations)
        guard force || snapshotMissing || current != fingerprint else {
            scanTranscripts(force: false)
            fetchLive(force: false)
            return
        }
        fingerprint = current

        // Carry forward everything the config file doesn't know about, so rebuilding
        // from disk doesn't blank out the token stats or drop back to cached gauges
        // until the next scan and fetch land.
        var rebuilt = ClaudeConfigReader.buildSnapshot()
        let previous = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) })
        for index in rebuilt.accounts.indices {
            guard let old = previous[rebuilt.accounts[index].id] else { continue }
            rebuilt.accounts[index].stats = old.stats
            if old.isLive, let fetched = old.fetchedAt,
               fetched > (rebuilt.accounts[index].fetchedAt ?? .distantPast) {
                rebuilt.accounts[index].session = old.session
                rebuilt.accounts[index].weekly = old.weekly
                rebuilt.accounts[index].scoped = old.scoped
                rebuilt.accounts[index].fetchedAt = fetched
                rebuilt.accounts[index].isLive = true
            }
        }
        publish(rebuilt)

        scanTranscripts(force: force)
        fetchLive(force: force)
    }

    private func publish(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        lastWriteSucceeded = SnapshotStore.write(snapshot)
        snapshotPaths = SnapshotStore.writtenPaths()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Live fetch

    private func fetchLive(force: Bool) {
        guard liveEnabled, !liveInFlight, !locations.isEmpty else { return }
        let now = Date()
        let wait = liveInterval + liveBackoff
        guard force || now.timeIntervalSince(lastLiveFetch) >= wait else { return }
        liveInFlight = true
        lastLiveFetch = now

        let targets = locations.map { (id: $0.id, service: $0.keychainService) }

        Task { @MainActor in
            var payloads: [String: [String: Any]] = [:]
            var errors: [String: String] = [:]
            var throttled = false

            for target in targets {
                do {
                    payloads[target.id] = try await LiveUsageFetcher.fetch(service: target.service)
                } catch {
                    errors[target.id] = error.localizedDescription
                    // Only a server pushing back should slow us down. A missing or
                    // expired token is a permanent condition for this account and
                    // retrying later at any interval won't fix it.
                    if case LiveUsageFetcher.FetchError.http(let code) = error,
                       code == 429 || code >= 500 {
                        throttled = true
                    }
                }
            }

            if throttled {
                liveBackoff = min(liveBackoffCeiling,
                                  liveBackoff == 0 ? liveInterval : liveBackoff * 2)
            } else if !payloads.isEmpty {
                liveBackoff = 0
            }

            var updated = snapshot
            for index in updated.accounts.indices {
                guard let payload = payloads[updated.accounts[index].id] else { continue }
                ClaudeConfigReader.applyLive(payload, to: &updated.accounts[index])
            }
            liveErrors = errors
            publish(updated)
            liveInFlight = false
        }
    }

    // MARK: - Transcript scan

    /// Rescans the transcripts for token counts, cost, burn history and model mix.
    private func scanTranscripts(force: Bool) {
        guard !scanInFlight else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastScan) >= scanInterval else { return }
        scanInFlight = true
        lastScan = now

        let targets: [(id: String, directory: URL, windowStart: Date)] =
            snapshot.accounts.compactMap { account in
                guard let path = account.dataDirPath else { return nil }
                return (account.id, URL(fileURLWithPath: path),
                        account.sessionWindowStart(now: now))
            }

        scanQueue.async { [weak self] in
            guard let self else { return }
            var results: [String: TokenStats] = [:]
            for target in targets {
                results[target.id] = self.scanners.scanner(for: target.id).scan(
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
    private static func fingerprint(of locations: [AccountLocation]) -> String {
        locations.map { location -> String in
            let path = location.configFile.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            return "\(path):\(modified):\(size)"
        }
        .joined(separator: "|")
    }
}
