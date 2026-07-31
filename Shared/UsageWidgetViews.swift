import SwiftUI

/// The three widget layouts.
///
/// These live in Shared rather than the widget target so they can be rendered outside
/// WidgetKit — by SwiftUI previews and by the snapshot harness in Tools/.
/// Every view takes its "now" explicitly: WidgetKit renders timeline entries ahead of
/// time, so reading the clock at draw time would freeze every countdown.

/// Small: a dial per account, with the weekly window as a line beneath.
struct UsageSmallView: View {
    var snapshot: UsageSnapshot
    var now: Date

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(2)) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(accounts) { account in
                VStack(spacing: 6) {
                    DialGauge(
                        percent: account.session?.percent ?? 0,
                        resetsAt: account.session?.resetsAt,
                        window: LimitWindow.session,
                        now: now,
                        size: accounts.count > 1 ? 64 : 116,
                        caption: "5H"
                    )
                    Text(account.label)
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(-0.1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    WeeklyLine(account: account, now: now, showsCountdown: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Medium: two large dials, one per account.
///
/// Side-by-side columns give each dial enough room for the graduated rim, which the
/// stacked-row alternative could not — and the rim is what makes the pace mark legible.
struct UsageMediumView: View {
    var snapshot: UsageSnapshot
    var now: Date

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(2)) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Hairline(axis: .vertical).padding(.vertical, 6) }

                VStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 12, weight: .bold))
                        .tracking(-0.2)
                        .lineLimit(1)

                    DialGauge(
                        percent: account.session?.percent ?? 0,
                        resetsAt: account.session?.resetsAt,
                        window: LimitWindow.session,
                        now: now,
                        size: 88,
                        caption: "5H"
                    )

                    WeeklyLine(account: account, now: now, showsCountdown: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Large: everything — per-model weekly limits and extra-usage spend included.
struct UsageLargeView: View {
    var snapshot: UsageSnapshot
    var now: Date

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(3)) }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Hairline() }

                HStack(spacing: 16) {
                    VStack(spacing: 6) {
                        DialGauge(
                            percent: account.session?.percent ?? 0,
                            resetsAt: account.session?.resetsAt,
                            window: LimitWindow.session,
                            now: now,
                            size: 112,
                            caption: "5H"
                        )
                        PaceCaption(account: account, now: now)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        AccountHeader(account: account, size: 14)
                        if let weekly = account.weekly {
                            MiniMeter(title: "Weekly", percent: weekly.percent,
                                      resetsAt: weekly.resetsAt, now: now)
                        }
                        ForEach(account.scoped.prefix(2)) { scoped in
                            MiniMeter(title: scoped.name, percent: scoped.percent,
                                      resetsAt: scoped.resetsAt, now: now)
                        }
                        Spacer(minLength: 0)
                        FooterLine(account: account, now: now)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Shared pieces

/// The weekly window as a single line, for layouts with no room for a meter.
private struct WeeklyLine: View {
    var account: AccountUsage
    var now: Date
    var showsCountdown: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let weekly = account.weekly {
            let isExpired = weekly.resetsAt.map { $0 <= now } ?? false
            HStack(spacing: 4) {
                Text("7D")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Dial.label(scheme))
                if isExpired {
                    Text("reset")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Dial.meta(scheme))
                } else {
                    Text("\(weekly.percent)%")
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Dial.arcEnds(at: Double(weekly.percent) / 100, scheme).tip)
                    if showsCountdown,
                       let reset = UsageFormat.countdown(to: weekly.resetsAt, from: now) {
                        Text(reset)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(Dial.meta(scheme))
                    }
                }
            }
            .lineLimit(1)
        }
    }
}

/// The pace reading — how the current burn compares to an even spend of the window.
/// Silent when there's nothing meaningful to say.
private struct PaceCaption: View {
    var account: AccountUsage
    var now: Date

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
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(pace.isAhead ? Dial.color(at: 0.85, scheme) : Dial.meta(scheme))
        }
    }
}

private struct FooterLine: View {
    var account: AccountUsage
    var now: Date

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if let spend = account.spend {
                Text(spend.usedText)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Dial.label(scheme))
                Text("extra")
                    .font(.system(size: 9))
                    .foregroundStyle(Dial.meta(scheme))
            }
            Spacer(minLength: 0)
            StalenessLabel(account: account, now: now)
        }
    }
}

/// Shown when the host app hasn't published a snapshot yet.
struct UsageNoDataView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Dial.label(scheme))
            Text("No data")
                .font(.system(size: 12, weight: .bold))
            Text("Open Claude Usage once")
                .font(.system(size: 10))
                .foregroundStyle(Dial.meta(scheme))
                .multilineTextAlignment(.center)
        }
        .padding(4)
    }
}
