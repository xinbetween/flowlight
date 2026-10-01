import AppKit
import SwiftUI

/// Flowlight's design tokens — one place for the brand palette, spacing, radii and the shared surfaces, so the app
/// reads as one considered system instead of scattered literals. The colours are the same ones the website uses,
/// each resolved for light and dark, because the app follows the system appearance.
///
/// Semantic roles, not raw hues: `accent` is the one "light" colour, reserved for what needs a decision; `received`
/// and `sent` carry traffic direction; `critical`/`warning`/`good` are status only and never stand in for the accent.
enum FL {
    // Surfaces, deepest to lightest ink.
    static let ground      = Color(light: 0xf4f5f8, dark: 0x0d0f16)
    static let surface     = Color(light: 0xffffff, dark: 0x151824)
    static let surfaceDeep = Color(light: 0xf0f1f6, dark: 0x10131d)
    static let surface2    = Color(light: 0xeceef4, dark: 0x1c2030)
    static let line        = Color(light: 0xdde0e8, dark: 0x262b3b)

    // Text.
    static let ink   = Color(light: 0x11131a, dark: 0xeef0f6)
    static let muted = Color(light: 0x565d70, dark: 0xa3a9bb)
    static let faint = Color(light: 0x8a90a2, dark: 0x737a8f)

    // Semantic.
    static let accent   = Color(light: 0x4a3aa7, dark: 0x9085e9)
    static let received = Color(light: 0x2a78d6, dark: 0x4a93ea)
    static let sent     = Color(light: 0xd95926, dark: 0xe5723f)
    static let critical = Color(light: 0xc93b33, dark: 0xec6a62)
    static let warning  = Color(light: 0xb86e00, dark: 0xe0a13a)
    static let good     = Color(light: 0x1f9d6b, dark: 0x4fb98a)
    /// Tools and MCP servers — a violet kept distinct from the primary accent so "something ran" reads apart from
    /// "something needs a decision".
    static let tool     = Color(light: 0x6f4bc7, dark: 0xb4a2f2)
}

/// Consistent spacing, so groups line up and gaps read as intentional rather than arbitrary.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Corner radii by role: a chip is tighter than a card, a card tighter than a panel.
enum Radius {
    static let chip: CGFloat = 8
    static let card: CGFloat = 12
    static let panel: CGFloat = 16
}

extension Color {
    /// A colour that resolves differently in light and dark, like an asset-catalog colour set but defined in code so
    /// the whole palette lives in one file. `0xRRGGBB`.
    init(light: Int, dark: Int) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255, alpha: 1)
    }
}

/// The one card surface the app uses, replacing the three slightly different `.quaternary` rounded rectangles that
/// grew up across the screens. A faint top-to-bottom gradient gives depth without a heavy shadow; `accent: true`
/// tints it for the one card that asks the user to act (the always-monitor banner).
struct FLCard: ViewModifier {
    var radius: CGFloat = Radius.card
    var accent: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(accent
                          ? AnyShapeStyle(FL.accent.opacity(0.09))
                          : AnyShapeStyle(LinearGradient(colors: [FL.surface, FL.surfaceDeep],
                                                         startPoint: .top, endPoint: .bottom)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent ? FL.accent.opacity(0.28) : FL.line, lineWidth: 1)
            )
    }
}

extension View {
    func flCard(radius: CGFloat = Radius.card, accent: Bool = false) -> some View {
        modifier(FLCard(radius: radius, accent: accent))
    }
}

/// A small status pill — a label and icon on a tinted, bordered capsule, never colour alone. The one chip style for
/// risk badges, allowlist state and anything else that marks a value's status at a glance.
struct FLPill: View {
    var text: String
    var systemImage: String?
    var color: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.32), lineWidth: 1))
        .foregroundStyle(color)
    }
}

/// A single-line trend, drawn to its own min/max so the shape reads even for small ranges. Shown only with real
/// data — never a decorative squiggle.
struct Sparkline: View {
    var points: [Double]
    var color: Color = FL.accent

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lo = points.min() ?? 0, hi = points.max() ?? 1
            let span = max(hi - lo, 0.0001)
            Path { path in
                for (i, v) in points.enumerated() {
                    let x = points.count <= 1 ? 0 : w * CGFloat(i) / CGFloat(points.count - 1)
                    let y = h - CGFloat((v - lo) / span) * h
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

/// An inline magnitude bar — a value's share of the largest in its column, so a table reads as a chart too.
struct TrafficBar: View {
    var fraction: Double
    var color: Color = FL.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FL.surface2)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }
}
