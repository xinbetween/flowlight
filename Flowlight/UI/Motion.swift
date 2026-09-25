import SwiftUI

/// One vocabulary for movement, so the app moves in a way that feels like one app.
///
/// Flowlight shows live data, which puts a limit on how playful this can be: an animation that lags reality is
/// worse than no animation, because the number on screen stops being the number. So the rules are narrow.
/// Movement marks a **change of state** — something arrived, something was selected, a view appeared — and never
/// decorates a value that is already correct. Nothing here moves layout under the pointer, because a monitoring
/// tool whose own window shifts while you are reading it is arguing against itself.
///
/// Everything respects Reduce Motion. Not as a courtesy: on this screen the moving parts are often the alarming
/// parts, and someone who has asked the system for less movement has asked for a reason.
enum Motion {
    /// A view arriving or leaving.
    static let appear = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// A control responding to a click or a hover.
    static let control = Animation.easeOut(duration: 0.16)
    /// A number or a chart settling on a new value.
    static let value = Animation.easeInOut(duration: 0.45)
    /// Something that repeats while a state lasts — a pulse while capture is live.
    static let breathing = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)

    /// How a new turn, row or card enters. Opacity plus a small rise, never a slide across, because a horizontal
    /// slide reads as navigation and nothing has navigated.
    static var entrance: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }
}

extension View {
    /// Applies an animation unless the person has asked the system for less movement.
    func motion<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// A view that fades and rises in as it appears.
    func entrance() -> some View {
        modifier(EntranceModifier())
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct EntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (shown ? 1 : 0))
            .offset(y: reduceMotion ? 0 : (shown ? 0 : 8))
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(Motion.appear) { shown = true }
            }
    }
}

/// A dot that breathes while something is live, and sits still when it isn't.
///
/// The pulse is the point: a green dot and a green dot that is alive look identical in a screenshot, and "is it
/// actually running?" is the question this screen exists to answer.
struct LiveDot: View {
    var color: Color
    var active: Bool
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                // A ring that swells and fades outwards. Drawn outside the dot so the dot itself never changes
                // size — a pulsing dot in a list makes the row it sits in twitch.
                if active && !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .scaleEffect(breathing ? 2.1 : 1)
                        .opacity(breathing ? 0 : 0.7)
                }
            }
            .onChange(of: active, initial: true) { _, on in
                breathing = false
                guard on, !reduceMotion else { return }
                withAnimation(Motion.breathing) { breathing = true }
            }
    }
}

/// A number that counts to its new value instead of jumping.
///
/// Only for figures that settle — a total for a finished window, a summary tile. Never for a live rate: counting
/// towards a number that has already changed again shows something that was never true.
struct CountingNumber: View, Animatable {
    var value: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

/// How wide content is allowed to get, and where it sits when the window is wider than that.
///
/// Five screens had grown five different answers to this — 860, 860, 820, 760 and 720 points — and three of them
/// centred the result while two left-aligned it. On a wide display that put the Rules list in the middle of the
/// window while the Capture form started at the left margin, which reads as two apps rather than one.
///
/// The rule: content is capped so a line of text never runs the full width of a large display, and it is always
/// **left-aligned**, because everything else in the app starts at the same left margin — tables, titles, the
/// sidebar. Centring a column inside a left-aligned app is the thing that looked wrong.
enum Measure {
    /// Prose someone reads a paragraph of: an answer, an explanation. Roughly eighty characters at the body size,
    /// which is about where a line stops being comfortable to track back from.
    static let prose: CGFloat = 720
    /// Cards, forms and rows with a control at each end. Wider, because the eye isn't reading these left to right
    /// so much as scanning down them — but not unbounded, or the control ends up an inch from the thing it acts on.
    static let panel: CGFloat = 860
    /// The gutter between content and the window edge, the same on every screen.
    static let gutter: CGFloat = 16
}

extension View {
    /// Caps the width and keeps the content against the left margin, which is where the rest of the app starts.
    func measured(_ width: CGFloat = Measure.panel) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
