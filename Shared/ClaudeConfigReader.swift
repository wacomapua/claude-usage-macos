import Foundation

/// Reads the usage numbers Claude Code caches on disk.
///
/// Claude Code writes the same figures `/usage` shows into `<configDir>/.claude.json`
/// under `cachedUsageUtilization`. Multiple accounts are kept apart by `CLAUDE_CONFIG_DIR`,
/// so each account is simply a different directory (`~/.claude-personal`, `~/.claude-work`).
///
/// Everything here is parsed defensively with `JSONSerialization` rather than `Codable`:
/// this is an internal file format that can change under us, and a widget that silently
/// drops one field is far better than one that fails to decode at all.
enum ClaudeConfigReader {

    /// Builds a full snapshot from every discovered account.
    static func buildSnapshot() -> UsageSnapshot {
        let accounts = AccountLocation.discoverAll().compactMap { readAccount(at: $0) }
        return UsageSnapshot(accounts: accounts, generatedAt: Date())
    }

    /// Parses one account's config file. Returns nil only if the file is unreadable.
    static func readAccount(at location: AccountLocation) -> AccountUsage? {
        guard
            let data = try? Data(contentsOf: location.configFile),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let oauth = root["oauthAccount"] as? [String: Any]
        let cached = root["cachedUsageUtilization"] as? [String: Any]
        let utilization = cached?["utilization"] as? [String: Any]

        let fetchedAt = (cached?["fetchedAtMs"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }

        var account = AccountUsage(
            id: location.id,
            label: location.label,
            email: oauth?["emailAddress"] as? String ?? "unknown account",
            plan: planDescription(from: oauth),
            fetchedAt: fetchedAt,
            session: gauge(utilization?["five_hour"]),
            weekly: gauge(utilization?["seven_day"]),
            scoped: scopedGauges(from: utilization),
            spend: spend(from: utilization?["spend"] as? [String: Any])
        )
        account.dataDirPath = location.dataDir.path
        return account
    }

    /// Applies a freshly fetched utilization payload over an account, replacing the
    /// cached gauges. Shares the same parsers as the cache path — the server returns
    /// the identical shape, which is why the cache is a verbatim copy of it.
    static func applyLive(_ utilization: [String: Any], to account: inout AccountUsage,
                          at date: Date = Date()) {
        // The endpoint returns the utilization object itself; the cache nests it one
        // level down. Accept either so the same parser serves both.
        let payload = (utilization["utilization"] as? [String: Any]) ?? utilization

        account.session = gauge(payload["five_hour"]) ?? account.session
        account.weekly = gauge(payload["seven_day"]) ?? account.weekly
        let scoped = scopedGauges(from: payload)
        if !scoped.isEmpty { account.scoped = scoped }
        if let spend = spend(from: payload["spend"] as? [String: Any]) { account.spend = spend }
        account.fetchedAt = date
        account.isLive = true
    }

    // MARK: - Field parsing

    private static func gauge(_ raw: Any?) -> Gauge? {
        guard let dict = raw as? [String: Any], let percent = dict["utilization"] as? Int else { return nil }
        return Gauge(percent: percent, resetsAt: date(dict["resets_at"]))
    }

    /// Per-model weekly limits, e.g. a separate Opus allowance.
    ///
    /// The `limits` array is the richer source because it carries the model's display
    /// name; the `seven_day_<model>` keys are the fallback when it's absent.
    private static func scopedGauges(from utilization: [String: Any]?) -> [ScopedGauge] {
        guard let utilization else { return [] }

        if let limits = utilization["limits"] as? [[String: Any]] {
            let scoped = limits.compactMap { limit -> ScopedGauge? in
                guard
                    limit["kind"] as? String == "weekly_scoped",
                    let percent = limit["percent"] as? Int,
                    let scope = limit["scope"] as? [String: Any],
                    let model = scope["model"] as? [String: Any],
                    let name = model["display_name"] as? String
                else { return nil }
                return ScopedGauge(name: name, percent: percent, resetsAt: date(limit["resets_at"]))
            }
            if !scoped.isEmpty { return scoped }
        }

        return ["seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet"].compactMap { key, name in
            guard let g = gauge(utilization[key]) else { return nil }
            return ScopedGauge(name: name, percent: g.percent, resetsAt: g.resetsAt)
        }
        .sorted { $0.name < $1.name }
    }

    private static func spend(from raw: [String: Any]?) -> Spend? {
        guard
            let raw,
            raw["enabled"] as? Bool == true,
            let used = raw["used"] as? [String: Any],
            let minor = used["amount_minor"] as? Int
        else { return nil }

        let limit = raw["limit"] as? [String: Any]
        // A zero limit means "no cap configured", not "capped at nothing".
        let limitMinor = (limit?["amount_minor"] as? Int).flatMap { $0 > 0 ? $0 : nil }

        return Spend(
            usedMinor: minor,
            limitMinor: limitMinor,
            currency: used["currency"] as? String ?? "USD",
            exponent: used["exponent"] as? Int ?? 2,
            enabled: true
        )
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }

    // MARK: - Naming

    /// ".claude-personal" → "Personal", ".claude" → "Default".
    static func label(forDirectoryNamed name: String) -> String {
        guard name.hasPrefix(".claude-") else { return "Default" }
        let suffix = String(name.dropFirst(".claude-".count))
        return suffix.isEmpty ? "Default" : suffix.prefix(1).uppercased() + suffix.dropFirst()
    }

    private static func planDescription(from oauth: [String: Any]?) -> String {
        guard let oauth else { return "—" }
        let orgType = oauth["organizationType"] as? String ?? ""
        // The user's own tier wins over the org default — on a Team plan the seat
        // carries the individual allowance.
        let tier = (oauth["userRateLimitTier"] as? String)
            ?? (oauth["organizationRateLimitTier"] as? String)
            ?? ""

        let multiplier = tier.contains("max_20x") ? "20×" : tier.contains("max_5x") ? "5×" : nil

        switch orgType {
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case "claude_max": return multiplier.map { "Max \($0)" } ?? "Max"
        case "claude_pro": return "Pro"
        default:
            if let multiplier { return "Max \(multiplier)" }
            return orgType.isEmpty ? "—" : orgType
                .replacingOccurrences(of: "claude_", with: "")
                .capitalized
        }
    }
}
