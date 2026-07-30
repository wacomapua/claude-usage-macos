import Foundation

/// Where the app and the widget meet.
///
/// The widget extension is force-sandboxed by macOS, so it can't read `~/.claude-*`
/// itself. The (non-sandboxed) host app does the reading and leaves a small snapshot
/// file somewhere the widget is allowed to look.
///
/// Two transports, tried in order:
///
///  1. **App Group container** — the textbook approach, but the entitlement needs a
///     provisioning profile from a registered App Group. Used automatically if present.
///  2. **The widget's own sandbox container** — a sandboxed extension can always read
///     its own Application Support directory, and the non-sandboxed host app is free to
///     write into it. No entitlements, no profile, no developer account required.
enum SnapshotStore {
    /// Must match the `com.apple.security.application-groups` entitlement, when used.
    static let appGroupID = "39GRBR78MZ.group.com.wacomapua.claudeusage"

    /// Bundle id of the widget extension — its sandbox container is named after it.
    static let widgetBundleID = "com.wacomapua.claudeusage.widget"

    private static let fileName = "usage-snapshot.json"

    // MARK: - Locations

    private static var appGroupDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The widget's Application Support directory, addressed from outside the sandbox.
    private static var widgetContainerDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support", isDirectory: true)
    }

    /// The same directory as seen from *inside* the widget's sandbox, where the system
    /// rewrites Application Support to point at the container.
    private static var localApplicationSupport: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Host app side

    /// Writes the snapshot to every transport that accepts it.
    /// - Returns: true if at least one write landed.
    @discardableResult
    static func write(_ snapshot: UsageSnapshot) -> Bool {
        guard let data = try? encoder.encode(snapshot) else { return false }

        // Write to both, not just the first that works: whichever transport the widget
        // ends up using, it finds current data.
        let destinations = [appGroupDirectory, widgetContainerDirectory].compactMap { $0 }
        return destinations.reduce(false) { didWrite, directory in
            write(data, into: directory) || didWrite
        }
    }

    private static func write(_ data: Data, into directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic so the widget can never observe a half-written file.
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Human-readable list of the paths actually written, for the app's diagnostics panel.
    static func writtenPaths() -> [String] {
        [appGroupDirectory, widgetContainerDirectory]
            .compactMap { $0?.appendingPathComponent(fileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    // MARK: - Widget side

    static func read() -> UsageSnapshot? {
        // Inside the widget's sandbox `localApplicationSupport` *is* the container
        // directory the host app wrote to; outside it, it is the real one in ~/Library.
        let candidates = [appGroupDirectory, localApplicationSupport, widgetContainerDirectory]
        for directory in candidates.compactMap({ $0 }) {
            let url = directory.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(UsageSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }
}
