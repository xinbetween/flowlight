import Foundation

/// Which windows are genuinely on screen.
///
/// The answer gates the expensive half of every tick — the live chart series and the per-app list — so getting it
/// wrong is not a visual bug, it is a battery bug that nothing on screen reveals.
///
/// Membership follows `NSWindow.occlusionState` rather than SwiftUI's `onAppear`/`onDisappear`. The view lifecycle
/// only says the window *exists*: it stays "appeared" while the window is minimised, fully covered by another
/// app, or on a Space nobody is looking at. In all three the chart was still being rebuilt every second for an
/// audience of nobody. Occlusion is the state that actually answers "can anyone see this".
///
/// A set rather than a counter, because occlusion notifications are not guaranteed to pair up. A window closed
/// while already occluded, or one teardown missed, leaks a count — and a leaked count pins visibility to `true`
/// for the rest of the session, silently restoring the cost this exists to remove. Keying on identity makes every
/// update idempotent, so a repeat cannot drift the state.
struct WindowVisibility {
    /// What an update did to the *overall* state, which is all the caller acts on.
    enum Change: Equatable {
        case unchanged
        case becameVisible
        case becameHidden
    }

    private var visible: Set<ObjectIdentifier> = []

    var isVisible: Bool { !visible.isEmpty }

    /// Record one window's visibility. Safe to call repeatedly with the same value.
    @discardableResult
    mutating func update(_ window: AnyObject, isVisible: Bool) -> Change {
        let was = self.isVisible
        let id = ObjectIdentifier(window)
        if isVisible { visible.insert(id) } else { visible.remove(id) }
        let now = self.isVisible
        if was == now { return .unchanged }
        return now ? .becameVisible : .becameHidden
    }
}
