import Foundation

/// Decides what to do about a connection to the system extension that keeps failing.
///
/// A lost XPC connection used to mean one thing: wait five seconds and dial again, for as long as the app was
/// left running. That is the right answer for a blip — the extension restarting, the Mac waking up — and the
/// wrong one for everything else. When macOS is running a different build of the extension from the app, it
/// refuses the connection outright, and refusing it again in five seconds' time refuses it in exactly the same
/// way forever: System Settings says the filter is enabled, the app says the connection was invalidated, and
/// neither of them ever changes its mind. This is the ladder out of that. Redial a couple of times, because most
/// drops really are blips; then ask whether the two builds match, which is the one fault the app can repair by
/// itself; and if none of it helps, stop and let the sampler capture, so there is still data to look at.
struct ExtensionRecovery {
    enum Step: Equatable {
        /// Dial again after this long. Nothing is known to be wrong beyond the connection having dropped.
        case redial(after: TimeInterval)
        /// Ask macOS which build of the extension it has before dialling again. A mismatch is repaired by
        /// re-activating, which is the only thing that replaces a stale extension after the app has updated.
        case repairVersion(after: TimeInterval)
        /// Stop. The extension isn't going to answer, so capture with the nettop sampler instead.
        case fallBack
    }

    /// Redials before the version check is worth doing. Two rides out a restart without reaching for a repair
    /// that can put a System Settings prompt on screen.
    static let attemptsBeforeVersionCheck = 2
    /// Consecutive failures before the sampler takes over. Six, at the delays below, is a little over a minute
    /// of trying: long enough for anything transient, short enough that nobody sits watching an orange dot.
    static let maxAttempts = 6
    /// Failures across the whole session, including the ones a brief success wiped out. A connection that
    /// registers and drops again on a loop would otherwise clear the ladder every time and never reach its end.
    static let maxTotalAttempts = 12

    /// Failures since the last time the extension registered.
    private(set) var attempts = 0
    /// Failures since the source started, which no success resets.
    private(set) var totalAttempts = 0
    /// Whether the version check has been asked for. Once only: it can end in an activation request, and an
    /// activation request can put a prompt in front of the user. Once is a repair; on a timer it is nagging.
    private(set) var versionChecked = false
    /// Set when the ladder has run out. Sticky — having given up once, every later failure says the same thing.
    private(set) var gaveUp = false

    /// Five seconds, then a little longer each time, capped. Backing off matters because the failure that most
    /// often gets this far is a permanent one, and there is nothing to be had from asking about it twelve times
    /// a minute while the Mac has better things to do.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        min(30, TimeInterval(5 * max(1, attempt)))
    }

    /// Records a failure and says what to do about it.
    mutating func next() -> Step {
        guard !gaveUp else { return .fallBack }
        attempts += 1
        totalAttempts += 1
        guard attempts < Self.maxAttempts, totalAttempts < Self.maxTotalAttempts else {
            gaveUp = true
            return .fallBack
        }
        let after = Self.delay(forAttempt: attempts)
        if attempts > Self.attemptsBeforeVersionCheck, !versionChecked {
            versionChecked = true
            return .repairVersion(after: after)
        }
        return .redial(after: after)
    }

    /// The connection came up and the extension registered. The ladder starts again from the bottom, but what
    /// has already been tried is remembered: the version check isn't repeated, and the session's running total
    /// still counts towards giving up, so a connection that flaps can't keep itself alive forever.
    mutating func succeeded() {
        attempts = 0
    }

    /// A stale extension is being replaced. That is a real fix in flight rather than another blind redial, so
    /// everything the failed attempts cost is given back — including having given up.
    ///
    /// Giving up is there to stop a flapping connection retrying forever, and a version repair can't flap: it
    /// happens at most once per session. Refusing to reconsider after one left an upgraded app stuck on the
    /// sampler saying the extension didn't answer, while macOS was in the middle of replacing the extension it
    /// was asking for.
    mutating func repairStarted() {
        attempts = 0
        totalAttempts = 0
        gaveUp = false
    }

    /// What the status line says while a step is pending. It names the delay and how far along the ladder this
    /// is, because a dot that goes orange and then explains nothing is the whole of the problem being fixed here.
    static func statusLine(_ message: String, step: Step, attempt: Int) -> String {
        switch step {
        case .redial(let after):
            return "\(message) — reconnecting in \(Int(after))s (try \(attempt) of \(maxAttempts))"
        case .repairVersion(let after):
            return "\(message) — checking whether the installed extension matches this app, "
                 + "then reconnecting in \(Int(after))s"
        case .fallBack:
            return "\(message) — switching to the nettop sampler"
        }
    }
}

/// Comparing the build of the extension macOS has installed with the one this app ships.
///
/// macOS keeps running whichever build was activated last. After the app updates, that is the previous one, and
/// the XPC connection between an app and an extension of a different version is refused — which on screen looks
/// exactly like an extension that is installed, enabled and unreachable for no reason at all.
enum ExtensionVersion {
    /// Whether what's installed is a different build from the app's. An empty list, or an app with no version,
    /// is not stale: knowing nothing isn't the same as knowing something is wrong, and the repair isn't free.
    static func isStale(installed: [String], appVersion: String) -> Bool {
        guard !appVersion.isEmpty, !installed.isEmpty else { return false }
        return !installed.contains { compare($0, appVersion) == .orderedSame }
    }

    /// Dotted numeric comparison, so "0.5" and "0.5.0" are one version and "0.10.0" comes after "0.9.0" — which
    /// plain string comparison gets backwards. A component that isn't a number counts as zero, and anything
    /// trailing it is ignored, which is what makes the "0.5.0/8" form `systemextensionsctl` prints work here too.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs), right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
