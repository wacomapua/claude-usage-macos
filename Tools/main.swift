import SwiftUI
import AppKit

/// Renders the widget layouts to PNGs at real macOS widget dimensions, so the designs
/// can be checked without adding the widget to the desktop by hand.
///
/// Build with `Tools/render.sh`.

@MainActor
func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to path: String) {
    let content = view
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
        .environment(\.colorScheme, scheme)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard
        let image = renderer.nsImage,
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        print("failed to render \(path)")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

/// Synthetic data covering the states real usage rarely reaches: a hot dial, an
/// over-pace burn, and a window that has already rolled over. Without this the design
/// only ever gets reviewed at the cool end of the scale.
func stressSnapshot(now: Date) -> UsageSnapshot {
    UsageSnapshot(
        accounts: [
            AccountUsage(
                id: ".claude-hot", label: "Burning", email: "hot@example.com",
                plan: "Max 20×", fetchedAt: now.addingTimeInterval(-120),
                // 94% spent with most of the window still to run — hard over pace.
                session: Gauge(percent: 94, resetsAt: now.addingTimeInterval(3600 * 3.5)),
                weekly: Gauge(percent: 68, resetsAt: now.addingTimeInterval(3600 * 90)),
                scoped: [ScopedGauge(name: "Opus", percent: 81,
                                     resetsAt: now.addingTimeInterval(3600 * 90))],
                spend: Spend(usedMinor: 128_00, limitMinor: 200_00,
                             currency: "USD", exponent: 2, enabled: true),
                stats: TokenStats(
                    sessionTokens: 412_000_000, sessionCost: 318.40,
                    weekTokens: 2_100_000_000, weekCost: 4210,
                    buckets: (0..<14).map { index in
                        HourBucket(hour: now.addingTimeInterval(Double(index - 13) * 3600),
                                   tokens: [4, 9, 3, 14, 22, 8, 31, 47, 29, 55, 71, 44, 88, 62][index] * 1_000_000,
                                   cost: 0)
                    },
                    models: [ModelSlice(family: "Opus", tokens: 62),
                             ModelSlice(family: "Fable", tokens: 24),
                             ModelSlice(family: "Sonnet", tokens: 10),
                             ModelSlice(family: "Haiku", tokens: 4)],
                    projects: [ProjectSlice(name: "monorepo-api", tokens: 940_000_000),
                               ProjectSlice(name: "web-dashboard", tokens: 610_000_000),
                               ProjectSlice(name: "infra-terraform", tokens: 350_000_000)],
                    todayTokens: 1_180_000_000,
                    yesterdayTokens: 890_000_000,
                    messageCount: 31_842
                )
            ),
            AccountUsage(
                id: ".claude-stale", label: "Idle", email: "stale@example.com",
                plan: "Pro", fetchedAt: now.addingTimeInterval(-3600 * 30),
                // Reset time already passed — must render as "reset", not as 47%.
                session: Gauge(percent: 47, resetsAt: now.addingTimeInterval(-3600 * 6)),
                weekly: Gauge(percent: 52, resetsAt: now.addingTimeInterval(3600 * 20)),
                scoped: [],
                spend: nil
            ),
        ],
        generatedAt: now
    )
}

@MainActor
func main() {
    let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
    let now = Date()

    if CommandLine.arguments.contains("--welcome") {
        // Render against a throwaway defaults domain so previewing the first-run
        // screen can't flip the real app's stored choices.
        let sandbox = UserDefaults(suiteName: "preview.welcome")!
        sandbox.removePersistentDomain(forName: "preview.welcome")
        let preferences = AppPreferences(defaults: sandbox)
        let locations = AccountLocation.discoverAll()
        let emails = Dictionary(uniqueKeysWithValues: locations.compactMap { location in
            ClaudeConfigReader.email(at: location).map { (location.id, $0) }
        })
        for scheme in [ColorScheme.light, .dark] {
            render(WelcomeView(preferences: preferences, locations: locations, emails: emails),
                   size: CGSize(width: 560, height: 620),
                   scheme: scheme,
                   to: "\(outputDir)/welcome-\(scheme == .dark ? "dark" : "light").png")
        }
        return
    }

    if CommandLine.arguments.contains("--stress") {
        renderAll(stressSnapshot(now: now), now: now, prefix: "stress", into: outputDir)
        return
    }

    // Build straight from the config files and scan the transcripts, so previews
    // always show live data rather than whatever the app last published.
    var snapshot = ClaudeConfigReader.buildSnapshot()
    if snapshot.accounts.isEmpty { snapshot = .placeholder }

    for index in snapshot.accounts.indices {
        let account = snapshot.accounts[index]
        guard let path = account.dataDirPath else { continue }
        let dir = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: dir.path) else { continue }
        let started = Date()
        snapshot.accounts[index].stats = TranscriptScanner().scan(
            configDir: dir,
            sessionWindowStart: account.sessionWindowStart(now: now),
            now: now
        )
        let stats = snapshot.accounts[index].stats
        print(String(
            format: "scanned %@ in %.2fs — %@ tokens, %@ this week, %d turns",
            account.label, Date().timeIntervalSince(started),
            TokenFormat.compact(stats?.sessionTokens ?? 0),
            TokenFormat.money(stats?.weekCost ?? 0),
            stats?.messageCount ?? 0
        ))
    }

    renderAll(snapshot, now: now, prefix: nil, into: outputDir)
}

@MainActor
func renderAll(_ snapshot: UsageSnapshot, now: Date, prefix: String?, into outputDir: String) {
    // Standard macOS widget point sizes.
    let sizes: [(String, CGSize)] = [
        ("small", CGSize(width: 170, height: 170)),
        ("medium", CGSize(width: 364, height: 170)),
        ("large", CGSize(width: 364, height: 382)),
    ]

    for scheme in [ColorScheme.light, .dark] {
        let suffix = scheme == .dark ? "dark" : "light"
        for (name, size) in sizes {
            let view: AnyView = switch name {
            case "small": AnyView(UsageSmallView(snapshot: snapshot, now: now))
            case "large": AnyView(UsageLargeView(snapshot: snapshot, now: now))
            default: AnyView(UsageMediumView(snapshot: snapshot, now: now))
            }
            let stem = prefix.map { "\($0)-\(name)" } ?? name
            render(view, size: size, scheme: scheme, to: "\(outputDir)/\(stem)-\(suffix).png")
        }
    }
}

// Top-level code already runs on the main thread; this just tells the compiler so.
MainActor.assumeIsolated { main() }
