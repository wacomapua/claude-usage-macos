import Foundation

/// One day of Codex activity.
struct DayBucket: Codable, Hashable {
    var day: Date
    var tokens: Int
}

/// What Codex is able to say about its own usage.
///
/// Deliberately **not** folded into `TokenStats`. That type is derived from Claude
/// Code's transcripts, which record every turn: it can therefore scope tokens to the
/// current window, split them by model, attribute them to a project and price them at
/// API list rates. Codex publishes none of that. `account/usage/read` returns whole-day
/// token totals and a handful of lifetime figures, and the local stores hold no per-turn
/// token counts at all: `thread_history_*.sqlite` records the items in a turn but not
/// what they cost, and the `sessions/*.jsonl` rollouts that used to carry usage stopped
/// being written.
///
/// So there is no honest way to fill in a five-hour token figure, a model mix or a
/// dollar value for Codex. Half-filling `TokenStats` would have made those zeroes look
/// like readings. This type only carries what Codex actually reports.
struct CodexStats: Codable, Hashable {
    var lifetimeTokens: Int = 0
    var peakDailyTokens: Int = 0
    var currentStreakDays: Int = 0
    var longestStreakDays: Int = 0
    /// Tokens inside the current primary rate-limit window, summed from whole days.
    /// Coarse by construction: a window that opened at noon still counts all of that
    /// morning, because the day is the finest grain Codex reports.
    var windowTokens: Int = 0
    /// Days with recorded usage, oldest first. Sparse: an idle day is absent, not zero.
    var days: [DayBucket] = []
    /// Backend-formatted credit balance, e.g. "$12.34". Passed through verbatim: Codex
    /// sends it as a string with no currency or exponent alongside it, so reformatting
    /// it here would mean guessing both.
    var creditsBalance: String? = nil
    /// Spend-control figures, also backend-formatted strings.
    var spendUsed: String? = nil
    var spendLimit: String? = nil
    /// Set when the backend says ordinary usage is currently refused, with the reason
    /// it gave. Percentages alone don't imply recovery, so this is read rather than
    /// inferred from the dial.
    var blockedReason: String? = nil

    var isEmpty: Bool { lifetimeTokens == 0 && days.isEmpty }

    /// Tokens recorded on or after the day `start` falls in.
    func tokens(since start: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: start)
        return days.filter { $0.day >= from }.reduce(0) { $0 + $1.tokens }
    }

    /// The sparse day list filled out to one point per day, so the sparkline's shape is
    /// proportional to time. Without the fill an idle fortnight would draw as a single
    /// short step instead of the flat run it actually was.
    ///
    /// Reuses `HourBucket` because the sparkline only reads `tokens`; the span is days
    /// here rather than hours, which is why the Codex card labels it.
    func sparkline(spanningDays span: Int, endingAt now: Date,
                   calendar: Calendar = .current) -> [HourBucket] {
        let byDay = Dictionary(days.map { (calendar.startOfDay(for: $0.day), $0.tokens) },
                               uniquingKeysWith: +)
        let today = calendar.startOfDay(for: now)
        return (0..<span).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return HourBucket(hour: day, tokens: byDay[day] ?? 0, cost: 0)
        }
    }
}

/// Compact token counts: "1.5B", "88.9M", "54.3K".
///
/// `TokenFormat.compact` tops out below the billions that Codex's lifetime figure
/// reaches, so this is its own thing rather than a change to a Claude-side formatter.
enum CodexFormat {
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(count)"
        }
    }
}
