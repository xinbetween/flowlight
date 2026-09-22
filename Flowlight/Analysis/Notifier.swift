import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
