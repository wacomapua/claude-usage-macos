import Foundation

/// Turns the Codex app-server payloads into the same `AccountUsage` the Claude side
/// produces, so one set of views draws both.
///
/// Parsed with `JSONSerialization` rather than `Codable`, for the reason spelled out in
/// `ClaudeConfigReader`: this is an experimental interface, and a widget that silently
/// drops one field is far better than one that fails to decode at all.
enum CodexReader {

    /// The account id Codex usage is filed under. Codex supports one signed-in account
    /// per `CODEX_HOME`, and this app only ever reads the default `~/.codex`.
    static let accountID = "codex"

    /// Fetches and parses in one go. Blocking, so call it off the main thread.
    static func read(now: Date = Date()) throws -> AccountUsage {
        parse(try CodexAppServer.read(), now: now)
    }

    static func parse(_ payload: CodexAppServer.Payload, now: Date = Date()) -> AccountUsage {
        let limits = payload.rateLimits["rateLimits"] as? [String: Any] ?? [:]
        let account = payload.account?["account"] as? [String: Any]

        let primary = gauge(limits["primary"])
        let secondary = gauge(limits["secondary"])

        return AccountUsage(
            id: accountID,
            label: "Codex",
            email: account?["email"] as? String ?? "unknown account",
            // The account's own plan wins: the rate-limit bucket repeats it, but the
            // account read is where it actually belongs.
            plan: planName(account?["planType"] as? String ?? limits["planType"] as? String),
            fetchedAt: now,
            session: primary,
            weekly: secondary,
            scoped: scopedGauges(from: payload.rateLimits, excluding: limits["limitId"] as? String),
            spend: nil,
            // Codex has no cache to fall back to, so anything shown here was fetched
            // just now by definition.
            isLive: true,
            provider: .codex,
            codex: stats(payload, window: primary, now: now)
        )
    }

    // MARK: - Rate limits

    /// Codex states its window lengths, and they vary by plan: 5 hours on a paid
    /// account, 30 days on a free one. So the duration travels with the gauge rather
    /// than being assumed by the views.
    private static func gauge(_ raw: Any?) -> Gauge? {
        guard let dict = raw as? [String: Any], let percent = dict["usedPercent"] as? Int else {
            return nil
        }
        let minutes = dict["windowDurationMins"] as? Int
        return Gauge(
            percent: percent,
            resetsAt: epochSeconds(dict["resetsAt"]),
            windowDuration: minutes.map { TimeInterval($0 * 60) }
        )
    }

    /// The other metered buckets, as meters under the dial.
    ///
    /// `rateLimitsByLimitId` always repeats the headline bucket, so that one is dropped
    /// by id; anything left is a genuinely separate quota.
    private static func scopedGauges(from root: [String: Any], excluding primaryID: String?) -> [ScopedGauge] {
        guard let buckets = root["rateLimitsByLimitId"] as? [String: Any] else { return [] }

        return buckets.compactMap { key, value -> ScopedGauge? in
            guard key != primaryID, let bucket = value as? [String: Any] else { return nil }
            guard let g = gauge(bucket["primary"]) else { return nil }
            let name = (bucket["limitName"] as? String)
                ?? (bucket["normalModelSlug"] as? String)
                ?? key
            return ScopedGauge(name: name, percent: g.percent, resetsAt: g.resetsAt)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Usage figures

    private static func stats(_ payload: CodexAppServer.Payload, window: Gauge?, now: Date) -> CodexStats? {
        var stats = CodexStats()

        if let summary = payload.usage?["summary"] as? [String: Any] {
            stats.lifetimeTokens = summary["lifetimeTokens"] as? Int ?? 0
            stats.peakDailyTokens = summary["peakDailyTokens"] as? Int ?? 0
            stats.currentStreakDays = summary["currentStreakDays"] as? Int ?? 0
            stats.longestStreakDays = summary["longestStreakDays"] as? Int ?? 0
        }

        if let buckets = payload.usage?["dailyUsageBuckets"] as? [[String: Any]] {
            stats.days = buckets.compactMap { bucket in
                guard
                    let day = localDay(bucket["startDate"] as? String),
                    let tokens = bucket["tokens"] as? Int
                else { return nil }
                return DayBucket(day: day, tokens: tokens)
            }
            .sorted { $0.day < $1.day }
        }

        if let window {
            let start = window.resetsAt.map { $0.addingTimeInterval(-(window.windowDuration ?? LimitWindow.session)) }
                ?? now.addingTimeInterval(-(window.windowDuration ?? LimitWindow.session))
            stats.windowTokens = stats.tokens(since: start)
        }

        let limits = payload.rateLimits["rateLimits"] as? [String: Any] ?? [:]

        // Backend-formatted strings, passed through untouched. Codex sends no currency
        // or exponent beside them, so reformatting would mean guessing both.
        if let credits = limits["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                stats.creditsBalance = "unlimited"
            } else if credits["hasCredits"] as? Bool == true {
                stats.creditsBalance = credits["balance"] as? String
            }
        }
        if let individual = limits["individualLimit"] as? [String: Any] {
            stats.spendUsed = individual["used"] as? String
            stats.spendLimit = individual["limit"] as? String
        }

        stats.blockedReason = blockedReason(payload.rateLimits, limits: limits)

        return stats.isEmpty && stats.blockedReason == nil ? nil : stats
    }

    /// Whether ordinary usage is currently refused, and why.
    ///
    /// Read, never inferred. The schema is explicit that a client must not take a
    /// percentage or a reset time as evidence of recovery, and this machine's own
    /// reading of 99% used with `ordinaryUsageAllowed: true` is exactly the case where
    /// guessing from the dial would have been wrong.
    private static func blockedReason(_ root: [String: Any], limits: [String: Any]) -> String? {
        let reached = limits["rateLimitReachedType"] as? String
        let spendControl = limits["spendControlReached"] as? Bool == true
        let refused = root["ordinaryUsageAllowed"] as? Bool == false

        guard refused || spendControl || reached != nil else { return nil }

        switch reached {
        case "rate_limit_reached": return "rate limit reached"
        case "workspace_owner_credits_depleted", "workspace_member_credits_depleted":
            return "credits depleted"
        case "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached":
            return "usage limit reached"
        default:
            return spendControl ? "spend limit reached" : "usage paused"
        }
    }

    // MARK: - Field parsing

    /// Codex sends reset times as whole seconds since the epoch, not as ISO strings.
    private static func epochSeconds(_ raw: Any?) -> Date? {
        // NSNumber rather than Int or Double: JSONSerialization decides which of the two
        // it hands back, and the field is declared int64.
        guard let seconds = (raw as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A daily bucket's `startDate` is a bare "2026-09-11" with no zone. Read in the
    /// local calendar, which is the one the sparkline and the window sum are drawn in.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func localDay(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return dayParser.date(from: raw)
    }

    // MARK: - Naming

    /// The plan enum as something worth printing on the card.
    private static func planName(_ raw: String?) -> String {
        switch raw {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            return "Business"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            return "Enterprise"
        case "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        case .some(let other) where !other.isEmpty && other != "unknown":
            // A plan added after this was written still deserves a legible label.
            return other.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return "—"
        }
    }
}
