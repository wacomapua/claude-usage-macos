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
        .background(.background)
    }
}

private struct AccountCard: View {
    var account: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.label).font(.headline)
                Text(account.plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                Spacer()
                StalenessLabel(account: account)
            }

            Text(account.email)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let session = account.session {
                UsageBar(title: "Session (5h)", percent: session.percent, resetsAt: session.resetsAt)
            }
            if let weekly = account.weekly {
                UsageBar(title: "Weekly", percent: weekly.percent, resetsAt: weekly.resetsAt)
            }
            ForEach(account.scoped) { scoped in
                UsageBar(title: "Weekly · \(scoped.name)", percent: scoped.percent, resetsAt: scoped.resetsAt)
            }

            if account.session == nil && account.weekly == nil {
                Text("No usage cached yet — run Claude Code under this account once.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let spend = account.spend {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard").font(.caption2)
                    Text("Extra usage \(spend.usedText)" + (spend.limitText.map { " of \($0)" } ?? ""))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quinary, in: .rect(cornerRadius: 10))
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
            Text("Keep this app running (or launching at login) so the widget stays current. Numbers come from Claude Code's local cache and refresh whenever you use Claude Code.")
                .font(.caption2).foregroundStyle(.secondary)

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
