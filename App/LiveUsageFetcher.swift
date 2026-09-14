import Foundation
import Security

/// One account's OAuth token as Claude Code stores it.
private struct Credentials {
    var accessToken: String
    var expiresAt: Date?

    /// True once the token is inside the margin where a request could lapse mid-flight.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        // Treat a token about to lapse as already gone rather than racing it.
        return expiresAt.timeIntervalSinceNow < 60
    }
}

/// Reads and caches the tokens, off the main thread.
///
/// Two reasons this is an actor rather than a static function:
///
/// 1. **A Keychain read can block.** If it ever does raise a dialog, the dialog owns
///    the calling thread until it is answered, which on the main actor would freeze
///    the whole app behind it.
/// 2. **A token is good for hours, and the live loop runs every minute.** Caching the
///    parsed credentials until they near expiry turns ~1,400 Keychain reads a day per
///    account into a handful.
private actor CredentialStore {
    static let shared = CredentialStore()

    private var cache: [String: Credentials] = [:]

    func credentials(service: String) throws -> Credentials {
        if let cached = cache[service], !cached.isExpired { return cached }
        let fresh = try Self.read(service: service)
        cache[service] = fresh
        return fresh
    }

    /// Drops a cached token, so the next call goes back to the Keychain. Used when the
    /// API rejects it: Claude Code can rotate a token long before its stated expiry.
    func invalidate(service: String) {
        cache[service] = nil
    }

    // MARK: Reading

    private static func read(service: String) throws -> Credentials {
        guard let data = securityTool(service: service) ?? frameworkRead(service: service) else {
            throw LiveUsageFetcher.FetchError.noToken
        }

        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { throw LiveUsageFetcher.FetchError.malformed }

        let expiry = (oauth["expiresAt"] as? Double).map {
            // The field is milliseconds since the epoch.
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return Credentials(accessToken: token, expiresAt: expiry)
    }

    /// Reads through `/usr/bin/security`, the way Claude Code itself does.
    ///
    /// This is what stops the "allow access" dialog coming back. A Keychain item's
    /// ACL names the applications trusted to decrypt it, and Claude Code writes its
    /// credentials with `security add-generic-password -U`, so the trusted application
    /// on that item is `/usr/bin/security`. Claude Code then reads them back with
    /// `security find-generic-password -w`, which is why the CLI never prompts itself.
    ///
    /// Asking through the framework instead makes *this app* the requesting process,
    /// which is not on that ACL, so macOS asks. "Always Allow" adds us, until the
    /// next time Claude Code rewrites the item and the ACL reverts to what its own
    /// writer put there. Hence a prompt that keeps coming back however often it is
    /// granted. Borrowing the same trusted reader sidesteps the whole cycle.
    ///
    /// Still strictly read-only: `find-generic-password` cannot write anything.
    private static func securityTool(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // No `-a`: the service name is already unique per account, and the account
        // attribute is whatever username Claude Code happened to be running as.
        process.arguments = ["find-generic-password", "-w", "-s", service]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        // `-w` prints the secret followed by a newline.
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Data(text.utf8)
    }

    /// Fallback for a machine where the item was written by something other than the
    /// `security` tool, so that ACL entry isn't there. This is the path that prompts.
    private static func frameworkRead(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

/// Fetches usage straight from the API instead of reading Claude Code's cache.
///
/// Claude Code stores each account's OAuth token in the login Keychain under
/// `Claude Code-credentials`, suffixed per `CLAUDE_CONFIG_DIR` (see
/// `AccountLocation.keychainService`). With that token the same endpoint Claude
/// Code's own `/usage` view calls returns live figures.
///
/// **This is strictly read-only.** It never writes to the Keychain and never
/// refreshes an expired token. Refresh tokens rotate — spending one here could
/// invalidate the copy Claude Code holds and sign the user out of the CLI. An
/// expired token simply falls back to the cached numbers, and Claude Code will
/// refresh it itself the next time it runs.
enum LiveUsageFetcher {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Same beta header Claude Code sends; OAuth tokens are rejected without it.
    private static let oauthBeta = "oauth-2025-04-20"

    enum FetchError: Error, LocalizedError {
        case noToken
        case tokenExpired(Date)
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .noToken: return "No stored credentials for this account"
            case .tokenExpired(let date):
                return "Token expired \(UsageFormat.age(of: date)) — run Claude Code once to refresh"
            case .http(let code): return "Usage endpoint returned \(code)"
            case .malformed: return "Unexpected response shape"
            }
        }
    }

    // MARK: Fetch

    /// Returns the raw utilization payload for one account.
    static func fetch(service: String) async throws -> [String: Any] {
        do {
            return try await request(service: service)
        } catch FetchError.http(401) {
            // The cached token was rotated out from under us before its stated expiry.
            // Re-read once, then give up so a genuinely rejected token can't loop.
            await CredentialStore.shared.invalidate(service: service)
            return try await request(service: service)
        }
    }

    private static func request(service: String) async throws -> [String: Any] {
        let creds = try await CredentialStore.shared.credentials(service: service)
        if creds.isExpired, let expiry = creds.expiresAt { throw FetchError.tokenExpired(expiry) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError.malformed
        }
        return root
    }
}
