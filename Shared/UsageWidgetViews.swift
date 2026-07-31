import SwiftUI

/// The three widget layouts.
///
/// These live in Shared rather than the widget target so they can be rendered outside
/// WidgetKit — by SwiftUI previews and by the snapshot harness in Tools/.
/// Every view takes its "now" explicitly: WidgetKit renders timeline entries ahead of
/// time, so reading the clock at draw time would freeze every countdown.

/// Small: a dial per account over its token and cost figures.
struct UsageSmallView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(2)) }

    private var blooms: [Bloom] {
        accounts.enumerated().map { index, account in
            let x = accounts.count > 1 ? (index == 0 ? 0.26 : 0.74) : 0.5
            return Bloom(percent: account.session?.percent ?? 0,
                         anchor: UnitPoint(x: x, y: 0.3), radius: 150)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(accounts) { account in
                VStack(spacing: 5) {
                    DialGauge(
                        percent: account.session?.percent ?? 0,
                        resetsAt: account.session?.resetsAt,
                        window: LimitWindow.session,
                        now: now,
                        size: accounts.count > 1 ? 62 : 116,
                        caption: "5H"
                    )
                    Text(account.label)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let stats = account.stats, !stats.isEmpty {
                        VStack(spacing: 0) {
                            Text(TokenFormat.compact(stats.sessionTokens))
                                .font(.system(size: 12, weight: .bold, design: .rounded)
                                    .monospacedDigit())
                            Text(TokenFormat.money(stats.sessionCost))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(Dial.meta(scheme))
                        }
                    } else {
                        WeeklyLine(account: account, now: now, showsCountdown: false)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .bloomBackdrop(blooms)
    }
}

/// Medium: two dials with the session's token spend and burn history.
struct UsageMediumView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(2)) }

    private var blooms: [Bloom] {
        accounts.enumerated().map { index, account in
            let x = accounts.count > 1 ? (index == 0 ? 0.15 : 0.65) : 0.2
            return Bloom(percent: account.session?.percent ?? 0,
                         anchor: UnitPoint(x: x, y: 0.55), radius: 190)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Hairline(axis: .vertical).padding(.vertical, 4) }

                VStack(alignment: .leading, spacing: 6) {
                    AccountHeader(account: account, size: 11.5)

                    HStack(spacing: 10) {
                        DialGauge(
                            percent: account.session?.percent ?? 0,
                            resetsAt: account.session?.resetsAt,
                            window: LimitWindow.session,
                            now: now,
                            size: 68,
                            caption: "5H"
                        )
                        VStack(alignment: .leading, spacing: 7) {
                            StatReadout(
                                label: "Tokens",
                                value: TokenFormat.compact(account.stats?.sessionTokens ?? 0),
                                caption: "5h",
                                size: 14
                            )
                            StatReadout(
                                label: "Value",
                                value: TokenFormat.money(account.stats?.sessionCost ?? 0),
                                caption: "api",
                                tint: Dial.color(at: 0.5, scheme),
                                size: 14
                            )
                        }
                    }

                    if let stats = account.stats, !stats.isEmpty {
                        BurnSparkline(buckets: stats.buckets, height: 18)
                    }

                    WeeklyLine(account: account, now: now, showsCountdown: true)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .bloomBackdrop(blooms)
    }
}

/// Large: the full instrument panel — limits, spend, burn history and model mix.
struct UsageLargeView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { Array(snapshot.accounts.prefix(2)) }

    private var blooms: [Bloom] {
        accounts.enumerated().map { index, account in
            let y = accounts.count > 1 ? (index == 0 ? 0.24 : 0.76) : 0.5
            return Bloom(percent: account.session?.percent ?? 0,
                         anchor: UnitPoint(x: 0.16, y: y), radius: 260)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Hairline() }

                HStack(alignment: .top, spacing: 14) {
                    // The left column is the readout — dial then figures, kept large.
                    // The qualifiers ride one horizontal line on the right.
                    VStack(spacing: 7) {
                        DialGauge(
                            percent: account.session?.percent ?? 0,
                            resetsAt: account.session?.resetsAt,
                            window: LimitWindow.session,
                            now: now,
                            size: 86,
                            caption: "5H"
                        )

                        StatReadout(
                            label: "Tokens 5h",
                            value: TokenFormat.compact(account.stats?.sessionTokens ?? 0),
                            size: 16,
                            alignment: .center
                        )
                        StatReadout(
                            label: "Value 5h",
                            value: TokenFormat.money(account.stats?.sessionCost ?? 0),
                            caption: "api",
                            tint: Dial.color(at: 0.5, scheme),
                            size: 16,
                            alignment: .center
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(width: 112)

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            AccountHeader(account: account, size: 13)
                            StalenessLabel(account: account, now: now)
                        }

                        QualifierRow(account: account, now: now, showsPace: false)

                        if let weekly = account.weekly {
                            MiniMeter(title: "Weekly", percent: weekly.percent,
                                      resetsAt: weekly.resetsAt, now: now)
                        }

                        if let stats = account.stats, !stats.isEmpty {
                            BurnSparkline(buckets: stats.buckets, height: 20)
                            ModelMixBar(models: stats.models)
                        }

                        Spacer(minLength: 0)
                        WeekFooter(account: account)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .bloomBackdrop(blooms)
    }
}

// MARK: - Shared pieces

/// The week in one line: turns taken, what they'd have cost on the API, and the
/// project that consumed the most. All three come from the transcripts.
private struct WeekFooter: View {
    var account: AccountUsage

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let stats = account.stats, !stats.isEmpty {
            HStack(spacing: 5) {
                Text("\(stats.messageCount)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Dial.label(scheme))
                Text("turns")
                    .font(.system(size: 9))
                    .foregroundStyle(Dial.meta(scheme))

                Text(TokenFormat.money(stats.weekCost))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Dial.label(scheme))
                Text("wk")
                    .font(.system(size: 9))
                    .foregroundStyle(Dial.meta(scheme))

                if let project = stats.topProject {
                    Text(project)
                        .font(.system(size: 9))
                        .foregroundStyle(Dial.meta(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

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
/// The three qualifiers on one line — they're all short, and stacking them wastes a
/// column that the big figures use better.
struct QualifierRow: View {
    var account: AccountUsage
    var now: Date
    /// The widget has ~230pt for this row, which all three chips overflow. The
    /// dial's own reference arc already shows pace, so that's the one to drop.
    var showsPace: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if showsPace { PaceCaption(account: account, now: now) }
            ProjectionBadge(account: account, now: now)
            DeltaChip(stats: account.stats)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// Shared with the app window, so it can't be file-private.
struct PaceCaption: View {
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
