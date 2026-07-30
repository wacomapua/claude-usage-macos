import SwiftUI

/// Shared visual language between the app window and the widget, so the two never drift.
enum UsageStyle {
    /// Colour a bar by how much headroom is left, not by which bar it is.
    static func tint(for percent: Int) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<80: return .yellow
        case ..<95: return .orange
        default: return .red
        }
    }
}

/// A labelled progress bar: "Session ▓▓▓░░░░ 17%  4h".
struct UsageBar: View {
    var title: String
    var percent: Int
    var resetsAt: Date?
    var compact: Bool = false
    /// WidgetKit renders each timeline entry ahead of time, so "now" has to come from
    /// the entry rather than from `Date()` at draw time — otherwise countdowns freeze.
    var now: Date = Date()

    /// The cached window already rolled over, so the percentage we hold is history —
    /// the real current figure is unknown until Claude Code refreshes its cache.
    private var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    private var tint: Color { isExpired ? .gray : UsageStyle.tint(for: percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(compact ? .system(size: 9, weight: .medium) : .caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(percent)%")
                    .font(compact ? .system(size: 9, weight: .semibold).monospacedDigit()
                                  : .caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isExpired ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                if isExpired {
                    // Don't imply the stale number still stands.
                    Text("reset")
                        .font(compact ? .system(size: 9) : .caption2)
                        .foregroundStyle(.tertiary)
                } else if let reset = UsageFormat.countdown(to: resetsAt, from: now) {
                    Text(reset)
                        .font(compact ? .system(size: 9).monospacedDigit()
                                      : .caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Capsule()
                .fill(.quaternary)
                .frame(height: compact ? 3 : 5)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(tint)
                            .opacity(isExpired ? 0.35 : 1)
                            // Clamp: the server can report >100% once a limit is blown.
                            .frame(width: geo.size.width * min(1, max(0, Double(percent) / 100)))
                    }
                }
                .clipShape(.capsule)
        }
    }
}

/// The "as of 2d ago" marker. Cached numbers only refresh while Claude Code is running.
struct StalenessLabel: View {
    var account: AccountUsage
    var now: Date = Date()

    private var isStale: Bool {
        guard let fetchedAt = account.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > 45 * 60
    }

    var body: some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 8))
            }
            Text("as of \(UsageFormat.age(of: account.fetchedAt, from: now))")
                .font(.system(size: 9))
        }
        .foregroundStyle(isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
    }
}
