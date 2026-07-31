import Foundation
import Security

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

    // MARK: Keychain

    private struct Credentials {
        var accessToken: String
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            // Treat a token about to lapse as already gone rather than racing it.
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private static func credentials(service: String) throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw FetchError.noToken }

        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { throw FetchError.malformed }

        let expiry = (oauth["expiresAt"] as? Double).map {
            // The field is milliseconds since the epoch.
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return Credentials(accessToken: token, expiresAt: expiry)
    }

    // MARK: Fetch

    /// Returns the raw utilization payload for one account.
    static func fetch(service: String) async throws -> [String: Any] {
        let creds = try credentials(service: service)
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
