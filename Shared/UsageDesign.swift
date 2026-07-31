import SwiftUI

// MARK: - Design tokens
//
// The visual language is a precision instrument cluster: a graphite dial, a scale that
// runs cool → hot as headroom disappears, and light coming off the reading rather than
// off the panel. Cool means room to spare; heat means you're running out.
//
// The scale is defined twice. Luminous mint reads beautifully on graphite and washes out
// to nothing on white, so the light scheme gets its own deeper, more saturated ramp
// rather than the dark one at reduced opacity.

enum Dial {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Dark scheme: luminous, as if lit from behind.
    private static let darkScale: [(at: Double, color: RGB)] = [
        (0.00, (0.275, 0.878, 0.722)),  // aqua    #46E0B8
        (0.50, (1.000, 0.820, 0.400)),  // citrus  #FFD166
        (0.80, (1.000, 0.541, 0.357)),  // ember   #FF8A5B
        (1.00, (1.000, 0.302, 0.427)),  // crimson #FF4D6D
    ]

    /// Light scheme: the same hues taken down into ink, so they hold on near-white.
    private static let lightScale: [(at: Double, color: RGB)] = [
        (0.00, (0.043, 0.588, 0.478)),  // deep teal   #0B967A
        (0.50, (0.729, 0.478, 0.020)),  // dark amber  #BA7A05
        (0.80, (0.816, 0.318, 0.106)),  // burnt ember #D0511B
        (1.00, (0.749, 0.098, 0.239)),  // deep crimson #BF193D
    ]

    static func scale(_ scheme: ColorScheme) -> [(at: Double, color: RGB)] {
        scheme == .dark ? darkScale : lightScale
    }

    private static func swatch(_ c: RGB) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// The colour at a point on the scale, interpolated between stops.
    static func color(at fraction: Double, _ scheme: ColorScheme) -> Color {
        let stops = scale(scheme)
        let f = min(1, max(0, fraction))

        guard let upperIndex = stops.firstIndex(where: { $0.at >= f }) else {
            return swatch(stops[stops.count - 1].color)
        }
        guard upperIndex > 0 else { return swatch(stops[0].color) }

        let lower = stops[upperIndex - 1], upper = stops[upperIndex]
        let span = upper.at - lower.at
        let t = span <= 0 ? 0 : (f - lower.at) / span
        return Color(
            .sRGB,
            red: lower.color.r + (upper.color.r - lower.color.r) * t,
            green: lower.color.g + (upper.color.g - lower.color.g) * t,
            blue: lower.color.b + (upper.color.b - lower.color.b) * t
        )
    }

    static func gradient(_ scheme: ColorScheme) -> AngularGradient {
        let stops = scale(scheme)
        var gradientStops = stops.map {
            Gradient.Stop(color: swatch($0.color), location: $0.at * sweepFraction)
        }
        // Run the scale back to its starting hue across the dial's blind spot at the
        // bottom. Without this the gradient seam sits exactly on the start angle, and
        // the round line cap — which overhangs it — picks up the hot end of the scale,
        // painting a red tip on an arc that has barely moved.
        gradientStops.append(.init(color: swatch(stops[0].color), location: 1))

        return AngularGradient(
            gradient: Gradient(stops: gradientStops),
            center: .center,
            startAngle: .degrees(startDegrees),
            endAngle: .degrees(startDegrees + 360)
        )
    }

    /// A 270° sweep with the gap at the bottom — the open-bottom face of a rev counter.
    static let startDegrees: Double = 135
    static let sweepDegrees: Double = 270
    static var sweepFraction: Double { sweepDegrees / 360 }

    // Explicit greys rather than the system hierarchy: `.tertiary` on a light background
    // is far too faint for 8pt type, which is most of what this widget is made of.
    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.09)
    }

    /// The pace ghost — where an even burn would have reached. Sits above the track,
    /// below the live arc.
    static func ghost(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.20) : .black.opacity(0.17)
    }

    /// Small-caps field labels.
    static func label(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.62) : .black.opacity(0.58)
    }

    /// Countdowns, timestamps, units — quieter than a label but still legible.
    static func meta(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.48) : .black.opacity(0.45)
    }

    /// A window that has rolled over: present, but carrying no live reading.
    static func idle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.35) : .black.opacity(0.32)
    }

    /// Glow is a dark-scheme effect. On white it turns into grey mud, so it's dialled
    /// most of the way down rather than off — just enough to soften the arc's edge.
    static func glowOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.55 : 0.22
    }
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
// closes, we know how far through the window you are — and therefore where an even burn
// would have put you by now.
//
// It's drawn as a second, dimmed arc rather than a mark on the ring: comparing two arc
// lengths is immediate, whereas a lone tick floating off the fill just reads as a
// broken needle.

struct Pace {
    /// Where an even burn would sit right now, 0–1.
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

    @Environment(\.colorScheme) private var scheme

    private var lineWidth: CGFloat { max(4, size * 0.085) }
    private var innerLineWidth: CGFloat { max(2, size * 0.042) }
    private var inset: CGFloat { lineWidth * 1.9 }

    /// Below this the centre can't carry a third line legibly.
    private var showsCountdown: Bool { size >= 84 }

    /// The cached window has already rolled over, so this figure is history.
    private var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    private var fraction: Double { min(1, max(0, Double(percent) / 100)) }
    private var accent: Color {
        isExpired ? Dial.idle(scheme) : Dial.color(at: fraction, scheme)
    }
    private var pace: Pace? {
        isExpired ? nil : Pace(percent: percent, resetsAt: resetsAt, window: window, now: now)
    }

    var body: some View {
        ZStack {
            ArcShape(fraction: 1)
                .stroke(Dial.track(scheme), style: .init(lineWidth: lineWidth, lineCap: .round))

            // Inner ring — the weekly window, when folded in.
            if let innerPercent {
                let innerExpired = innerResetsAt.map { $0 <= now } ?? false
                ArcShape(fraction: 1)
                    .stroke(Dial.track(scheme),
                            style: .init(lineWidth: innerLineWidth, lineCap: .round))
                    .padding(inset)
                ArcShape(fraction: Double(innerPercent) / 100)
                    .stroke(
                        innerExpired ? Dial.idle(scheme)
                                     : Dial.color(at: Double(innerPercent) / 100, scheme),
                        style: .init(lineWidth: innerLineWidth, lineCap: .round)
                    )
                    .padding(inset)
            }

            // The pace ghost. Longer than the live arc → you're under pace; swallowed by
            // it → you're over.
            if let pace, pace.expected > 0.01 {
                ArcShape(fraction: pace.expected)
                    .stroke(Dial.ghost(scheme),
                            style: .init(lineWidth: lineWidth, lineCap: .round))
            }

            // The live reading. Light comes off this, not off the panel.
            if !isExpired && percent > 0 {
                ArcShape(fraction: fraction)
                    .stroke(Dial.gradient(scheme),
                            style: .init(lineWidth: lineWidth, lineCap: .round))
                    .shadow(color: accent.opacity(Dial.glowOpacity(scheme)),
                            radius: lineWidth * 0.85)
            }

            readout
        }
        .frame(width: size, height: size)
    }

    private var readout: some View {
        VStack(spacing: 0) {
            if isExpired {
                Text("—")
                    .font(.system(size: size * 0.28, weight: .medium, design: .rounded))
                    .foregroundStyle(Dial.idle(scheme))
                Text("reset")
                    .font(.system(size: max(7, size * 0.095), weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Dial.meta(scheme))
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
                    .foregroundStyle(Dial.label(scheme))

                if showsCountdown, let left = UsageFormat.countdown(to: resetsAt, from: now) {
                    Text(left)
                        .font(.system(size: max(7, size * 0.088)).monospacedDigit())
                        .foregroundStyle(Dial.meta(scheme))
                        .padding(.top, 1)
                }
            }
        }
    }
}

// MARK: - Supporting readouts

/// A compact linear readout for the secondary limits, sized to sit beside a dial.
struct MiniMeter: View {
    var title: String
    var percent: Int
    var resetsAt: Date?
    var now: Date

    @Environment(\.colorScheme) private var scheme

    private var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    private var accent: Color {
        isExpired ? Dial.idle(scheme) : Dial.color(at: Double(percent) / 100, scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Dial.label(scheme))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isExpired {
                    Text("reset")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Dial.meta(scheme))
                } else {
                    Text("\(percent)%")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                    if let reset = UsageFormat.countdown(to: resetsAt, from: now) {
                        Text(reset)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(Dial.meta(scheme))
                            .lineLimit(1)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Dial.track(scheme))
                    Capsule()
                        .fill(accent)
                        .frame(width: geo.size.width * min(1, max(0, Double(percent) / 100)))
                        .shadow(color: isExpired ? .clear : accent.opacity(Dial.glowOpacity(scheme)),
                                radius: 3)
                }
            }
            .frame(height: 3.5)
        }
    }
}

/// Account name and plan, set as an instrument label.
struct AccountHeader: View {
    var account: AccountUsage
    var size: CGFloat = 12

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(account.label)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
            Text(account.plan.uppercased())
                .font(.system(size: max(7, size * 0.62), weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Dial.label(scheme))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Dial.track(scheme), in: .capsule)
            Spacer(minLength: 0)
        }
    }
}

/// The "as of …" marker. Cached numbers only refresh while Claude Code is running.
struct StalenessLabel: View {
    var account: AccountUsage
    var now: Date = Date()

    @Environment(\.colorScheme) private var scheme

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
                .lineLimit(1)
        }
        .foregroundStyle(isStale ? Dial.color(at: 0.8, scheme) : Dial.meta(scheme))
    }
}

/// Card surface for the larger layouts — a panel the dials sit on.
///
/// In the light scheme the panel is white and the page behind it is grey; a
/// near-white-on-white panel with a hairline border disappears entirely.
struct PanelBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                scheme == .dark ? Color.white.opacity(0.08)
                                                : Color.black.opacity(0.07),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.10),
                            radius: 7, y: 2)
            }
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}
