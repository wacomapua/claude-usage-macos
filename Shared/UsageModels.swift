import Foundation

/// How long each kind of limit window runs for. Needed to work out how far through a
/// window you are, which is what the dial's pace marker is derived from.
enum LimitWindow {
    static let session: TimeInterval = 5 * 60 * 60
    static let weekly: TimeInterval = 7 * 24 * 60 * 60
}

/// One rate-limit bar (a 5-hour session window, a weekly window, ...).
struct Gauge: Codable, Hashable {
    var percent: Int
    var resetsAt: Date?
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

/// Everything we know about one Claude account.
struct AccountUsage: Codable, Hashable, Identifiable {
    /// Stable id — the config directory name, e.g. ".claude-personal".
    var id: String
    /// Short display name, e.g. "Personal".
    var label: String
    var email: String
    /// Human-readable plan, e.g. "Max 5×" or "Team".
    var plan: String
    /// When Claude Code last refreshed these numbers from the server.
    var fetchedAt: Date?
    var session: Gauge?
    var weekly: Gauge?
    var scoped: [ScopedGauge]
    var spend: Spend?
    /// Derived from the transcripts rather than the usage cache — see TokenStats.
    /// Defaulted so adding it didn't break every existing construction site.
    var stats: TokenStats? = nil
    /// Directory holding this account's `projects/`. Differs from the config file's
    /// location on a default install, so it can't be inferred from `id`.
    var dataDirPath: String? = nil
    /// True when these figures came from the API rather than the on-disk cache.
    var isLive: Bool = false

    /// When the current 5-hour window opened, worked back from its reset time.
    /// Used to scope token totals to the same window the dial is showing.
    func sessionWindowStart(now: Date) -> Date {
        guard let resetsAt = session?.resetsAt, resetsAt > now else {
            return now.addingTimeInterval(-LimitWindow.session)
        }
        return resetsAt.addingTimeInterval(-LimitWindow.session)
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
}

struct UsageSnapshot: Codable {
    var accounts: [AccountUsage]
    var generatedAt: Date

    static let empty = UsageSnapshot(accounts: [], generatedAt: .distantPast)

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
}
