import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when someone clicks an update notification, so the app can bring up the update window.
    static let flowlightOpenUpdate = Notification.Name("flowlight.openUpdate")
}

/// Handles clicks on Flowlight's notifications, and lets them show while the app is in front.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Notifier.updateCategory else { return }
        await MainActor.run { NotificationCenter.default.post(name: .flowlightOpenUpdate, object: nil) }
    }
}

enum Notifier {
    static let updateCategory = "flowlight.update"

    /// Always registered, so clicking a notification opens the right place even when alerts are switched off.
    static func configure() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    static func requestAuthorization() {
        configure()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Tells the person a new version is out. Clicking it opens the update window.
    static func postUpdate(version: String, summary: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Flowlight \(version) is available"
        content.body = summary ?? "Click to see what's new and install it."
        content.categoryIdentifier = updateCategory
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "flowlight.update.\(version)", content: content, trigger: nil))
    }

    /// Something connected or went away on a channel that isn't the network. Only the arrivals are worth a
    /// notification — a device disconnecting is usually you walking out of the room — and only when notifications
    /// are on at all, like every other kind.
    static func post(devices events: [DeviceEvent]) {
        guard UserDefaults.standard.bool(forKey: AnomalySettings.Keys.notifications) else { return }
        let arrivals = events.filter { $0.change == .connected || $0.change == .appeared }
        guard !arrivals.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if arrivals.count == 1, let event = arrivals.first {
            content.title = "\(event.change.title): \(event.name)"
            content.body = event.detail.isEmpty ? event.kind.title : "\(event.kind.title) · \(event.detail)"
        } else {
            content.title = "\(arrivals.count) devices connected"
            content.body = arrivals.prefix(3).map(\.name).joined(separator: ", ")
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func post(_ alerts: [AlertRecord]) {
        guard UserDefaults.standard.bool(forKey: AnomalySettings.Keys.notifications) else { return }
        let important = alerts.filter { $0.severity >= 2 }
        guard !important.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if important.count == 1, let alert = important.first {
            content.title = "\(alert.kind): \(alert.appName)"
            content.body = alert.detail
        } else {
            content.title = "\(important.count) network anomalies"
            content.body = important.prefix(3).map { "\($0.appName): \($0.kind)" }.joined(separator: "\n")
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    /// Short form for the menu bar, e.g. "1.2M", "830K".
    static func compact(_ bytes: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(0, bytes)
        var index = 0
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        return value < 10 && index > 0 ? String(format: "%.1f%@", value, units[index]) : String(format: "%.0f%@", value, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        string(Int64(bytesPerSecond)) + "/s"
    }
}
