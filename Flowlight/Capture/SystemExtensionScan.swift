import Foundation

/// A system extension macOS knows about, as reported by `systemextensionsctl list`.
struct InstalledSystemExtension: Equatable, Identifiable, Sendable {
    var teamID: String
    var bundleID: String
    var name: String
    var version: String
    var state: String
    /// The category heading it was listed under, e.g. "network_extension".
    var category: String
    var isActive: Bool
    var id: String { bundleID + version }

    /// Content filters are the ones that matter: macOS runs one at a time, so an active one that isn't ours is
    /// the reason Flowlight's filter would be installed and yet never asked to filter anything.
    var isNetworkExtension: Bool { category.contains("network_extension") }
    var isOurs: Bool { bundleID == FlowlightConstants.extensionBundleIdentifier }
}

/// Reads the list of installed system extensions. Used to explain why the content filter isn't working: the
/// message "another product holds the one content-filter slot" is far more useful when it can name the product.
enum SystemExtensionScan {
    /// Parses `systemextensionsctl list` output. Separated from running it so the parsing is testable.
    ///
    /// The format is a category line starting with `---`, a header row, then tab-separated rows:
    /// `*\t*\tTEAMID\tcom.example.filter (1.0/1)\tDisplay Name\t[activated enabled]`
    static func parse(_ output: String) -> [InstalledSystemExtension] {
        var category = ""
        var found: [InstalledSystemExtension] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("---") {
                // "--- com.apple.system_extension.network_extension (Go to 'System Settings …')"
                category = line.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 6, columns[2] != "teamID", !columns[2].isEmpty else { continue }
            // "com.example.filter (1.0/1)" → identifier and version
            let identifier = columns[3]
            let bundleID = identifier.split(separator: " ").first.map(String.init) ?? identifier
            let version = identifier.firstIndex(of: "(").map { String(identifier[identifier.index(after: $0)...].dropLast()) } ?? ""
            found.append(InstalledSystemExtension(teamID: columns[2], bundleID: bundleID, name: columns[4],
                                                  version: version, state: columns[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                                                  category: category,
                                                  isActive: columns[0].contains("*") && columns[1].contains("*")))
        }
        return found
    }

    /// Other vendors' active network extensions — the ones that can take the content-filter slot.
    static func competingFilters(in extensions: [InstalledSystemExtension]) -> [InstalledSystemExtension] {
        extensions.filter { $0.isNetworkExtension && $0.isActive && !$0.isOurs }
    }

    /// Runs the tool. Never on the main thread: it spawns a process.
    static func read() async -> [InstalledSystemExtension] {
        await Task.detached(priority: .utility) { () -> [InstalledSystemExtension] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }
}
