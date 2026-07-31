import SwiftUI

/// First run. States plainly what gets read and what leaves the machine, then lets
/// the user pick which accounts to include before anything else happens.
///
/// The claims here are deliberately specific rather than reassuring. "We respect
/// your privacy" is worth nothing; naming the files and the fields is checkable.
struct WelcomeView: View {
    @ObservedObject var preferences: AppPreferences
    var locations: [AccountLocation]
    var emails: [String: String]

    @Environment(\.colorScheme) private var scheme

    private var anySelected: Bool { !preferences.enabledAccountIDs.isEmpty }

    /// Deliberately not wrapped in a ScrollView — the caller owns scrolling. It also
    /// keeps the view renderable by ImageRenderer, which draws a ScrollView empty.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            readsSection
            accountsSection
            Divider()
            footer
        }
        .padding(22)
        .frame(maxWidth: 520, alignment: .leading)
        .onAppear { preferences.primeSelection(with: locations.map(\.id)) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Usage")
                .font(.system(size: 22, weight: .bold))
            Text("Shows how much of your Claude limits you've used, from the data Claude Code already keeps on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Everything stays on this Mac", systemImage: "lock.laptopcomputer")
                .font(.system(size: 13, weight: .semibold))

            Text("Nothing is uploaded anywhere. The only network request this app can ever make is to Anthropic's own usage endpoint, and only if you switch on Live usage later — which asks for Keychain access separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ReadRow(
                    icon: "doc.text",
                    path: "~/.claude.json, ~/.claude-*/.claude.json",
                    detail: "Your limit percentages, reset times, plan, and account email."
                )
                ReadRow(
                    icon: "square.stack.3d.up",
                    path: "projects/**/*.jsonl",
                    detail: "Your transcripts. Each turn is parsed to pull out four things: the token counts, the timestamp, the model, and the project folder. Message text is never extracted, stored, or sent."
                )
            }
            .padding(12)
            .background(.quinary, in: .rect(cornerRadius: 10))

            Text("Transcripts aren't touched until you choose accounts below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(locations.isEmpty
                 ? "No Claude Code accounts found"
                 : "Found \(locations.count) account\(locations.count == 1 ? "" : "s") — choose which to include")
                .font(.system(size: 13, weight: .semibold))

            if locations.isEmpty {
                Text("Looked for `~/.claude.json` and `~/.claude-*/.claude.json`. Run Claude Code once, then reopen this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(locations, id: \.id) { location in
                Toggle(isOn: Binding(
                    get: { preferences.isEnabled(location.id) },
                    set: { preferences.setEnabled($0, for: location.id) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.label).font(.system(size: 12, weight: .semibold))
                        Text(emails[location.id] ?? location.dataDir.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            Toggle("Hide email addresses in the app and widget", isOn: $preferences.hideEmails)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 4)
        }
    }

    private var footer: some View {
        HStack {
            Text(anySelected ? "" : "Select at least one account to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get started") { preferences.confirmSetup() }
                .keyboardShortcut(.defaultAction)
                .disabled(!anySelected)
        }
    }
}

private struct ReadRow: View {
    var icon: String
    var path: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
