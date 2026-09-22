import Foundation

enum FlowlightConstants {
    /// App Group shared by the host app and the system extension. The Info.plist value is
    /// `$(TeamIdentifierPrefix)com.flowlight.shared`; unsigned builds fall back to the bare suffix.
    static let appGroupSuffix = "com.flowlight.shared"

    static var appGroupIdentifier: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "FLAppGroupIdentifier") as? String,
           !value.isEmpty, !value.hasPrefix("$"), !value.hasPrefix(".") {
            return value
        }
        return appGroupSuffix
    }

    /// Mach service vended by the extension (must be prefixed with the App Group).
    static var machServiceName: String { appGroupIdentifier + ".xpc" }

    /// Team ID derived from the App Group prefix; nil for unsigned builds.
    static var teamIdentifier: String? {
        let group = appGroupIdentifier
        guard group != appGroupSuffix, group.hasSuffix("." + appGroupSuffix) else { return nil }
        return String(group.dropLast(appGroupSuffix.count + 1))
    }

    static let hostBundleIdentifier = "com.flowlight.app"
    static let extensionBundleIdentifier = "com.flowlight.app.filter"
}
