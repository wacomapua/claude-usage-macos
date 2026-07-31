import SwiftUI
import ServiceManagement

struct ContentView: View {
    @EnvironmentObject private var monitor: UsageMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if monitor.snapshot.accounts.isEmpty {
                    EmptyStateView(searchedDirectories: monitor.configDirectories)
                } else {
                    ForEach(monitor.snapshot.accounts) { account in
                        AccountCard(account: account)
                    }
                }
                Divider()
                FooterView(writeSucceeded: monitor.lastWriteSucceeded)
            }
            .padding(16)
        }
        // The panels are white in the light scheme, so the page behind them has to be
        // grey or they vanish into it.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AccountCard: View {
    var account: AccountUsage
    private let now = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DialGauge(
                percent: account.session?.percent ?? 0,
                resetsAt: account.session?.resetsAt,
                window: LimitWindow.session,
                now: now,
                size: 112,
                caption: "5H"
            )

            VStack(alignment: .leading, spacing: 10) {
                AccountHeader(account: account, size: 14)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let weekly = account.weekly {
                    MiniMeter(title: "Weekly", percent: weekly.percent,
                              resetsAt: weekly.resetsAt, now: now)
                }
                ForEach(account.scoped) { scoped in
                    MiniMeter(title: scoped.name, percent: scoped.percent,
                              resetsAt: scoped.resetsAt, now: now)
                }

                if account.session == nil && account.weekly == nil {
                    Text("No usage cached yet — run Claude Code under this account once.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let stats = account.stats, !stats.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        StatReadout(label: "Tokens 5h",
                                    value: TokenFormat.compact(stats.sessionTokens), size: 17)
                        StatReadout(label: "Value 5h",
                                    value: TokenFormat.money(stats.sessionCost),
                                    caption: "api", tint: .orange, size: 17)
                        StatReadout(label: "Week",
                                    value: TokenFormat.money(stats.weekCost),
                                    caption: TokenFormat.compact(stats.weekTokens), size: 17)
                        Spacer(minLength: 0)
                    }
                    BurnSparkline(buckets: stats.buckets, height: 26)
                    ModelMixBar(models: stats.models)
                }

                HStack(spacing: 5) {
                    if let stats = account.stats, let project = stats.topProject {
                        Text("\(stats.messageCount) turns")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("· \(project)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let spend = account.spend {
                        Text(spend.usedText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("extra usage")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    StalenessLabel(account: account, now: now)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

private struct EmptyStateView: View {
    var searchedDirectories: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No Claude accounts found", systemImage: "questionmark.folder")
                .font(.headline)
            Text("Looked for `~/.claude` and `~/.claude-*` directories containing a `.claude.json`.")
                .font(.caption).foregroundStyle(.secondary)
            if !searchedDirectories.isEmpty {
                Text(searchedDirectories.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quinary, in: .rect(cornerRadius: 10))
    }
}

private struct FooterView: View {
    var writeSucceeded: Bool
    @EnvironmentObject private var monitor: UsageMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !writeSucceeded {
                Label(
                    "Can't write to the shared container — the widget won't update. Check the App Group entitlement.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }

            if let loginError {
                Text(loginError).font(.caption2).foregroundStyle(.red)
            }

            // The widget only sees what this app last wrote, so it stops updating if
            // the app isn't running. Worth saying plainly rather than hiding.
            Text("Keep this app running (or launching at login) so the widget stays current. Limit percentages come from Claude Code's local cache and refresh whenever you use Claude Code. Token counts, value and burn history are read from your transcripts — the value shown is what that usage would have cost at Claude API list rates, not a charge on your plan.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Refresh now") { monitor.refresh(force: true) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // Revert the toggle so it never claims a state that didn't take.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = error.localizedDescription
        }
    }
}
