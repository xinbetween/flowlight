import AppKit
import SwiftUI

/// App icons via NSWorkspace, cached by bundle path.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// The enclosing .app bundle of an executable path, if any.
    static func bundlePath(forExecutable path: String) -> String? {
        if let range = path.range(of: ".app/", options: .caseInsensitive) { return String(path[..<range.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    static func icon(forExecutable path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        let bundlePath: String
        if let range = path.range(of: ".app/", options: .caseInsensitive) {
            bundlePath = String(path[..<range.lowerBound]) + ".app"
        } else {
            bundlePath = path
        }
        if let hit = cache[bundlePath] { return hit }
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        cache[bundlePath] = image
        return image
    }
}

struct AppIconView: View {
    var path: String
    var size: CGFloat = 18

    var body: some View {
        if let bundle = AppIcons.bundlePath(forExecutable: path) {
            if FileManager.default.fileExists(atPath: bundle), let image = AppIcons.icon(forExecutable: path) {
                Image(nsImage: image).resizable().frame(width: size, height: size)
            } else {
                // App isn't installed here (e.g. data imported from another Mac): monogram instead of a blank page.
                let name = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: size * 0.22))
                    .accessibilityHidden(true)
            }
        } else {
            // Bare executables have no icon of their own; a symbol reads better than a blank document.
            let isSystem = path.isEmpty || path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            Image(systemName: isSystem ? "gearshape.fill" : "terminal.fill")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(isSystem ? Color.gray : Color(red: 0.2, green: 0.24, blue: 0.3), in: RoundedRectangle(cornerRadius: size * 0.22))
                .accessibilityHidden(true)
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .motion(Motion.value, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum TrafficColors {
    static let inbound = Color.blue
    static let outbound = Color.orange
    static let anomaly = Color.red
}

/// Opens the first window at the size of the screen, so everything Flowlight shows has room. It runs once: after
/// that macOS restores whatever size the person chose.
/// Sizes the main window on a first run, then remembers where it was left.
///
/// `setFrameAutosaveName` looks like the answer and quietly isn't: SwiftUI's `WindowGroup` owns the window's
/// restoration, so the name is rejected and nothing is ever written. Watching the window and storing the frame
/// is a few more lines and actually works.
struct WindowSizer: NSViewRepresentable {
    private static let key = "window.mainFrame"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if let saved = UserDefaults.standard.string(forKey: Self.key) {
                let frame = NSRectFromString(saved)
                // A screen that has gone away — an unplugged display — would leave the window somewhere
                // unreachable. So would a frame saved on a larger display, or one that was nudged off the right
                // edge: it still overlaps the screen, so a bare intersection test keeps it, and the window comes
                // back half outside the visible area. Fit it instead of asking whether it is hopeless.
                let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
                window.setFrame(screen.map { Self.fit(frame, in: $0.visibleFrame) } ?? frame, display: true, animate: false)
            } else if let screen = window.screen ?? NSScreen.main {
                // Nothing saved: fill the screen so a first run doesn't hide most of the app in a small window.
                window.setFrame(screen.visibleFrame, display: true, animate: false)
            }
            coordinator.watch(window, key: Self.key)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    /// A saved frame, brought back inside the screen that will show it: no larger than the visible area, and moved
    /// rather than resized when it only needs moving, so a window someone sized deliberately keeps its size.
    static func fit(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var fitted = frame
        fitted.size.width = min(fitted.width, visible.width)
        fitted.size.height = min(fitted.height, visible.height)
        fitted.origin.x = min(max(fitted.minX, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, visible.minY), visible.maxY - fitted.height)
        return fitted
    }

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []

        func watch(_ window: NSWindow, key: String) {
            guard observers.isEmpty else { return }
            let save = { [weak window] (_: Notification) in
                guard let window, window.isVisible else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
            }
            let center = NotificationCenter.default
            // didResize covers a programmatic change too; didEndLiveResize alone misses everything but a drag.
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main, using: save))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

