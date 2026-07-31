import SwiftUI

// MARK: - Design tokens
//
// The visual language is a precision instrument cluster: a graphite dial, a luminous
// scale that runs cool → hot as headroom disappears, and light that comes off the
// needle rather than off the panel. Cool means room to spare; heat means you're
// running out. That ramp does the work a traffic-light palette would do, without
// three flat states.

enum Dial {
    /// The scale, as (position, colour). Read left to right around the arc.
    static let scale: [(at: Double, color: (r: Double, g: Double, b: Double))] = [
        (0.00, (0.275, 0.878, 0.722)),  // aqua   #46E0B8
        (0.50, (1.000, 0.820, 0.400)),  // citrus #FFD166
        (0.80, (1.000, 0.541, 0.357)),  // ember  #FF8A5B
        (1.00, (1.000, 0.302, 0.427)),  // crimson #FF4D6D
    ]

    /// The colour at a point on the scale, interpolated between stops.
    static func color(at fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        guard let upperIndex = scale.firstIndex(where: { $0.at >= f }) else {
            return Color(.sRGB, red: scale[scale.count - 1].color.r,
                         green: scale[scale.count - 1].color.g,
                         blue: scale[scale.count - 1].color.b)
        }
        guard upperIndex > 0 else {
            return Color(.sRGB, red: scale[0].color.r, green: scale[0].color.g, blue: scale[0].color.b)
        }

        let lower = scale[upperIndex - 1], upper = scale[upperIndex]
        let span = upper.at - lower.at
        let t = span <= 0 ? 0 : (f - lower.at) / span
        return Color(
            .sRGB,
            red: lower.color.r + (upper.color.r - lower.color.r) * t,
            green: lower.color.g + (upper.color.g - lower.color.g) * t,
            blue: lower.color.b + (upper.color.b - lower.color.b) * t
        )
    }

    private static func swatch(_ c: (r: Double, g: Double, b: Double)) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    static var gradient: AngularGradient {
        var stops = scale.map {
            Gradient.Stop(color: swatch($0.color), location: $0.at * sweepFraction)
        }
        // Run the scale back to its starting hue across the dial's blind spot at the
        // bottom. Without this the gradient seam sits exactly on the start angle, and
        // the round line cap — which overhangs it — picks up the hot end of the scale,
        // painting a red tip on an arc that has barely moved.
        stops.append(.init(color: swatch(scale[0].color), location: 1))

        return AngularGradient(
            gradient: Gradient(stops: stops),
            center: .center,
            startAngle: .degrees(startDegrees),
            endAngle: .degrees(startDegrees + 360)
        )
    }

    /// A 270° sweep with the gap at the bottom — the open-bottom face of a rev counter.
    static let startDegrees: Double = 135
    static let sweepDegrees: Double = 270
    static var sweepFraction: Double { sweepDegrees / 360 }

    static let track = Color.primary.opacity(0.08)
    static let idle = Color.secondary
}

/// The arc itself. A real `Shape` rather than a rotated, trimmed `Circle` so that the
/// angular gradient lines up with actual screen angles instead of drifting with the
/// rotation.
struct ArcShape: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(Dial.startDegrees),
            endAngle: .degrees(Dial.startDegrees + Dial.sweepDegrees * min(1, max(0, fraction))),
            clockwise: false
        )
        return path
    }
}

// MARK: - Pace
//
// The signature of this widget. A quota bar tells you how much you've spent; it can't
// tell you whether that's fast. Because we know both the percentage and when the window
// closes, we know how far through the window you are — and therefore where an even
// burn would have put you by now. The tick on the dial marks that point.

struct Pace {
    /// Where an even burn would sit right now, 0–1. Nil when it can't be established.
    var expected: Double
    var actual: Double

    var isAhead: Bool { actual > expected + 0.05 }
    var isBehind: Bool { actual < expected - 0.05 }

    var caption: String {
        if isBehind { return "under pace" }
        if isAhead { return "over pace" }
        return "on pace"
    }

    var symbol: String {
        if isBehind { return "arrow.down.right" }
        if isAhead { return "arrow.up.right" }
        return "equal"
    }

    init?(percent: Int, resetsAt: Date?, window: TimeInterval, now: Date) {
        guard let resetsAt, window > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        // Outside the window entirely — either expired or a reset time we can't reconcile.
        guard remaining > 0, remaining <= window else { return nil }
        expected = (window - remaining) / window
        actual = Double(percent) / 100
    }
}

// MARK: - The dial

struct DialGauge: View {
    var percent: Int
    var resetsAt: Date?
    var window: TimeInterval
    var now: Date
    var size: CGFloat
    var caption: String
    /// Optional second, inset ring — used to fold the weekly window into the same dial.
    var innerPercent: Int?
    var innerResetsAt: Date?

    private var lineWidth: CGFloat { max(4, size * 0.085) }
    private var innerLineWidth: CGFloat { max(2, size * 0.042) }
    private var inset: CGFloat { lineWidth * 1.9 }

    /// The cached window has already rolled over, so this figure is history.
    private var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    private var fraction: Double { min(1, max(0, Double(percent) / 100)) }
    private var accent: Color { isExpired ? Dial.idle : Dial.color(at: fraction) }
    private var pace: Pace? {
        isExpired ? nil : Pace(percent: percent, resetsAt: resetsAt, window: window, now: now)
    }

    var body: some View {
        ZStack {
            // Track
            ArcShape(fraction: 1)
                .stroke(Dial.track, style: .init(lineWidth: lineWidth, lineCap: .round))

            // Inner ring — the weekly window, when folded in.
            if let innerPercent {
                let innerExpired = innerResetsAt.map { $0 <= now } ?? false
                ArcShape(fraction: 1)
                    .stroke(Dial.track, style: .init(lineWidth: innerLineWidth, lineCap: .round))
                    .padding(inset)
                ArcShape(fraction: Double(innerPercent) / 100)
                    .stroke(
                        innerExpired ? Dial.idle.opacity(0.4)
                                     : Dial.color(at: Double(innerPercent) / 100),
                        style: .init(lineWidth: innerLineWidth, lineCap: .round)
                    )
                    .padding(inset)
            }

            // The needle path. Light comes off the reading, not the panel.
            if !isExpired && percent > 0 {
                ArcShape(fraction: fraction)
                    .stroke(Dial.gradient, style: .init(lineWidth: lineWidth, lineCap: .round))
                    .shadow(color: accent.opacity(0.55), radius: lineWidth * 0.85)
            }

            if let pace {
                PaceTick(expected: pace.expected, size: size, lineWidth: lineWidth)
            }

            readout
        }
        .frame(width: size, height: size)
    }

    private var readout: some View {
        VStack(spacing: -1) {
            if isExpired {
                Text("—")
                    .font(.system(size: size * 0.30, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("reset")
                    .font(.system(size: max(7, size * 0.095), weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    Text("\(percent)")
                        .font(.system(size: size * 0.30, weight: .semibold, design: .rounded)
                            .monospacedDigit())
                    Text("%")
                        .font(.system(size: size * 0.15, weight: .semibold, design: .rounded))
                        .padding(.top, size * 0.035)
                }
                .foregroundStyle(accent)
                Text(caption)
                    .font(.system(size: max(7, size * 0.095), weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Marks where an even burn through the window would have reached by now.
private struct PaceTick: View {
    var expected: Double
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        Capsule()
            .fill(.primary.opacity(0.6))
            // The tick crosses both the dim track and the lit arc, so it needs a halo
            // to stay readable against a hot gradient as well as against graphite.
            .shadow(color: .black.opacity(0.35), radius: 1)
            .frame(width: 1.5, height: lineWidth + 5)
            .offset(y: -(size / 2))
            // offset(y:) places the tick at 12 o'clock, which is -90° in screen angles.
            .rotationEffect(.degrees(Dial.startDegrees + Dial.sweepDegrees * expected + 90))
    }
}

// MARK: - Supporting readouts

/// A compact linear readout for the secondary limits, sized to sit beside a dial.
struct MiniMeter: View {
    var title: String
    var percent: Int
    var resetsAt: Date?
    var now: Date

    private var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    private var accent: Color {
        isExpired ? Dial.idle : Dial.color(at: Double(percent) / 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if isExpired {
                    Text("reset")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(percent)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                    if let reset = UsageFormat.countdown(to: resetsAt, from: now) {
                        Text(reset)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Dial.track)
                    Capsule()
                        .fill(accent)
                        .opacity(isExpired ? 0.3 : 1)
                        .frame(width: geo.size.width * min(1, max(0, Double(percent) / 100)))
                        .shadow(color: isExpired ? .clear : accent.opacity(0.5), radius: 3)
                }
            }
            .frame(height: 3)
        }
    }
}

/// Account name and plan, set as an instrument label.
struct AccountHeader: View {
    var account: AccountUsage
    var size: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(account.label)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
            Text(account.plan.uppercased())
                .font(.system(size: max(7, size * 0.62), weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Dial.track, in: .capsule)
            Spacer(minLength: 0)
        }
    }
}

/// The "as of …" marker. Cached numbers only refresh while Claude Code is running.
struct StalenessLabel: View {
    var account: AccountUsage
    var now: Date = Date()

    private var isStale: Bool {
        guard let fetchedAt = account.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > 45 * 60
    }

    var body: some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 8))
            }
            Text(UsageFormat.age(of: account.fetchedAt, from: now))
                .font(.system(size: 9))
        }
        .foregroundStyle(isStale ? AnyShapeStyle(Dial.color(at: 0.8)) : AnyShapeStyle(.tertiary))
    }
}

/// Card surface for the larger layouts — a panel the dials sit on.
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}
