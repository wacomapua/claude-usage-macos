import Foundation
import CryptoKit

/// Where one Claude Code account keeps its files.
///
/// There are two layouts, and they are not the same shape:
///
/// - **Default install** — config at `~/.claude.json`, data under `~/.claude/`.
/// - **`CLAUDE_CONFIG_DIR` install** — both inside the directory, e.g.
///   `~/.claude-work/.claude.json` and `~/.claude-work/projects/`.
///
/// An earlier version only looked for `<dir>/.claude.json`, which silently missed
/// every single-account install — the common case.
struct AccountLocation {
    /// Stable identifier, also used as the snapshot key.
    var id: String
    var label: String
    var configFile: URL
    /// Directory containing `projects/`.
    var dataDir: URL
    /// The value of `CLAUDE_CONFIG_DIR` for this account, or nil for a default install.
    /// Determines the Keychain service name.
    var configDirOverride: URL?

    /// Claude Code names its Keychain entry `Claude Code-credentials`, suffixed with
    /// the first 8 hex characters of the SHA-256 of `CLAUDE_CONFIG_DIR` when that is
    /// set. That's what keeps multiple accounts' tokens apart on one machine.
    var keychainService: String {
        let base = "Claude Code-credentials"
        guard let dir = configDirOverride else { return base }
        let normalized = dir.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(base)-\(hex.prefix(8))"
    }

    // MARK: Discovery

    /// Finds every account on this machine — one, several, or none.
    static func discoverAll() -> [AccountLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [AccountLocation] = []

        // Default install.
        let defaultConfig = home.appendingPathComponent(".claude.json")
        let defaultData = home.appendingPathComponent(".claude", isDirectory: true)
        if fm.fileExists(atPath: defaultConfig.path) {
            found.append(AccountLocation(
                id: "default",
                label: "Claude",
                configFile: defaultConfig,
                dataDir: defaultData,
                configDirOverride: nil
            ))
        }

        // CLAUDE_CONFIG_DIR installs.
        let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        for name in entries.sorted() where name.hasPrefix(".claude-") {
            let dir = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let config = dir.appendingPathComponent(".claude.json")
            guard fm.fileExists(atPath: config.path) else { continue }
            found.append(AccountLocation(
                id: name,
                label: label(forDirectoryNamed: name),
                configFile: config,
                dataDir: dir,
                configDirOverride: dir
            ))
        }

        return found.filter(\.isInUse)
    }

    /// A machine can carry a leftover default `~/.claude.json` from before the user
    /// switched to per-account directories — it still has an `oauthAccount` but no
    /// usage and no transcripts. Requiring evidence of actual use keeps that ghost
    /// account out of the widget without hard-coding anything about this machine.
    var isInUse: Bool {
        guard
            let data = try? Data(contentsOf: configFile),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }

        if root["cachedUsageUtilization"] is [String: Any] { return true }

        let hasAccount = (root["oauthAccount"] as? [String: Any])?["emailAddress"] != nil
        let projects = dataDir.appendingPathComponent("projects", isDirectory: true)
        let hasTranscripts = ((try? FileManager.default
            .contentsOfDirectory(atPath: projects.path))?.isEmpty == false)
        return hasAccount && hasTranscripts
    }

    /// ".claude-personal" → "Personal". The default install is just "Claude".
    private static func label(forDirectoryNamed name: String) -> String {
        let suffix = String(name.dropFirst(".claude-".count))
        guard !suffix.isEmpty else { return "Claude" }
        return suffix.prefix(1).uppercased() + suffix.dropFirst()
    }
}
