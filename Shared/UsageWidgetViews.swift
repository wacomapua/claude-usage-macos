import SwiftUI

/// The three widget layouts.
///
/// These live in Shared rather than the widget target so they can be rendered outside
/// WidgetKit — by SwiftUI previews and by the snapshot harness in Tools/.
/// Every view takes its "now" explicitly: WidgetKit renders timeline entries ahead of
/// time, so reading the clock at draw time would freeze every countdown.
///
/// There can now be more accounts than any size has room for, namely two Claude accounts
/// plus Codex, so each size takes the *busiest* few rather than the first few. A fixed
/// order would have pinned Codex behind the Claude accounts permanently.

/// Small: a dial per account over its headline figures.
struct UsageSmallView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { snapshot.busiest(2, at: now) }

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
                        window: account.primaryWindow,
                        now: now,
                        size: accounts.count > 1 ? 62 : 116,
                        caption: account.primaryCaption
                    )
                    Text(account.label)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if account.provider == .codex {
                        if let codex = account.codex, !codex.isEmpty {
                            VStack(spacing: 0) {
                                Text(CodexFormat.tokens(codex.windowTokens))
                                    .font(.system(size: 12, weight: .bold, design: .rounded)
                                        .monospacedDigit())
                                Text("this \(account.primaryCaption.lowercased())")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Dial.meta(scheme))
                            }
                        } else {
                            SecondaryLine(account: account, now: now, showsCountdown: false)
                        }
                    } else if let stats = account.stats, !stats.isEmpty {
                        VStack(spacing: 0) {
                            Text(TokenFormat.compact(stats.sessionTokens))
                                .font(.system(size: 12, weight: .bold, design: .rounded)
                                    .monospacedDigit())
                            Text(TokenFormat.money(stats.sessionCost))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(Dial.meta(scheme))
                        }
                    } else {
                        SecondaryLine(account: account, now: now, showsCountdown: false)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .bloomBackdrop(blooms)
    }
}

/// Medium: two dials with the window's token spend and burn history.
struct UsageMediumView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { snapshot.busiest(2, at: now) }

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
                            window: account.primaryWindow,
                            now: now,
                            size: 68,
                            caption: account.primaryCaption
                        )
                        VStack(alignment: .leading, spacing: 7) {
                            if account.provider == .codex {
                                StatReadout(
                                    label: "Tokens",
                                    value: CodexFormat.tokens(account.codex?.windowTokens ?? 0),
                                    caption: account.primaryCaption.lowercased(),
                                    size: 14
                                )
                                StatReadout(
                                    label: "Lifetime",
                                    value: CodexFormat.tokens(account.codex?.lifetimeTokens ?? 0),
                                    size: 14
                                )
                            } else {
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
                    }

                    BurnHistory(account: account, now: now, height: 18)
                    SecondaryLine(account: account, now: now, showsCountdown: true)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .bloomBackdrop(blooms)
    }
}

/// Large: the full instrument panel — limits, spend, burn history and model mix.
///
/// Fits three accounts, which is what makes Codex visible alongside two Claude ones.
/// The third row is bought by shrinking the dial and dropping the detail strips, so a
/// two-account machine loses nothing.
struct UsageLargeView: View {
    var snapshot: UsageSnapshot
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var accounts: [AccountUsage] { snapshot.busiest(3, at: now) }
    private var isCrowded: Bool { accounts.count > 2 }

    private var blooms: [Bloom] {
        accounts.enumerated().map { index, account in
            let step = 1.0 / Double(max(1, accounts.count))
            let y = accounts.count > 1 ? step * (Double(index) + 0.5) : 0.5
            return Bloom(percent: account.session?.percent ?? 0,
                         anchor: UnitPoint(x: 0.16, y: y), radius: isCrowded ? 200 : 260)
        }
    }

    var body: some View {
        VStack(spacing: isCrowded ? 8 : 12) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Hairline() }
                LargeAccountRow(account: account, now: now, isCrowded: isCrowded)
            }
        }
        .bloomBackdrop(blooms)
    }
}

private struct LargeAccountRow: View {
    var account: AccountUsage
    var now: Date
    var isCrowded: Bool

    @Environment(\.colorScheme) private var scheme

    private var dialSize: CGFloat { isCrowded ? 62 : 86 }
    private var columnWidth: CGFloat { isCrowded ? 84 : 112 }
    private var figureSize: CGFloat { isCrowded ? 13 : 16 }

    var body: some View {
        HStack(alignment: .top, spacing: isCrowded ? 11 : 14) {
            // The left column is the readout — dial then figures, kept large.
            // The qualifiers ride one horizontal line on the right.
            VStack(spacing: isCrowded ? 5 : 7) {
                DialGauge(
                    percent: account.session?.percent ?? 0,
                    resetsAt: account.session?.resetsAt,
                    window: account.primaryWindow,
                    now: now,
                    size: dialSize,
                    caption: account.primaryCaption
                )

                if account.provider == .codex {
                    StatReadout(
                        label: "Tokens \(account.primaryCaption.lowercased())",
                        value: CodexFormat.tokens(account.codex?.windowTokens ?? 0),
                        size: figureSize,
                        alignment: .center
                    )
                    if !isCrowded {
                        StatReadout(
                            label: "Lifetime",
                            value: CodexFormat.tokens(account.codex?.lifetimeTokens ?? 0),
                            size: figureSize,
                            alignment: .center
                        )
                    }
                } else {
                    StatReadout(
                        label: "Tokens 5h",
                        value: TokenFormat.compact(account.stats?.sessionTokens ?? 0),
                        size: figureSize,
                        alignment: .center
                    )
                    if !isCrowded {
                        StatReadout(
                            label: "Value 5h",
                            value: TokenFormat.money(account.stats?.sessionCost ?? 0),
                            caption: "api",
                            tint: Dial.color(at: 0.5, scheme),
                            size: figureSize,
                            alignment: .center
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: columnWidth)

            VStack(alignment: .leading, spacing: isCrowded ? 6 : 9) {
                HStack(spacing: 6) {
                    AccountHeader(account: account, size: isCrowded ? 12 : 13)
                    StalenessLabel(account: account, now: now)
                }

                QualifierRow(account: account, now: now, showsPace: false)

                if let weekly = account.weekly {
                    MiniMeter(title: UsageFormat.windowCaption(weekly.windowDuration ?? LimitWindow.weekly),
                              percent: weekly.percent,
                              resetsAt: weekly.resetsAt, now: now)
                }

                // The curve stays even when crowded. On a Codex row it's often the only
                // thing in the right column, because a free plan has no second window and
                // no per-model buckets, so dropping it would leave the row half empty.
                BurnHistory(account: account, now: now,
                            height: isCrowded ? 14 : 20, showsSpan: !isCrowded)
                if !isCrowded, account.provider != .codex, let stats = account.stats, !stats.isEmpty {
                    ModelMixBar(models: stats.models)
                }

                Spacer(minLength: 0)
                RowFooter(account: account)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Shared pieces

/// The recent past as a burn curve, from whichever source the account has.
///
/// Claude's points are hours, from the transcripts. Codex's are days, the finest grain
/// it publishes, so the span is labelled rather than left to be misread as the same
/// ~24 hours the Claude curve covers.
struct BurnHistory: View {
    var account: AccountUsage
    var now: Date
    var height: CGFloat
    /// Whether to caption the span. Off in the tightest layouts, where the row can't
    /// spare the line.
    var showsSpan: Bool = true

    @Environment(\.colorScheme) private var scheme

    /// A month reads as a shape at widget widths; a year is a smear.
    private let codexDays = 30

    var body: some View {
        if account.provider == .codex {
            if let codex = account.codex, !codex.days.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    BurnSparkline(buckets: codex.sparkline(spanningDays: codexDays, endingAt: now),
                                  height: height)
                    if showsSpan {
                        Text("\(codexDays) days")
                            .font(.system(size: 8))
                            .foregroundStyle(Dial.meta(scheme))
                    }
                }
            }
        } else if let stats = account.stats, !stats.isEmpty {
            BurnSparkline(buckets: stats.buckets, height: height)
        }
    }
}

/// The one-line footer under an account: what it did, in its own terms.
private struct RowFooter: View {
    var account: AccountUsage

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if account.provider == .codex {
            if let codex = account.codex {
                HStack(spacing: 5) {
                    if let blocked = codex.blockedReason {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 8))
                        Text(blocked)
                            .font(.system(size: 9, weight: .semibold))
                    } else {
                        if codex.currentStreakDays > 0 {
                            Text("\(codex.currentStreakDays)")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Dial.label(scheme))
                            Text("day streak")
                                .font(.system(size: 9))
                                .foregroundStyle(Dial.meta(scheme))
                        }
                        if let credits = codex.creditsBalance {
                            Text(credits)
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Dial.label(scheme))
                            Text("credits")
                                .font(.system(size: 9))
                                .foregroundStyle(Dial.meta(scheme))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .foregroundStyle(codex.blockedReason == nil ? Color.primary : Dial.color(at: 0.95, scheme))
            }
        } else if let stats = account.stats, !stats.isEmpty {
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

/// The longer window as a single line, for layouts with no room for a meter.
/// Captioned from the window's own length, because Codex's second bucket isn't
/// necessarily seven days.
private struct SecondaryLine: View {
    var account: AccountUsage
    var now: Date
    var showsCountdown: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let weekly = account.weekly {
            let isExpired = weekly.resetsAt.map { $0 <= now } ?? false
            HStack(spacing: 4) {
                Text(UsageFormat.windowCaption(weekly.windowDuration ?? LimitWindow.weekly))
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
            // Day-over-day is a transcript figure. Codex reports whole days only, so
            // "today vs the same time yesterday" can't be computed like for like.
            if account.provider != .codex { DeltaChip(stats: account.stats) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// The pace reading — how the current burn compares to an even spend of the window.
/// Silent when there's nothing meaningful to say.
/// Shared with the app window, so it can't be file-private.
struct PaceCaption: View {
    var account: AccountUsage
    var now: Date

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let pace = Pace(percent: account.session?.percent ?? 0,
                           resetsAt: account.session?.resetsAt,
                           window: account.primaryWindow,
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
