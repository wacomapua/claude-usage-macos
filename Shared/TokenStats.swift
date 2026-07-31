import Foundation

// MARK: - Model pricing
//
// Per-million-token list rates for the Claude API. Everything derived from these
// is an *API-equivalent* figure: on a Max or Team subscription none of it is
// billed. It answers "what would this have cost on the API", which is the only
// honest way to put a dollar value on subscription usage.

struct ModelRate {
    var family: String
    var input: Double   // $ per 1M input tokens
    var output: Double  // $ per 1M output tokens

    /// Cache writes and reads are priced as multiples of the input rate.
    static let cacheWrite5m = 1.25
    static let cacheWrite1h = 2.0
    static let cacheRead = 0.1

    /// Claude Sonnet 5 carries an introductory rate that expires; past the date
    /// the list price applies. Hard-coding one or the other would silently drift.
    private static let sonnetIntroEnds = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")
        ?? Date.distantPast

    static func rate(forModel id: String, at date: Date) -> ModelRate {
        let m = id.lowercased()
        if m.contains("fable") || m.contains("mythos") {
            return ModelRate(family: "Fable", input: 10, output: 50)
        }
        if m.contains("haiku") {
            return ModelRate(family: "Haiku", input: 1, output: 5)
        }
        if m.contains("sonnet") {
            let intro = date < sonnetIntroEnds
            return ModelRate(family: "Sonnet",
                             input: intro ? 2 : 3,
                             output: intro ? 10 : 15)
        }
        // Opus is both the most common and the safest default for an unknown id:
        // it sits mid-range, so a new model name can't wildly skew the estimate.
        return ModelRate(family: "Opus", input: 5, output: 25)
    }
}

// MARK: - Aggregates

/// One hour of activity, used for the burn sparkline.
struct HourBucket: Codable, Hashable {
    var hour: Date
    var tokens: Int
    var cost: Double
}

/// Share of output tokens attributable to one model family.
struct ModelSlice: Codable, Hashable, Identifiable {
    var id: String { family }
    var family: String
    var tokens: Int
}

/// Everything derived from the transcripts for one account.
struct TokenStats: Codable, Hashable {
    /// Totals inside the account's current 5-hour session window.
    var sessionTokens: Int = 0
    var sessionCost: Double = 0
    /// Totals over the last 7 days.
    var weekTokens: Int = 0
    var weekCost: Double = 0
    /// Hourly buckets, oldest first, for the sparkline.
    var buckets: [HourBucket] = []
    /// Output-token share per model family, largest first.
    var models: [ModelSlice] = []
    /// Project directory with the most tokens this week.
    var topProject: String?
    var messageCount: Int = 0

    var isEmpty: Bool { weekTokens == 0 }
}

// MARK: - Scanner

/// Aggregates token usage out of Claude Code's transcript files.
///
/// Every assistant turn is written to `<configDir>/projects/<project>/<session>.jsonl`
/// with a `message.usage` block and a timestamp, so the transcripts carry the one
/// thing the `/usage` cache does not: what was actually spent, when, and on which
/// model.
///
/// Files are only ever appended to, so each is read once in full and thereafter
/// only from the byte offset where the last read stopped. A full cold scan of
/// ~200MB takes well under a second; warm rescans touch almost nothing.
final class TranscriptScanner {
    /// How far back to look. Bounds both the cold scan and the weekly totals.
    private let lookback: TimeInterval = 7 * 24 * 60 * 60
    /// How many hourly buckets the sparkline shows.
    private let sparklineHours = 14

    /// Per-file parse state, keyed by path.
    private struct FileState {
        var offset: UInt64 = 0
        var buckets: [Date: HourBucket] = [:]
        var modelTokens: [String: Int] = [:]
        var messages = 0
        var projectTokens: [String: Int] = [:]
    }

    private var files: [String: FileState] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Scans one account's transcripts and returns fresh aggregates.
    func scan(configDir: URL, sessionWindowStart: Date, now: Date = Date()) -> TokenStats {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        let cutoff = now.addingTimeInterval(-lookback)

        for url in transcriptURLs(under: projects, modifiedSince: cutoff) {
            ingest(url)
        }

        return aggregate(sessionWindowStart: sessionWindowStart, now: now, cutoff: cutoff)
    }

    // MARK: File discovery

    private func transcriptURLs(under root: URL, modifiedSince cutoff: Date) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
            result.append(url)
        }
        return result
    }

    // MARK: Parsing

    private func ingest(_ url: URL) {
        let path = url.path
        var state = files[path] ?? FileState()

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // A shrunken file means it was rotated or rewritten — start over.
        if size < state.offset { state = FileState() }
        guard size > state.offset else {
            files[path] = state
            return
        }

        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            files[path] = state
            return
        }

        // A read can land mid-line while Claude Code is still writing. Keep only
        // whole lines and rewind the offset to the last newline so the partial
        // line is re-read intact next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            files[path] = state
            return
        }
        let complete = data[..<lastNewline]
        state.offset += UInt64(lastNewline + 1)

        let project = url.deletingLastPathComponent().lastPathComponent
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            parse(line: Data(line), project: project, into: &state)
        }
        files[path] = state
    }

    private func parse(line: Data, project: String, into state: inout FileState) {
        // Cheap pre-filter: most lines are user turns, attachments or metadata and
        // never carry a usage block. Decoding all of them would dominate the scan.
        guard line.count > 40, line.range(of: Data("\"usage\"".utf8)) != nil else { return }

        guard
            let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let message = root["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let stamp = root["timestamp"] as? String,
            let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp)
        else { return }

        let model = message["model"] as? String ?? ""
        let rate = ModelRate.rate(forModel: model, at: date)

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

        // The transcript records the 5-minute and 1-hour cache splits separately,
        // and they're priced differently — 1.25× vs 2× the input rate.
        let creation = usage["cache_creation"] as? [String: Any]
        let write5m = creation?["ephemeral_5m_input_tokens"] as? Int
            ?? usage["cache_creation_input_tokens"] as? Int ?? 0
        let write1h = creation?["ephemeral_1h_input_tokens"] as? Int ?? 0

        let cost = (Double(input) * rate.input
                    + Double(output) * rate.output
                    + Double(cacheRead) * rate.input * ModelRate.cacheRead
                    + Double(write5m) * rate.input * ModelRate.cacheWrite5m
                    + Double(write1h) * rate.input * ModelRate.cacheWrite1h) / 1_000_000

        let tokens = input + output + cacheRead + write5m + write1h
        let hour = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date

        var bucket = state.buckets[hour] ?? HourBucket(hour: hour, tokens: 0, cost: 0)
        bucket.tokens += tokens
        bucket.cost += cost
        state.buckets[hour] = bucket

        state.modelTokens[rate.family, default: 0] += output
        state.messages += 1

        // Each record carries the working directory it ran in. That's exact, whereas
        // the containing folder name encodes the path with "/" replaced by "-" —
        // which is ambiguous the moment a directory name contains a hyphen
        // ("-Users-me-code-my-app" could be "my-app" or "my/app").
        let name = (root["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        state.projectTokens[name ?? project, default: 0] += tokens
    }

    // MARK: Aggregation

    private func aggregate(sessionWindowStart: Date, now: Date, cutoff: Date) -> TokenStats {
        var merged: [Date: HourBucket] = [:]
        var modelTokens: [String: Int] = [:]
        var projectTokens: [String: Int] = [:]
        var messages = 0

        for state in files.values {
            for (hour, bucket) in state.buckets where hour >= cutoff {
                var existing = merged[hour] ?? HourBucket(hour: hour, tokens: 0, cost: 0)
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                merged[hour] = existing
            }
            for (family, tokens) in state.modelTokens { modelTokens[family, default: 0] += tokens }
            for (project, tokens) in state.projectTokens { projectTokens[project, default: 0] += tokens }
            messages += state.messages
        }

        var stats = TokenStats()
        stats.messageCount = messages

        for (hour, bucket) in merged {
            stats.weekTokens += bucket.tokens
            stats.weekCost += bucket.cost
            if hour >= sessionWindowStart {
                stats.sessionTokens += bucket.tokens
                stats.sessionCost += bucket.cost
            }
        }

        // Sparkline: a contiguous run of hours, with gaps filled as zeroes so the
        // spacing stays linear in time rather than skipping idle hours.
        let currentHour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        stats.buckets = (0..<sparklineHours).reversed().map { offset in
            let hour = currentHour.addingTimeInterval(-Double(offset) * 3600)
            return merged[hour] ?? HourBucket(hour: hour, tokens: 0, cost: 0)
        }

        stats.models = modelTokens
            .map { ModelSlice(family: $0.key, tokens: $0.value) }
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }

        stats.topProject = projectTokens.max { $0.value < $1.value }?.key

        return stats
    }
}

// MARK: - Formatting

enum TokenFormat {
    /// 1_234_567 → "1.2M". Widgets have no room for grouped digits.
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens)"
        case ..<1_000_000:
            return String(format: "%.0fK", Double(tokens) / 1_000)
        case ..<10_000_000:
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        default:
            return String(format: "%.0fM", Double(tokens) / 1_000_000)
        }
    }

    static func money(_ dollars: Double) -> String {
        if dollars >= 1000 { return String(format: "$%.1fk", dollars / 1000) }
        if dollars >= 100 { return String(format: "$%.0f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}
