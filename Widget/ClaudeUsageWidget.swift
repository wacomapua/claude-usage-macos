import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: UsageSnapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        // The widget gallery has no real data to show, so use the sample set there.
        let snapshot = context.isPreview ? .placeholder : (SnapshotStore.read() ?? .placeholder)
        completion(UsageEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = SnapshotStore.read() ?? .empty
        let now = Date()

        // Pre-render the next hour so the reset countdowns keep ticking even if the
        // host app never gets a chance to push a reload.
        let entries = stride(from: 0, through: 60, by: 10).map { minutes in
            UsageEntry(date: now.addingTimeInterval(Double(minutes) * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Session and weekly limits for each of your Claude accounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget { ClaudeUsageWidget() }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        if entry.snapshot.accounts.isEmpty {
            UsageNoDataView()
        } else {
            switch family {
            case .systemSmall: UsageSmallView(snapshot: entry.snapshot, now: entry.date)
            case .systemLarge: UsageLargeView(snapshot: entry.snapshot, now: entry.date)
            default: UsageMediumView(snapshot: entry.snapshot, now: entry.date)
            }
        }
    }
}
