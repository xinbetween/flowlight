import Foundation

/// One reason an app's destinations stand out, with the numbers that produced it. Every signal carries its own
/// evidence: a ranked list with no arithmetic behind it is a horoscope, not a report.
struct BehaviourSignal: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case manyDestinations, hostless, generatedNames, mostlyUploading, sensitiveProtocol
    }
    var kind: Kind
    /// One line, in the numbers the user can go and check.
    var detail: String
    /// Contribution to the app's score. Relative weights only; the absolute value means nothing on its own.
    var weight: Int
    var id: String { kind.rawValue }
}

/// An app worth looking at, and why.
struct AppBehaviour: Equatable, Identifiable, Sendable {
    var bundleID: String
    var appName: String
    var appPath: String
    var signals: [BehaviourSignal]
    var destinations: Int
    var bytesIn: Int64
    var bytesOut: Int64
    var score: Int { signals.reduce(0) { $0 + $1.weight } }
    var id: String { bundleID }
}

/// Reads a report's breakdown rows and points at the apps whose destinations don't look like the rest.
///
/// Deliberately *not* called suspicious. Everything here is "unusual compared with the other apps in this
/// report", which is a claim the data supports; "malicious" is a claim it doesn't, and calling a legitimate app
/// that in a tool people trust costs more than the feature is worth.
enum DestinationProfile {
    /// Below this an app isn't worth a line of the user's attention.
    static let scoreFloor = 3

    static func analyse(_ rows: [BreakdownRow], limit: Int = 8) -> [AppBehaviour] {
        var byApp: [String: [BreakdownRow]] = [:]
        for row in rows where !row.bundleID.isEmpty { byApp[row.bundleID, default: []].append(row) }
        guard !byApp.isEmpty else { return [] }

        // "Many" only means anything next to what the other apps in this report do.
        let counts = byApp.values.map { distinctDomains($0).count }.sorted()
        let typical = counts[counts.count / 2]

        return byApp.compactMap { bundleID, appRows -> AppBehaviour? in
            let signals = signals(for: appRows, typicalDestinations: typical)
            guard !signals.isEmpty else { return nil }
            let behaviour = AppBehaviour(bundleID: bundleID,
                                         appName: appRows.first?.appName ?? bundleID,
                                         appPath: appRows.first?.appPath ?? "",
                                         signals: signals.sorted { $0.weight > $1.weight },
                                         destinations: distinctDomains(appRows).count,
                                         bytesIn: appRows.reduce(0) { $0 + $1.counters.bytesIn },
                                         bytesOut: appRows.reduce(0) { $0 + $1.counters.bytesOut })
            return behaviour.score >= scoreFloor ? behaviour : nil
        }
        .sorted { ($0.score, $0.bytesOut) > ($1.score, $1.bytesOut) }
        .prefix(limit)
        .map { $0 }
    }

    static func distinctDomains(_ rows: [BreakdownRow]) -> Set<String> {
        Set(rows.filter { !$0.domain.isEmpty }.map { AnomalyEngine.registrableDomain($0.domain.lowercased()) })
    }

    private static func signals(for rows: [BreakdownRow], typicalDestinations: Int) -> [BehaviourSignal] {
        var found: [BehaviourSignal] = []
        let domains = distinctDomains(rows)

        // Spread. Three times the typical app in this report, and more than a handful, is worth a mention.
        if domains.count >= max(8, typicalDestinations * 3) {
            found.append(BehaviourSignal(kind: .manyDestinations,
                                         detail: "\(domains.count) destinations, against \(typicalDestinations) for a typical app here",
                                         weight: 3))
        }

        // Destinations that never resolved to a name. Local chatter isn't interesting.
        let hostless = Set(rows.filter { $0.domain.isEmpty && !AnomalyEngine.isLocal($0.remoteIP) }.map(\.remoteIP))
        if hostless.count >= 3 {
            let owners = Set(rows.filter { $0.domain.isEmpty && !$0.owner.isEmpty }.map(\.owner))
            let where_ = owners.isEmpty ? "" : " (\(owners.sorted().prefix(2).joined(separator: ", ")))"
            found.append(BehaviourSignal(kind: .hostless,
                                         detail: "\(hostless.count) addresses with no hostname\(where_)",
                                         weight: hostless.count >= 10 ? 3 : 2))
        }

        // Names that look machine-made. A weak signal on its own, which is why it scores low.
        let generated = domains.filter { looksGenerated($0) }
        if generated.count >= 2 {
            found.append(BehaviourSignal(kind: .generatedNames,
                                         detail: "\(generated.count) look machine-generated, such as \(generated.sorted().first ?? "")",
                                         weight: 2))
        }

        // Sending far more than it receives, in quantities that matter.
        let out = rows.reduce(Int64(0)) { $0 + $1.counters.bytesOut }
        let into = rows.reduce(Int64(0)) { $0 + $1.counters.bytesIn }
        if out > 10_000_000, out > into * 3 {
            found.append(BehaviourSignal(kind: .mostlyUploading,
                                         detail: "sent \(ByteFormat.string(out)) and received \(ByteFormat.string(into))",
                                         weight: 3))
        }

        // Protocols an app has no business using — unless they are its business. A mail client sending mail is
        // not a finding, and flagging it is how a list like this loses the reader. So a sensitive protocol only
        // counts when it is a sideline: most of the app's bytes went somewhere else.
        // By category, not by protocol name: a mail client splits its work across imaps and smtp-submission, and
        // neither alone dominates, but mail plainly is what it does.
        let total = max(1, rows.reduce(Int64(0)) { $0 + $1.counters.total })
        var bytesByCategory: [ProtocolCategory: Double] = [:]
        var namesByCategory: [ProtocolCategory: Set<String>] = [:]
        for row in rows {
            let names = row.protocols.split(separator: " ").map(String.init)
            guard !names.isEmpty else { continue }
            // A row can list several protocols, and its byte count is the total for all of them. Charging that
            // total to each one makes the shares add up to more than the app's traffic, which pushes a category
            // over the "this is what the app does" line it hasn't earned. Split it instead.
            let perName = Double(row.counters.total) / Double(names.count)
            for name in names {
                let category = ProtocolCatalog.category(of: name)
                bytesByCategory[category, default: 0] += perName
                namesByCategory[category, default: []].insert(name)
            }
        }
        let sensitive = Set(bytesByCategory
            .filter { $0.key.isSensitiveEgress && $0.value / Double(total) < 0.5 }
            .flatMap { namesByCategory[$0.key] ?? [] })
        if !sensitive.isEmpty {
            found.append(BehaviourSignal(kind: .sensitiveProtocol,
                                         detail: "used \(sensitive.sorted().joined(separator: ", "))",
                                         weight: 3))
        }
        return found
    }

    /// A rough test for hostnames that were generated rather than chosen: long, and either full of digits or
    /// carrying more information per character than a word does. It catches DGA-style names and plenty of
    /// innocent CDN shards too, which is why on its own it barely moves the score.
    static func looksGenerated(_ domain: String) -> Bool {
        guard let label = domain.split(separator: ".").first.map(String.init), label.count >= 10 else { return false }
        let digits = label.filter(\.isNumber).count
        if digits >= 4 && Double(digits) / Double(label.count) >= 0.3 { return true }
        let vowels = Set("aeiou")
        if !label.contains(where: { vowels.contains($0) }) { return true }
        return entropy(of: label) >= 3.6
    }

    /// Shannon entropy per character. "cloudfront" sits near 2.9; a random string of the same length is over 3.6.
    static func entropy(of text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        return counts.values.reduce(0.0) { total, count in
            let p = Double(count) / length
            return total - p * log2(p)
        }
    }
}
