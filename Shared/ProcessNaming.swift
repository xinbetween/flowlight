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

    /// Names learned for executables whose filename is a version.
    ///
    /// `proc_pidpath` fails whenever the path cannot be read — the commonest case being a process that has since
    /// exited, which for a short-lived agent invocation is most of them. The caller then falls back to
    /// `proc_name`, which returns the filename, and for an installer that keeps one file per release the
    /// filename *is* the version. So the whole point of this file was defeated by a failure mode it never saw:
    /// the path-based rule was correct and simply never ran, and `2.1.283` went into the database as an identity
    /// of its own.
    ///
    /// Remembering the answer from the times the path *was* readable fixes that, because the same executable is
    /// resolved successfully many times before it is resolved badly once.
    private static let memo = NSLock()
    nonisolated(unsafe) private static var namesByVersion: [String: String] = [:]

    /// Records that this version-shaped filename belongs to a tool of this name.
    static func remember(version: String, as name: String) {
        guard isVersion(version), !name.isEmpty, !isVersion(name) else { return }
        memo.lock(); defer { memo.unlock() }
        namesByVersion[version] = name
    }

    /// The tool a version-shaped filename belongs to, if it has ever been seen with a readable path.
    static func rememberedName(forVersion version: String) -> String? {
        memo.lock(); defer { memo.unlock() }
        return namesByVersion[version]
    }

    /// What to record when all that is known about a process is its filename.
    ///
    /// A version is never an identity: taking one would give the agent a new name, a new allowlist and a new
    /// history on every update, which is the failure this whole file exists to prevent. Better a remembered
    /// name, and failing that an honest `pid N` — a row labelled by pid is obviously incomplete, where a row
    /// labelled `2.1.283` looks like an answer.
    static func identity(fromFilename filename: String, pid: Int32) -> String {
        guard isVersion(filename) else { return filename }
        return rememberedName(forVersion: filename) ?? "pid \(pid)"
    }

    static func displayName(path: String) -> String {
        displayName(fromPathComponents: path.split(separator: "/").map(String.init))
    }

    /// What to show a person. `claude` is the identity — it keys the allowlist, the guardrails and the history —
    /// but "Claude Code" is its name, and a table that says `claude` next to `Google Chrome` is telling the
    /// reader to know which command-line tool is which. Only the label changes; the identifier does not.
    static func friendlyName(executable name: String) -> String {
        guard !name.isEmpty else { return name }
        return AgentCatalog.knownAgent(bundleID: name, appName: name)?.name ?? name
    }
}
