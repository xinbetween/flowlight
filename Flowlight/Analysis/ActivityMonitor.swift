import AppKit
import Foundation

protocol ActivitySnapshotting: AnyObject, Sendable {
    /// Seconds since the GUI app was last frontmost; nil if not a running GUI app or currently frontmost.
    func idleDuration(bundleID: String) -> TimeInterval?
    /// Seconds since the last keyboard/mouse/trackpad input anywhere (the user is "away").
    func systemIdleSeconds() -> TimeInterval
}

extension ActivitySnapshotting {
    func systemIdleSeconds() -> TimeInterval { 0 }
}

/// Tracks when each GUI app was last frontmost, to spot traffic from apps with no UI activity.
final class ActivityMonitor: ActivitySnapshotting, @unchecked Sendable {
    private let lock = NSLock()
    private var lastActive: [String: Date] = [:]
    private var regularApps: Set<String> = []
    private var frontmost: String?
    private let startedAt = Date()
    private var observers: [NSObjectProtocol] = []

    @MainActor
    func start() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.handle(name: note.name, app: app) }
            })
        }
    }

    @MainActor
    private func handle(name: Notification.Name, app: NSRunningApplication?) {
        // The previously frontmost app was in use until this moment.
        lock.lock()
        if let previous = frontmost { lastActive[previous] = Date() }
        lock.unlock()
        refreshRunning()
    }

    @MainActor
    private func refreshRunning() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.lock()
        regularApps = Set(apps)
        frontmost = front
        if let front { lastActive[front] = Date() }
        lock.unlock()
    }

    func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func idleDuration(bundleID: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard regularApps.contains(bundleID), frontmost != bundleID else { return nil }
        return Date().timeIntervalSince(lastActive[bundleID] ?? startedAt)
    }
}
