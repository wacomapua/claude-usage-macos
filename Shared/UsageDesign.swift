import SwiftUI

// MARK: - Design tokens
//
// The face of a real instrument: a graduated rim, a thick gradient arc with a lit knob
// riding its tip, and panels with enough depth to sit under the dial rather than behind
// it. Hairline strokes and flat grey fills read as monitoring software; weight, depth
// and a single point of light read as a device.
//
// The scale is defined twice. Luminous accents look superb on graphite and wash out to
// nothing on white, so the light scheme gets its own deeper ramp rather than the dark
// one at reduced opacity.

enum Dial {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Dark scheme: lit from behind.
    private static let darkScale: [(at: Double, color: RGB)] = [
        (0.00, (0.231, 0.910, 0.690)),  // mint    #3BE8B0
        (0.45, (1.000, 0.776, 0.420)),  // amber   #FFC66B
        (0.75, (1.000, 0.541, 0.420)),  // coral   #FF8A6B
        (1.00, (1.000, 0.361, 0.478)),  // rose    #FF5C7A
    ]

    /// Light scheme: the same hues taken down into ink, so they hold on near-white.
    private static let lightScale: [(at: Double, color: RGB)] = [
        (0.00, (0.031, 0.639, 0.482)),  // deep teal   #08A37B
        (0.45, (0.788, 0.541, 0.071)),  // dark amber  #C98A12
        (0.75, (0.831, 0.329, 0.122)),  // burnt ember #D4541F
        (1.00, (0.784, 0.118, 0.271)),  // deep rose   #C81E45
    ]

    static func scale(_ scheme: ColorScheme) -> [(at: Double, color: RGB)] {
        scheme == .dark ? darkScale : lightScale
    }

    static func swatch(_ c: RGB) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// Blend a colour toward white (positive) or black (negative).
    static func mix(_ c: RGB, toward target: Double, by amount: Double) -> RGB {
        (r: c.r + (target - c.r) * amount,
         g: c.g + (target - c.g) * amount,
         b: c.b + (target - c.b) * amount)
    }

    /// The raw colour at a point on the scale, interpolated between stops.
    static func rgb(at fraction: Double, _ scheme: ColorScheme) -> RGB {
        let stops = scale(scheme)
        let f = min(1, max(0, fraction))

        guard let upperIndex = stops.firstIndex(where: { $0.at >= f }) else {
            return stops[stops.count - 1].color
        }
        guard upperIndex > 0 else { return stops[0].color }

        let lower = stops[upperIndex - 1], upper = stops[upperIndex]
        let span = upper.at - lower.at
        let t = span <= 0 ? 0 : (f - lower.at) / span
        return (r: lower.color.r + (upper.color.r - lower.color.r) * t,
                g: lower.color.g + (upper.color.g - lower.color.g) * t,
                b: lower.color.b + (upper.color.b - lower.color.b) * t)
    }

    static func color(at fraction: Double, _ scheme: ColorScheme) -> Color {
        swatch(rgb(at: fraction, scheme))
    }

    /// The two ends of a single arc's sweep — lighter where it starts, saturated at the
    /// tip. A designed gradient rather than a temperature ramp: the hue carries severity,
    /// the gradient carries depth.
    static func arcEnds(at fraction: Double, _ scheme: ColorScheme) -> (start: Color, tip: Color) {
        let base = rgb(at: fraction, scheme)
        if scheme == .dark {
            return (swatch(mix(base, toward: 1, by: 0.34)), swatch(base))
        }
        return (swatch(mix(base, toward: 1, by: 0.22)), swatch(mix(base, toward: 0, by: 0.12)))
    }

    /// A 270° sweep with the gap at the bottom — the open-bottom face of a rev counter.
    static let startDegrees: Double = 135
    static let sweepDegrees: Double = 270
    static var sweepFraction: Double { sweepDegrees / 360 }

    /// Where the redline band begins, as a fraction of the scale.
    static let redlineStart: Double = 0.85

    /// The whole scale, cool through hot, for painting the unfilled arc. Drawn
    /// dim beneath the reading so the dial shows its full range at a glance.
    static func scaleGradient(_ scheme: ColorScheme) -> AngularGradient {
        let stops = scale(scheme)
        var gradientStops = stops.map {
            Gradient.Stop(color: swatch($0.color), location: $0.at * sweepFraction)
        }
        gradientStops.append(.init(color: swatch(stops[0].color), location: 1))
        return AngularGradient(
            gradient: Gradient(stops: gradientStops),
            center: .center,
            startAngle: .degrees(startDegrees),
            endAngle: .degrees(startDegrees + 360)
        )
    }

    /// Distinct hues per model family. Severity uses the cool-to-hot ramp, so the
    /// model mix needs its own palette or the two readings would be confused.
    static func modelColor(_ family: String, _ scheme: ColorScheme) -> Color {
        let dark: [String: RGB] = [
            "Opus":   (0.545, 0.475, 1.000),  // #8B79FF violet
            "Fable":  (1.000, 0.451, 0.784),  // #FF73C8 magenta
            "Sonnet": (0.322, 0.686, 1.000),  // #52AFFF blue
            "Haiku":  (0.239, 0.855, 0.784),  // #3DDAC8 teal
        ]
        let light: [String: RGB] = [
            "Opus":   (0.361, 0.259, 0.859),
            "Fable":  (0.780, 0.161, 0.549),
            "Sonnet": (0.078, 0.451, 0.792),
            "Haiku":  (0.020, 0.545, 0.494),
        ]
        let table = scheme == .dark ? dark : light
        return swatch(table[family] ?? (scheme == .dark ? (0.6, 0.6, 0.65) : (0.45, 0.45, 0.5)))
    }

    // Explicit greys rather than the system hierarchy: `.tertiary` on a light background
    // is far too faint for 8pt type, which is most of what this widget is made of.
    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.06)
    }

    static func graduation(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.14)
    }

    static func label(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.60) : .black.opacity(0.56)
    }

    static func meta(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.44) : .black.opacity(0.42)
    }

    /// A window that has rolled over: present, but carrying no live reading.
    static func idle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.32) : .black.opacity(0.30)
    }

    /// Depth under the arc, not a halo around it — a wide soft glow reads as smudge.
    static func glow(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.5 : 0.14
    }
}

/// The arc itself. A real `Shape` rather than a rotated, trimmed `Circle` so the angular
/// gradient lines up with actual screen angles instead of drifting with the rotation.
struct ArcShape: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
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
// It's drawn as a second, dimmed arc set inside the live one. Comparing two arc lengths
// is immediate, and it keeps the face clean — a tick sitting off the end of the fill
// reads as debris whether or not there's a scale behind it.

struct Pace {
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

    @Environment(\.colorScheme) private var scheme

    /// Thick enough to have presence. A hairline ring reads as a chart, not a reading.
    private var lineWidth: CGFloat { max(5, size * 0.115) }

    private var showsCountdown: Bool { size >= 84 }
    /// Below this the inset reference arc is too fine to read.
    private var showsPace: Bool { size >= 74 }

    /// The cached window has already rolled over, so this figure is history.
    private var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    private var fraction: Double { min(1, max(0, Double(percent) / 100)) }
    private var ends: (start: Color, tip: Color) { Dial.arcEnds(at: fraction, scheme) }
    private var pace: Pace? {
        isExpired ? nil : Pace(percent: percent, resetsAt: resetsAt, window: window, now: now)
    }

    /// Stops laid so the gradient spans exactly the drawn arc, then returns to the
    /// starting hue across the dial's blind spot. Without that return the seam sits on
    /// the start angle and the round cap — which overhangs it — picks up the far end.
    private var arcGradient: AngularGradient {
        let tipLocation = max(0.02, fraction * Dial.sweepFraction)
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: ends.start, location: 0),
                .init(color: ends.tip, location: tipLocation),
                .init(color: ends.start, location: 1),
            ]),
            center: .center,
            startAngle: .degrees(Dial.startDegrees),
            endAngle: .degrees(Dial.startDegrees + 360)
        )
    }

    /// The bright core inside the channel. Kept well under the band width — the
    /// whole effect depends on the halo reading as the *channel* and this as the
    /// light travelling through it.
    private var filamentWidth: CGFloat { lineWidth * 0.34 }

    var body: some View {
        ZStack {
            // The empty channel.
            ArcShape(fraction: 1)
                .stroke(Dial.track(scheme), style: .init(lineWidth: lineWidth, lineCap: .round))

            // The scale. A tachometer shows its whole range, not just the needle —
            // the unfilled arc carries the full cool-to-hot ramp at low opacity so
            // the face reads as an instrument even at 6%.
            ArcShape(fraction: 1)
                .stroke(Dial.scaleGradient(scheme), style: .init(lineWidth: lineWidth, lineCap: .round))
                .opacity(scheme == .dark ? 0.22 : 0.18)

            // The redline. Where the scale stops being advisory.
            ArcShape(fraction: 1)
                .trim(from: Dial.redlineStart, to: 1)
                .stroke(Dial.color(at: 1, scheme),
                        style: .init(lineWidth: lineWidth, lineCap: .butt))
                .opacity(fraction >= Dial.redlineStart ? 0 : (scheme == .dark ? 0.42 : 0.30))

            // The pace reference, as a thin arc inset inside the main band. Drawn at
            // full width it competes with the reading — the eye takes the longest arc
            // for the value, which at low usage says the opposite of the truth.
            if showsPace, let pace, pace.expected > 0.01 {
                ArcShape(fraction: pace.expected)
                    .stroke(Dial.graduation(scheme), style: .init(lineWidth: 2.5, lineCap: .round))
                    .padding(lineWidth * 0.5 + 3.5)
            }

            if !isExpired && percent > 0 {
                // Two passes make the reading a lit tube rather than a painted
                // stroke: a wide soft flood the width of the channel, and a narrow
                // filament burning at full strength down the middle of it.
                ArcShape(fraction: fraction)
                    .stroke(arcGradient, style: .init(lineWidth: lineWidth, lineCap: .round))
                    .opacity(scheme == .dark ? 0.34 : 0.28)
                    .blur(radius: lineWidth * 0.18)

                ArcShape(fraction: fraction)
                    .stroke(arcGradient, style: .init(lineWidth: filamentWidth, lineCap: .round))
                    .shadow(color: ends.tip.opacity(Dial.glow(scheme)), radius: lineWidth * 0.42)
                    .shadow(color: ends.tip.opacity(Dial.glow(scheme) * 0.5), radius: lineWidth)
            }

            readout
        }
        .frame(width: size, height: size)
    }

    private var readout: some View {
        VStack(spacing: 0) {
            if isExpired {
                Text("—")
                    .font(.system(size: size * 0.26, weight: .medium, design: .rounded))
                    .foregroundStyle(Dial.idle(scheme))
                Text("reset")
                    .font(.system(size: max(7, size * 0.092), weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Dial.meta(scheme))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(percent)")
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded)
                            .monospacedDigit())
                        .tracking(-size * 0.012)
                    Text("%")
                        .font(.system(size: size * 0.145, weight: .bold, design: .rounded))
                        .baselineOffset(size * 0.015)
                }
                .foregroundStyle(ends.tip)

                Text(caption)
                    .font(.system(size: max(7, size * 0.092), weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Dial.label(scheme))
                    .padding(.top, size * 0.012)

                if showsCountdown, let left = UsageFormat.countdown(to: resetsAt, from: now) {
                    Text(left)
                        .font(.system(size: max(7, size * 0.085)).monospacedDigit())
                        .foregroundStyle(Dial.meta(scheme))
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

    private var ends: (start: Color, tip: Color) {
        Dial.arcEnds(at: Double(percent) / 100, scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Dial.label(scheme))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isExpired {
                    Text("reset")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Dial.meta(scheme))
                } else {
                    Text("\(percent)%")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(ends.tip)
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
                    if !isExpired && percent > 0 {
                        Capsule()
                            .fill(LinearGradient(colors: [ends.start, ends.tip],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(5, geo.size.width * min(1, Double(percent) / 100)))
                            .shadow(color: ends.tip.opacity(Dial.glow(scheme)), radius: 3)
                    }
                }
            }
            .frame(height: 5)
        }
    }
}

/// Hourly token burn over the recent past. The one view here with real history —
/// the usage cache is a single instantaneous reading, but the transcripts record
/// every turn, so the shape of a working day is recoverable.
struct BurnSparkline: View {
    var buckets: [HourBucket]
    var height: CGFloat = 22

    @Environment(\.colorScheme) private var scheme

    private var peak: Int { max(1, buckets.map(\.tokens).max() ?? 1) }

    /// Value at index, 0–1 against the peak.
    private func share(_ index: Int) -> Double {
        guard buckets.indices.contains(index) else { return 0 }
        return Double(buckets[index].tokens) / Double(peak)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let count = max(buckets.count, 2)
        let step = size.width / CGFloat(count - 1)
        // Leave a sliver of headroom so the peak's stroke isn't clipped.
        let usable = size.height - 2
        return (0..<count).map { index in
            CGPoint(x: CGFloat(index) * step,
                    y: size.height - 1 - usable * share(index))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            let accent = Dial.color(at: 0.35, scheme)

            ZStack(alignment: .bottom) {
                // Baseline, so an idle stretch reads as a floor rather than a gap.
                Rectangle()
                    .fill(Dial.track(scheme))
                    .frame(height: 1)

                // Filled area under the curve, fading out downward.
                Path { path in
                    guard let first = pts.first, let last = pts.last else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for point in pts { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [accent.opacity(scheme == .dark ? 0.55 : 0.40), accent.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ))

                // The curve itself, lit.
                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for point in pts.dropFirst() { path.addLine(to: point) }
                }
                .stroke(accent, style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(scheme == .dark ? 0.7 : 0.2), radius: 3)
            }
        }
        .frame(height: height)
    }
}

/// One dial's worth of light in the room.
struct Bloom: Hashable {
    var percent: Int
    var anchor: UnitPoint
    var radius: CGFloat
}

/// A soft radial wash behind the whole widget, one source per dial, each tinted by
/// its own reading.
///
/// The one deliberately atmospheric element: it lets the surface take on the mood of
/// the numbers without putting saturated colour anywhere near the type. Kept under
/// 15% so it reads as light rather than as a coloured background.
///
/// It has to sit at the widget root, not behind each account block. A radial
/// gradient painted behind a block is clipped to that block's rectangle, and
/// wherever it hasn't faded to zero by the edge you get a visible hard-edged box.
/// At the root the only boundary is the widget's own rounded outline.
struct BloomBackdrop: ViewModifier {
    var blooms: [Bloom]

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                ForEach(blooms, id: \.self) { bloom in
                    let accent = Dial.color(at: Double(bloom.percent) / 100, scheme)
                    RadialGradient(
                        colors: [accent.opacity(scheme == .dark ? 0.16 : 0.10), accent.opacity(0)],
                        center: bloom.anchor,
                        startRadius: 0,
                        endRadius: bloom.radius
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func bloomBackdrop(_ blooms: [Bloom]) -> some View {
        modifier(BloomBackdrop(blooms: blooms))
    }
}

/// Output-token share per model family, as one stacked bar.
struct ModelMixBar: View {
    var models: [ModelSlice]
    var height: CGFloat = 4
    var showsLegend: Bool = true

    @Environment(\.colorScheme) private var scheme

    private var total: Int { max(1, models.reduce(0) { $0 + $1.tokens }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(models) { model in
                        Rectangle()
                            .fill(Dial.modelColor(model.family, scheme))
                            .frame(width: max(2, geo.size.width * Double(model.tokens) / Double(total)))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: height)

            if showsLegend {
                HStack(spacing: 8) {
                    ForEach(models.prefix(3)) { model in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Dial.modelColor(model.family, scheme))
                                .frame(width: 5, height: 5)
                            Text(model.family)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Dial.label(scheme))
                            Text("\(Int((Double(model.tokens) / Double(total) * 100).rounded()))%")
                                .font(.system(size: 8.5).monospacedDigit())
                                .foregroundStyle(Dial.meta(scheme))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A labelled figure — the building block for the token and cost readouts.
struct StatReadout: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color?
    var size: CGFloat = 15

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Dial.label(scheme))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint ?? Color.primary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Dial.meta(scheme))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

/// Account name and plan, set as an instrument label.
struct AccountHeader: View {
    var account: AccountUsage
    var size: CGFloat = 12

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(account.label)
                .font(.system(size: size, weight: .bold))
                .tracking(-0.2)
                .lineLimit(1)
            Text(account.plan.uppercased())
                .font(.system(size: max(7, size * 0.58), weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Dial.label(scheme))
                .padding(.horizontal, 5).padding(.vertical, 2)
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
            if account.isLive {
                // Live figures need no staleness caveat — say so, and say it in the
                // calm end of the palette so it reads as reassurance, not alarm.
                Circle()
                    .fill(Dial.color(at: 0, scheme))
                    .frame(width: 5, height: 5)
                    .shadow(color: Dial.color(at: 0, scheme).opacity(0.8), radius: 3)
                Text("live")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Dial.color(at: 0, scheme))
            } else {
                if isStale {
                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 8))
                }
                Text(UsageFormat.age(of: account.fetchedAt, from: now))
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(isStale ? Dial.color(at: 0.8, scheme) : Dial.meta(scheme))
            }
        }
    }
}

/// Card surface for the app window.
///
/// Deliberately not used inside the widgets: a card drawn on a widget is a box inside a
/// box, and the extra border competes with the dial for attention. The widgets separate
/// accounts with space and a hairline instead.
struct PanelBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.09),
                            radius: 9, y: 3)
            }
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

/// Separator used between accounts inside the widgets.
struct Hairline: View {
    var axis: Axis = .horizontal

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
        Rectangle()
            .fill(color)
            .frame(width: axis == .vertical ? 1 : nil,
                   height: axis == .horizontal ? 1 : nil)
    }
}
