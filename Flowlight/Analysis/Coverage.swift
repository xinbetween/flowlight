import Foundation

/// How much of one app's traffic Flowlight can actually account for, and what is missing.
///
/// The app says it sees every connection, and then the honest paragraphs elsewhere list the exceptions:
/// traffic from before the filter started, system services a content filter never sees, a Mac where another
/// filter owns the only slot, apps that pin their certificates, QUIC the proxy is never offered, an agent's
/// MCP server talking over a pipe. All of that is true and all of it is somewhere else, so reading any screen
/// correctly means having read the documentation first.
///
/// This turns it into a per-app answer. Three separate questions, because they fail independently: is the
/// traffic *seen* at all, is the destination *named*, and is the content *readable*. An app can be fully seen
/// and entirely unnamed, or named and unreadable, and lumping those together is how a coverage number becomes
/// a reassurance rather than a fact.
struct AppCoverage: Identifiable, Equatable, Sendable {
    var bundleID: String
    var appName: String
    var bytes: Int64
    /// How its flows reach Flowlight.
    var capture: Capture
    /// The share of this app's bytes whose destination has a hostname rather than a bare address.
    var named: Double
    /// Whether anything of this app's has been decrypted, and why not when it hasn't.
    var inspection: Inspection
    var id: String { bundleID }

    enum Capture: Equatable, Sendable {
        /// The Network Extension sees flows as they open.
        case filter
        /// The sampler reads counters once a second: a connection that opens and closes between two readings
        /// is never counted, which is a gap no percentage can show.
        case sampler
        /// The filter is the chosen source but isn't delivering — another content filter holds the slot, or it
        /// hasn't been installed — so what is on screen came from the sampler instead.
        case fellBack
        case demo
    }

    enum Inspection: Equatable, Sendable {
        /// Not turned on. Nothing is decrypted for anyone.
        case off
        /// On, and this app's requests are being read.
        case reading
        /// On, but nothing of this app's has arrived: it was started without the proxy, or it ignores proxy
        /// settings, or it pins its certificates and was passed through untouched.
        case notRouted
        /// Deliberately excluded — Apple services, password managers, anything on the never-inspect list.
        case excluded
    }

    /// Whether anything here is worth a user's attention. An app that is seen, named and either read or not
    /// meant to be read is covered; everything else has a gap worth naming.
    var isComplete: Bool {
        capture == .filter && named > 0.99 && (inspection == .reading || inspection == .excluded || inspection == .off)
    }
}

enum CoverageReport {
    /// Builds one row per app from a report's breakdown, the apps whose traffic has been decrypted, and the
    /// state of the two engines.
    ///
    /// `named` is computed over bytes rather than flows on purpose: one unnamed connection carrying a gigabyte
    /// is a bigger hole than a hundred unnamed connections carrying a kilobyte each, and a count would rank
    /// them the other way round.
    static func build(rows: [BreakdownRow], inspected: Set<String>, excluded: Set<String>,
                      mode: CaptureMode, fellBack: Bool, inspectionOn: Bool, isDemo: Bool,
                      limit: Int = 60) -> [AppCoverage] {
        var bytes: [String: Int64] = [:]
        var namedBytes: [String: Int64] = [:]
        var names: [String: String] = [:]
        for row in rows where !row.bundleID.isEmpty {
            bytes[row.bundleID, default: 0] += row.counters.total
            if !row.domain.isEmpty { namedBytes[row.bundleID, default: 0] += row.counters.total }
            if names[row.bundleID] == nil || names[row.bundleID]?.isEmpty == true {
                names[row.bundleID] = row.appName.isEmpty ? row.bundleID : row.appName
            }
        }
        let capture: AppCoverage.Capture = isDemo ? .demo
            : mode == .nettop ? .sampler : (fellBack ? .fellBack : .filter)

        return bytes.map { bundleID, total in
            let inspection: AppCoverage.Inspection
            if isDemo || !inspectionOn { inspection = .off }
            else if inspected.contains(bundleID) { inspection = .reading }
            else if excluded.contains(bundleID) { inspection = .excluded }
            else { inspection = .notRouted }
            return AppCoverage(bundleID: bundleID, appName: names[bundleID] ?? bundleID, bytes: total,
                               capture: capture,
                               named: total > 0 ? Double(namedBytes[bundleID] ?? 0) / Double(total) : 0,
                               inspection: inspection)
        }
        // Biggest first: a gap matters in proportion to what is going through it.
        .sorted { ($0.bytes, $1.appName) > ($1.bytes, $0.appName) }
        .prefix(limit)
        .map { $0 }
    }

    /// The share of all bytes in the report that sit behind a complete row. Deliberately not an average of the
    /// per-app percentages: an app moving a gigabyte and an app moving a kilobyte are not half the picture each.
    static func overall(_ rows: [AppCoverage]) -> Double {
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return 0 }
        let complete = rows.filter(\.isComplete).reduce(Int64(0)) { $0 + $1.bytes }
        return Double(complete) / Double(total)
    }
}
