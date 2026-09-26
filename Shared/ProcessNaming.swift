import Foundation

/// What to call a process that isn't inside an `.app` bundle.
///
/// The obvious answer — the executable's filename — is wrong for the installers that keep one file per release.
/// Claude Code's native install is `~/.local/share/claude/versions/2.1.283`, so the filename *is* the version:
/// naming the process after it splits one agent into a new identity on every update, and takes its allowlist,
/// its guardrails and its inspected history with it. The tool's own directory is the stable name.
///
/// Both capture engines need the same answer. The sampler and the Network Extension resolve processes through
/// different APIs, and when they disagree the same agent appears twice — once per engine.
enum ProcessNaming {
    /// Directories that name a layout rather than a tool, so they are never the answer.
    static let genericDirectories: Set<String> = ["bin", "sbin", "libexec", "versions", "current", "latest",
                                                  "lib", "share", "local", "macos"]

    /// The last path component that reads like a name: it contains a letter, isn't a version, isn't one of the
    /// layout directories above, and isn't a dotted support folder (`.local`, `.claude`). Empty when nothing
    /// qualifies, which leaves the caller with its own fallbacks (`proc_name`, then the pid).
    static func displayName(fromPathComponents components: [String]) -> String {
        for component in components.reversed() {
            let lower = component.lowercased()
            if component.contains(where: \.isLetter), !isVersion(component), !genericDirectories.contains(lower),
               !lower.hasPrefix(".") {
                return component
            }
        }
        return ""
    }

    /// `2.1.283`, `v2.1.283`, `20.11.0-1` — digits and dots, an optional leading `v`, an optional `-build` tail.
    /// The `v` form is why "contains a letter" isn't enough on its own to call something a name.
    static func isVersion(_ component: String) -> Bool {
        var s = Substring(component)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        guard let first = s.first, first.isNumber, s.contains(".") else { return false }
        return s.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }

    static func displayName(path: String) -> String {
        displayName(fromPathComponents: path.split(separator: "/").map(String.init))
    }
}
