import Foundation

/// Talks to `codex app-server`, the JSON-RPC server built into the Codex CLI.
///
/// Codex is nothing like Claude Code here. Claude Code writes the same figures its
/// `/usage` view shows into `.claude.json`, so the widget can read them straight off the
/// disk and only needs the network to be *fresher*. Codex keeps no such cache: the rate
/// limits it draws in its own status line arrive on the wire and are never persisted.
/// Grepping the whole of `~/.codex` finds `usedPercent` only inside `sessions/*.jsonl`
/// rollout files that the current version has stopped writing, and in none of its SQLite
/// stores. There is simply nothing on disk to read.
///
/// So every Codex figure in this app is a live read, and the app's own snapshot file is
/// the only thing that carries them across a relaunch.
///
/// Going through the CLI rather than calling the backend directly is the point:
///
/// - **No token handling.** Codex owns its OAuth tokens in `~/.codex/auth.json` and
///   refreshes them itself. Reading that file and spending a refresh token here could
///   invalidate the CLI's own copy. That is the same trap the Claude live path
///   documents at length, avoided entirely by never touching the credentials.
/// - **A stated contract.** `codex app-server generate-json-schema` emits the full
///   protocol, so the response shape is checkable rather than reverse-engineered.
///
/// Read-only: the only methods called are `account/rateLimits/read`, `account/usage/read`
/// and `account/read`. Nothing here starts a thread, a turn, or anything that spends quota.
enum CodexAppServer {

    /// The three responses, still as raw dictionaries. Parsed in `CodexReader` for the
    /// same reason `ClaudeConfigReader` parses defensively: this is an experimental
    /// interface that can change under us, and dropping one field is far better than
    /// failing to decode at all.
    struct Payload {
        var rateLimits: [String: Any]
        var usage: [String: Any]?
        var account: [String: Any]?
    }

    enum ReadError: Error, LocalizedError {
        case notInstalled
        case launchFailed(String)
        case noResponse
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Codex CLI not found. If you've just installed it, restart this app."
            case .launchFailed(let message):
                return "Couldn't start codex app-server: \(message)"
            case .noResponse:
                return "codex app-server didn't answer in time"
            case .rpc(let message):
                return message
            }
        }
    }

    // MARK: - Locating the binary

    /// Absolute installs, in the order they're worth trying.
    private static let absoluteCandidates = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex",
    ]

    /// The same, relative to the home directory: the npm, pnpm, bun and volta layouts.
    private static let homeCandidates = [
        ".local/bin/codex",
        ".bun/bin/codex",
        ".volta/bin/codex",
        ".npm-global/bin/codex",
        "Library/pnpm/codex",
    ]

    /// Resolved once per run.
    ///
    /// An app launched by the Finder or by launchd inherits a bare
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so `codex` is never simply on the `PATH` the way
    /// it is in a terminal. Searching the usual install locations is not belt and
    /// braces, it's the only thing that works. The login shell is the last resort
    /// because spawning one costs far more than four `stat` calls.
    ///
    /// Cached for the life of the process, so installing Codex while the app is running
    /// needs a restart. That's the trade for not paying the lookup every five minutes.
    private static let binary: URL? = locate()

    private static func locate() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = absoluteCandidates.map { URL(fileURLWithPath: $0) }
            + homeCandidates.map { home.appendingPathComponent($0) }

        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        return loginShellLookup()
    }

    /// Asks the user's shell where `codex` is, the way they'd ask it themselves.
    /// Catches installs this file has never heard of: asdf, mise, a hand-rolled prefix.
    private static func loginShellLookup() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True when a Codex install was found. Used to decide whether the toggle is worth
    /// showing at all.
    static var isAvailable: Bool { binary != nil }

    static var binaryPath: String? { binary?.path }

    // MARK: - The session

    private static let initializeID = 1
    private static let rateLimitsID = 2
    private static let usageID = 3
    private static let accountID = 4

    /// Runs one short JSON-RPC session and returns the three payloads.
    ///
    /// Blocking by design: the caller runs it on a utility queue, the same way the
    /// transcript scan is kept off the main thread.
    static func read(timeout: TimeInterval = 20) throws -> Payload {
        guard let binary else { throw ReadError.notInstalled }
        _ = ignoreBrokenPipeOnce

        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Codex writes tracing to stderr. Nothing here reads it, and a pipe nobody
        // drains eventually fills and wedges the child, so it goes to /dev/null.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ReadError.launchFailed(error.localizedDescription)
        }

        // A server that never answers must not hold the fetch loop open. Terminating it
        // closes stdout, which is exactly what ends the read loop below.
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let writer = input.fileHandleForWriting
        func send(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            // Swallowed rather than thrown: if the child has already gone, the read loop
            // below will see EOF and report that, which is the more useful error.
            try? writer.write(contentsOf: data + Data("\n".utf8))
        }

        send([
            "jsonrpc": "2.0", "id": initializeID, "method": "initialize",
            "params": ["clientInfo": ["name": "ClaudeUsage", "version": appVersion]],
        ])

        var results: [Int: [String: Any]] = [:]
        var failures: [Int: String] = [:]
        var buffer = Data()
        let reader = output.fileHandleForReading

        while results.count + failures.count < 4 {
            guard let line = takeLine(&buffer) else {
                let chunk = reader.availableData
                if chunk.isEmpty { break }   // the server closed, or the deadline fired
                buffer.append(chunk)
                continue
            }

            // Notifications carry no id and are of no interest here.
            guard
                let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                let id = message["id"] as? Int
            else { continue }

            // Keyed on which member is present, not on its shape: a server-initiated
            // *request* also carries an id, and counting one as a response would let a
            // colliding id stand in for an answer that never came.
            if message.index(forKey: "result") != nil {
                results[id] = (message["result"] as? [String: Any]) ?? [:]
            } else if let error = message["error"] as? [String: Any] {
                failures[id] = error["message"] as? String ?? "request \(id) failed"
            } else {
                continue
            }

            guard id == initializeID else { continue }
            if failures[initializeID] != nil { break }

            // The handshake isn't finished until the client acknowledges it, and reads
            // sent before that are rejected. All three go out together: they're
            // independent, and the server answers them in whatever order it likes.
            send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
            send([
                "jsonrpc": "2.0", "id": rateLimitsID, "method": "account/rateLimits/read",
                // The reset-credit detail rows are a second backend lookup and nothing
                // here shows them; the available count comes back either way.
                "params": ["excludeResetCreditDetails": true],
            ])
            send(["jsonrpc": "2.0", "id": usageID, "method": "account/usage/read", "params": [:]])
            send(["jsonrpc": "2.0", "id": accountID, "method": "account/read", "params": [:]])
        }

        if let message = failures[rateLimitsID] { throw ReadError.rpc(message) }
        guard let limits = results[rateLimitsID] else {
            if let message = failures[initializeID] { throw ReadError.rpc(message) }
            throw ReadError.noResponse
        }
        // Usage and account are best-effort: the limits are the headline, and losing the
        // token totals or the email address shouldn't cost the whole reading.
        return Payload(rateLimits: limits, usage: results[usageID], account: results[accountID])
    }

    // MARK: - Plumbing

    private static let newline = Data([0x0a])

    /// Pulls one newline-terminated message off the front of the buffer.
    private static func takeLine(_ buffer: inout Data) -> Data? {
        guard let range = buffer.firstRange(of: newline) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return line
    }

    /// Writing to a pipe whose reader has gone raises `SIGPIPE`, whose default
    /// disposition is to kill the *writing* process, meaning this app. Ignoring it turns
    /// that into the `EPIPE` the `try?` above already handles.
    private static let ignoreBrokenPipeOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
