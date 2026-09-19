import Foundation

/// Which CLI an account belongs to.
///
/// The two agents publish their numbers in completely different ways. Claude Code
/// caches them in a JSON file on disk; Codex only answers over a local JSON-RPC server.
/// Once read they describe the same thing, so they share one model and one set of
/// views. What they do *not* share is the finer detail underneath: see `CodexStats`.
enum Provider: String, Codable, Hashable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// How long each kind of limit window runs for.
///
/// Claude Code's payload never states its window lengths; they're implied by the field
/// names `five_hour` and `seven_day`, so they're spelled out here. Codex *does* state
/// its own, and those travel on the gauge itself, because they vary by plan: a free
/// account is metered over 30 days where a paid one is metered over 5 hours.
enum LimitWindow {
    static let session: TimeInterval = 5 * 60 * 60
    static let weekly: TimeInterval = 7 * 24 * 60 * 60
}

/// One rate-limit bar (a 5-hour session window, a weekly window, ...).
struct Gauge: Codable, Hashable {
    var percent: Int
    var resetsAt: Date?
    /// How long this window runs, when the source says so. Claude leaves it nil and the
    /// constants above apply; Codex reports `windowDurationMins` and it must be honoured,
    /// because the pace marker and the projection are both derived from it.
    var windowDuration: TimeInterval? = nil
}

/// A weekly limit scoped to a particular model, e.g. "Opus" or "Fable".
struct ScopedGauge: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var percent: Int
    var resetsAt: Date?
}

/// Extra-usage / overage spend, when the account has it enabled.
struct Spend: Codable, Hashable {
    var usedMinor: Int
    var limitMinor: Int?
    var currency: String
    var exponent: Int
    var enabled: Bool

    private func money(_ minor: Int) -> String {
        let value = Double(minor) / pow(10.0, Double(exponent))
        let fmt = NumberFormatter()
        // Spell out the code when it isn't the local currency, so "$" is never ambiguous.
        let isLocalCurrency = Locale.current.currency?.identifier == currency
        fmt.numberStyle = isLocalCurrency ? .currency : .currencyISOCode
        fmt.currencyCode = currency
        fmt.maximumFractionDigits = exponent
        return fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    var usedText: String { money(usedMinor) }
    var limitText: String? { limitMinor.map(money) }
}

/// Everything we know about one account, of either provider.
struct AccountUsage: Codable, Hashable, Identifiable {
    /// Stable identifier, also used as the snapshot key. A Claude account uses its
    /// config directory name, e.g. ".claude-personal"; Codex uses "codex".
    var id: String
    /// Short display name, e.g. "Personal".
    var label: String
    var email: String
    /// Human-readable plan, e.g. "Max 5×", "Team", "Plus".
    var plan: String
    /// When these numbers were last refreshed from the server.
    var fetchedAt: Date?
    /// The shorter, faster-moving window. Five hours on Claude; on Codex, whatever
    /// `session.windowDuration` says.
    var session: Gauge?
    var weekly: Gauge?
    var scoped: [ScopedGauge]
    var spend: Spend?
    /// Derived from the transcripts rather than the usage cache — see TokenStats.
    /// Claude only: Codex records no per-turn token counts anywhere on disk.
    var stats: TokenStats? = nil
    /// Directory holding this account's `projects/`. Differs from the config file's
    /// location on a default install, so it can't be inferred from `id`.
    var dataDirPath: String? = nil
    /// True when these figures came from the API rather than the on-disk cache.
    /// Always true for Codex, which has no cache to fall back to.
    var isLive: Bool = false
    var provider: Provider = .claude
    /// The Codex-side counterpart to `stats`. Far thinner, and deliberately a separate
    /// type rather than a half-filled `TokenStats`. See `CodexStats`.
    var codex: CodexStats? = nil

    /// How long the primary window runs. The dial, its pace marker and the projection
    /// all key off this, so a 30-day Codex window can't be drawn as though it were five
    /// hours old.
    var primaryWindow: TimeInterval {
        session?.windowDuration ?? LimitWindow.session
    }

    /// The dial's face caption: "5H", "7D", "30D".
    var primaryCaption: String {
        UsageFormat.windowCaption(primaryWindow)
    }

    /// When the current primary window opened, worked back from its reset time.
    /// Used to scope token totals to the same window the dial is showing.
    func sessionWindowStart(now: Date) -> Date {
        let window = primaryWindow
        guard let resetsAt = session?.resetsAt, resetsAt > now else {
            return now.addingTimeInterval(-window)
        }
        return resetsAt.addingTimeInterval(-window)
    }

    /// The worst percentage across the account's still-current bars — what we surface at
    /// a glance. A window that has already rolled over is skipped rather than counted,
    /// so an old session figure can't dominate the headline forever.
    func headlinePercent(at now: Date) -> Int {
        [session, weekly]
            .compactMap { $0 }
            .filter { gauge in gauge.resetsAt.map { $0 > now } ?? true }
            .map(\.percent)
            .max() ?? 0
    }

    /// Cached numbers go stale when an account sits idle. Anything past this deserves a marker.
    var isStale: Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > 45 * 60
    }

    enum CodingKeys: String, CodingKey {
        case id, label, email, plan, fetchedAt, session, weekly, scoped, spend
        case stats, dataDirPath, isLive, provider, codex
    }
}

extension AccountUsage {
    /// Decoded by hand so an older or newer snapshot still loads.
    ///
    /// Swift's synthesised initialiser treats a missing key as an error even when the
    /// property carries a default, and the snapshot on disk is now the only copy of the
    /// Codex figures between launches, since Codex has no cache of its own to rebuild
    /// from. Losing the whole file to one added field would blank the widget until the next
    /// successful fetch. Declared in an extension so the memberwise initialiser survives.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? "unknown account"
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? "—"
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        session = try c.decodeIfPresent(Gauge.self, forKey: .session)
        weekly = try c.decodeIfPresent(Gauge.self, forKey: .weekly)
        scoped = try c.decodeIfPresent([ScopedGauge].self, forKey: .scoped) ?? []
        spend = try c.decodeIfPresent(Spend.self, forKey: .spend)
        stats = try c.decodeIfPresent(TokenStats.self, forKey: .stats)
        dataDirPath = try c.decodeIfPresent(String.self, forKey: .dataDirPath)
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        codex = try c.decodeIfPresent(CodexStats.self, forKey: .codex)
    }
}

struct UsageSnapshot: Codable {
    var accounts: [AccountUsage]
    var generatedAt: Date

    static let empty = UsageSnapshot(accounts: [], generatedAt: .distantPast)

    /// The accounts a space-constrained widget should show, busiest first.
    ///
    /// Small and medium have room for two, and there can now be three or more: two
    /// Claude accounts plus Codex. Ranking by current pressure rather than by discovery
    /// order is what keeps the one that's about to run out on screen; a fixed order
    /// would hide Codex behind the Claude accounts permanently.
    func busiest(_ count: Int, at now: Date) -> [AccountUsage] {
        accounts
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.headlinePercent(at: now)
                let r = rhs.element.headlinePercent(at: now)
                // Discovery order breaks ties, so a quiet day doesn't reshuffle the
                // widget every time two accounts sit level.
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .prefix(count)
            .map(\.element)
    }

    /// Sample data so the widget gallery and SwiftUI previews have something to draw.
    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            accounts: [
                AccountUsage(
                    id: ".claude-personal", label: "Personal", email: "you@example.com",
                    plan: "Max 5×", fetchedAt: Date(),
                    session: Gauge(percent: 17, resetsAt: Date().addingTimeInterval(3600 * 4)),
                    weekly: Gauge(percent: 15, resetsAt: Date().addingTimeInterval(3600 * 50)),
                    scoped: [ScopedGauge(name: "Opus", percent: 3, resetsAt: nil)],
                    spend: nil
                ),
                AccountUsage(
                    id: ".claude-work", label: "Work", email: "you@company.com",
                    plan: "Team", fetchedAt: Date(),
                    session: Gauge(percent: 62, resetsAt: Date().addingTimeInterval(3600 * 2)),
                    weekly: Gauge(percent: 41, resetsAt: Date().addingTimeInterval(3600 * 120)),
                    scoped: [],
                    spend: Spend(usedMinor: 4655, limitMinor: nil, currency: "AUD", exponent: 2, enabled: true)
                ),
                AccountUsage(
                    id: "codex", label: "Codex", email: "you@example.com",
                    plan: "Plus", fetchedAt: Date(),
                    session: Gauge(percent: 74, resetsAt: Date().addingTimeInterval(3600 * 3),
                                   windowDuration: LimitWindow.session),
                    weekly: Gauge(percent: 38, resetsAt: Date().addingTimeInterval(3600 * 90),
                                  windowDuration: LimitWindow.weekly),
                    scoped: [],
                    spend: nil,
                    isLive: true,
                    provider: .codex,
                    codex: CodexStats(
                        lifetimeTokens: 1_524_159_434,
                        peakDailyTokens: 88_967_039,
                        currentStreakDays: 4,
                        longestStreakDays: 57,
                        windowTokens: 12_400_000,
                        days: []
                    )
                ),
            ],
            generatedAt: Date()
        )
    }
}

// MARK: - Presentation helpers

enum UsageFormat {
    /// "4h 12m", "3d", "now" — compact enough for a widget row.
    static func countdown(to date: Date?, from now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "due" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rem = minutes % 60
            return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
        }
        let days = hours / 24
        let rem = hours % 24
        return rem == 0 ? "\(days)d" : "\(days)d \(rem)h"
    }

    /// "12m ago", "2d ago" — used for the staleness marker.
    static func age(of date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// A window length as a dial caption: "5H", "7D", "30D".
    ///
    /// Only ever a label, so it rounds to the coarsest unit that divides exactly and
    /// falls back to minutes rather than inventing a fractional day.
    static func windowCaption(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }
}
