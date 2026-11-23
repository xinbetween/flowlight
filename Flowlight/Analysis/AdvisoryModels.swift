import Foundation

/// A normalized security advisory. The shape intentionally follows the useful parts of NVD's CVE and CPE
/// configuration records without coupling the app to a feed or its wire format.
struct SecurityAdvisory: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var summary: String?
    var published: Date?
    var lastModified: Date?
    var configurations: [AdvisoryConfiguration]

    init(id: String, summary: String? = nil, published: Date? = nil, lastModified: Date? = nil,
         configurations: [AdvisoryConfiguration] = []) {
        self.id = id
        self.summary = summary
        self.published = published
        self.lastModified = lastModified
        self.configurations = configurations
    }

    /// The CVE name used by NVD. Keeping this separate makes the normalized model readable at call sites.
    var cveID: String { id }
}

/// One NVD configuration expression. Configurations are alternatives; a match in any one is sufficient.
struct AdvisoryConfiguration: Codable, Equatable, Hashable, Sendable {
    var nodes: [AdvisoryNode]

    init(nodes: [AdvisoryNode] = []) {
        self.nodes = nodes
    }
}

/// An NVD configuration node, retaining its AND/OR and negation semantics.
struct AdvisoryNode: Codable, Equatable, Hashable, Sendable {
    enum Operator: String, Codable, Hashable, Sendable {
        case and = "AND"
        case or = "OR"
    }

    var operation: Operator
    var negate: Bool
    var matches: [AdvisoryCPEMatch]

    init(`operator`: Operator = .or, negate: Bool = false, matches: [AdvisoryCPEMatch] = []) {
        self.operation = `operator`
        self.negate = negate
        self.matches = matches
    }

    private enum CodingKeys: String, CodingKey {
        case operation = "operator"
        case negate
        case matches = "cpeMatch"
    }

    /// NVD calls this field `operator`; `operation` avoids colliding with Swift's operator syntax while preserving
    /// the same normalized meaning.
    var `operator`: Operator {
        get { operation }
        set { operation = newValue }
    }
}

/// A normalized CPE match. `bundleIDs` is the explicit local identity bridge: a CPE product name alone cannot
/// truthfully identify an installed macOS application, so matching never guesses a bundle identifier from it.
struct AdvisoryCPEMatch: Codable, Equatable, Hashable, Sendable {
    var criteria: String
    var matchCriteriaID: String?
    var vulnerable: Bool
    var bundleIDs: [String]
    var versionStartIncluding: String?
    var versionStartExcluding: String?
    var versionEndIncluding: String?
    var versionEndExcluding: String?

    init(criteria: String, matchCriteriaID: String? = nil, vulnerable: Bool = true, bundleIDs: [String] = [],
         versionStartIncluding: String? = nil, versionStartExcluding: String? = nil,
         versionEndIncluding: String? = nil, versionEndExcluding: String? = nil) {
        self.criteria = criteria
        self.matchCriteriaID = matchCriteriaID
        self.vulnerable = vulnerable
        self.bundleIDs = bundleIDs
        self.versionStartIncluding = versionStartIncluding
        self.versionStartExcluding = versionStartExcluding
        self.versionEndIncluding = versionEndIncluding
        self.versionEndExcluding = versionEndExcluding
    }

    private enum CodingKeys: String, CodingKey {
        case criteria
        case matchCriteriaID = "matchCriteriaId"
        case vulnerable
        case bundleIDs
        case versionStartIncluding
        case versionStartExcluding
        case versionEndIncluding
        case versionEndExcluding
    }

    /// The CPE URI spelling used by NVD. The normalized model still keeps this as a criteria string.
    var cpeURI: String { criteria }

    /// A match without an explicit local identity is deliberately not applicable to an installed app.
    func targets(bundleID: String) -> Bool {
        bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    var versionRange: AdvisoryVersionRange {
        AdvisoryVersionRange(startIncluding: versionStartIncluding, startExcluding: versionStartExcluding,
                             endIncluding: versionEndIncluding, endExcluding: versionEndExcluding)
    }
}

/// CPE range bounds normalized into the four NVD range fields. A nil bound means unbounded on that side.
struct AdvisoryVersionRange: Codable, Equatable, Hashable, Sendable {
    var startIncluding: String?
    var startExcluding: String?
    var endIncluding: String?
    var endExcluding: String?

    init(startIncluding: String? = nil, startExcluding: String? = nil,
         endIncluding: String? = nil, endExcluding: String? = nil) {
        self.startIncluding = startIncluding
        self.startExcluding = startExcluding
        self.endIncluding = endIncluding
        self.endExcluding = endExcluding
    }

    var isBounded: Bool {
        startIncluding != nil || startExcluding != nil || endIncluding != nil || endExcluding != nil
    }
}

/// The version evidence available for one installed application, kept separate from its bundle-ID identity.
struct AdvisoryAppVersion: Equatable, Hashable, Sendable {
    var bundleID: String
    var marketingVersion: String?
    var buildVersion: String?

    init(bundleID: String, marketingVersion: String? = nil, buildVersion: String? = nil) {
        self.bundleID = bundleID
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
    }
}
