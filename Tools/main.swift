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

@MainActor
func main() {
    let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
    // Prefer the user's real snapshot; fall back to sample data.
    let snapshot = SnapshotStore.read() ?? .placeholder
    let now = Date()

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
            render(view, size: size, scheme: scheme, to: "\(outputDir)/\(name)-\(suffix).png")
        }
    }
}

// Top-level code already runs on the main thread; this just tells the compiler so.
MainActor.assumeIsolated { main() }
