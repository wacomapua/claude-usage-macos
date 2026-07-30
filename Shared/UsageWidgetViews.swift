import SwiftUI

/// The three widget layouts.
///
/// These live in Shared rather than the widget target so they can be rendered outside
/// WidgetKit — by SwiftUI previews and by the snapshot harness in Tools/.
/// Every view takes its "now" explicitly: WidgetKit renders timeline entries ahead of
/// time, so reading the clock at draw time would freeze all the countdowns.

/// Small: headline number per account plus hairline bars.
struct UsageSmallView: View {
    var snapshot: UsageSnapshot
    var now: Date

    init(snapshot: UsageSnapshot, now: Date) {
        self.snapshot = snapshot
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.accounts.prefix(3)) { account in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(account.label)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(account.headlinePercent(at: now))%")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(UsageStyle.tint(for: account.headlinePercent(at: now)))
                    }
                    if let session = account.session {
                        UsageBar(title: "5h", percent: session.percent,
                                 resetsAt: session.resetsAt, compact: true, now: now)
                    }
                    if let weekly = account.weekly {
                        UsageBar(title: "7d", percent: weekly.percent,
                                 resetsAt: weekly.resetsAt, compact: true, now: now)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Medium: one column per account with full-size bars.
struct UsageMediumView: View {
    var snapshot: UsageSnapshot
    var now: Date

    init(snapshot: UsageSnapshot, now: Date) {
        self.snapshot = snapshot
        self.now = now
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(snapshot.accounts.prefix(2)) { account in
                VStack(alignment: .leading, spacing: 6) {
                    AccountHeader(account: account)
                    if let session = account.session {
                        UsageBar(title: "Session", percent: session.percent,
                                 resetsAt: session.resetsAt, now: now)
                    }
                    if let weekly = account.weekly {
                        UsageBar(title: "Weekly", percent: weekly.percent,
                                 resetsAt: weekly.resetsAt, now: now)
                    }
                    Spacer(minLength: 0)
                    StalenessLabel(account: account, now: now)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Large: everything — per-model weekly limits and overage spend included.
struct UsageLargeView: View {
    var snapshot: UsageSnapshot
    var now: Date

    init(snapshot: UsageSnapshot, now: Date) {
        self.snapshot = snapshot
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(snapshot.accounts.prefix(3)) { account in
                VStack(alignment: .leading, spacing: 6) {
                    AccountHeader(account: account)
                    if let session = account.session {
                        UsageBar(title: "Session (5h)", percent: session.percent,
                                 resetsAt: session.resetsAt, now: now)
                    }
                    if let weekly = account.weekly {
                        UsageBar(title: "Weekly", percent: weekly.percent,
                                 resetsAt: weekly.resetsAt, now: now)
                    }
                    ForEach(account.scoped.prefix(2)) { scoped in
                        UsageBar(title: "Weekly · \(scoped.name)", percent: scoped.percent,
                                 resetsAt: scoped.resetsAt, now: now)
                    }
                    HStack {
                        if let spend = account.spend {
                            Text("Extra usage \(spend.usedText)")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StalenessLabel(account: account, now: now)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shown when the host app hasn't published a snapshot yet.
struct UsageNoDataView: View {
    init() {}

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.title3).foregroundStyle(.secondary)
            Text("No data").font(.caption.weight(.medium))
            Text("Open Claude Usage once")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(4)
    }
}

struct AccountHeader: View {
    var account: AccountUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(account.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(account.plan)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
            Spacer(minLength: 0)
        }
    }
}
