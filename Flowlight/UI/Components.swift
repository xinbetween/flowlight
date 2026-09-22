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
