import SwiftUI

/// The three widget layouts.
///
/// These live in Shared rather than the widget target so they can be rendered outside
/// WidgetKit — by SwiftUI previews and by the snapshot harness in Tools/.
/// Every view takes its "now" explicitly: WidgetKit renders timeline entries ahead of
/// time, so reading the clock at draw time would freeze every countdown.

/// Small: a dial per account, weekly folded into the inner ring.
struct UsageSmallView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(2)) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(accounts) { account in
                VStack(spacing: 5) {
                    DialGauge(
                        percent: account.session?.percent ?? 0,
                        resetsAt: account.session?.resetsAt,
                        window: LimitWindow.session,
                        now: now,
                        size: accounts.count > 1 ? 56 : 104,
                        caption: "5H",
                        innerPercent: account.weekly?.percent,
                        innerResetsAt: account.weekly?.resetsAt
                    )
                    Text(account.label)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    // The inner ring shows the weekly window's shape; this gives it a
                    // number, since a thin arc alone can't be read to a percent.
                    if let weekly = account.weekly {
                        HStack(spacing: 3) {
                            Text("7D")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(Dial.label(scheme))
                            Text("\(weekly.percent)%")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded)
                                    .monospacedDigit())
                                .foregroundStyle(
                                    weekly.resetsAt.map { $0 <= now } ?? false
                                        ? Dial.idle(scheme)
                                        : Dial.color(at: Double(weekly.percent) / 100, scheme)
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Medium: one full-width row per account.
///
/// Side-by-side columns would give each account barely 60pt of text width, which wraps
/// "WEEKLY" onto three lines. A row per account spends the widget's width where the
/// labels need it and keeps the dial dominant.
struct UsageMediumView: View {
    var snapshot: UsageSnapshot
    var now: Date

    var body: some View {
        VStack(spacing: 8) {
            ForEach(snapshot.accounts.prefix(2)) { account in
                HStack(spacing: 12) {
                    DialGauge(
                        percent: account.session?.percent ?? 0,
                        resetsAt: account.session?.resetsAt,
                        window: LimitWindow.session,
                        now: now,
                        size: 58,
                        caption: "5H"
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            AccountHeader(account: account, size: 12)
                            StalenessLabel(account: account, now: now)
                        }
                        if let weekly = account.weekly {
                            MiniMeter(title: "Weekly", percent: weekly.percent,
                                      resetsAt: weekly.resetsAt, now: now)
                        }
                        PaceCaption(account: account, now: now, includeReset: true)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .panel()
            }
        }
    }
}

/// Large: everything — per-model weekly limits and extra-usage spend included.
struct UsageLargeView: View {
    var snapshot: UsageSnapshot
    var now: Date

    var body: some View {
        VStack(spacing: 10) {
            ForEach(snapshot.accounts.prefix(3)) { account in
                HStack(spacing: 14) {
                    VStack(spacing: 5) {
                        DialGauge(
                            percent: account.session?.percent ?? 0,
                            resetsAt: account.session?.resetsAt,
                            window: LimitWindow.session,
                            now: now,
                            size: 104,
                            caption: "5H"
                        )
                        PaceCaption(account: account, now: now)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        AccountHeader(account: account, size: 13)
                        if let weekly = account.weekly {
                            MiniMeter(title: "Weekly", percent: weekly.percent,
                                      resetsAt: weekly.resetsAt, now: now)
                        }
                        ForEach(account.scoped.prefix(2)) { scoped in
                            MiniMeter(title: scoped.name, percent: scoped.percent,
                                      resetsAt: scoped.resetsAt, now: now)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 5) {
                            if let spend = account.spend {
                                Text(spend.usedText)
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("extra")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            StalenessLabel(account: account, now: now)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .panel()
            }
        }
    }
}

/// The pace reading — how the current burn compares to an even spend of the window.
/// Silent when there's nothing meaningful to say.
private struct PaceCaption: View {
    var account: AccountUsage
    var now: Date
    /// Medium is too tight for a countdown inside the dial, so it rides along here.
    var includeReset: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let pace = Pace(percent: account.session?.percent ?? 0,
                           resetsAt: account.session?.resetsAt,
                           window: LimitWindow.session,
                           now: now) {
            HStack(spacing: 3) {
                Image(systemName: pace.symbol)
                    .font(.system(size: 7, weight: .bold))
                Text(pace.caption)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                if includeReset,
                   let left = UsageFormat.countdown(to: account.session?.resetsAt, from: now) {
                    Text("· \(left)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Dial.meta(scheme))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(pace.isAhead ? Dial.color(at: 0.85, scheme) : Dial.label(scheme))
        }
    }
}

/// Shown when the host app hasn't published a snapshot yet.
struct UsageNoDataView: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No data")
                .font(.system(size: 12, weight: .semibold))
            Text("Open Claude Usage once")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(4)
    }
}
