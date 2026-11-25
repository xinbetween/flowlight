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

/// A signed, kind-qualified local identity. The catalog must name the artifact kind explicitly; a display name or
/// CPE product alone is never enough to identify local software.
struct AdvisoryTarget: Codable, Equatable, Hashable, Sendable {
    var kind: AdvisoryArtifactKind
    var identifier: String
    /// Required for generic package targets; nil preserves the legacy kind-qualified wire format.
    var packageManager: AdvisoryPackageManager?

    init(kind: AdvisoryArtifactKind, identifier: String, packageManager: AdvisoryPackageManager? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.packageManager = packageManager
    }
}

/// A normalized CPE match. Legacy app entries use `bundleIDs`; new entries use `targets` for non-bundle software.
struct AdvisoryCPEMatch: Codable, Equatable, Hashable, Sendable {
    var criteria: String
    var matchCriteriaID: String?
    var vulnerable: Bool
    var bundleIDs: [String]
    var targets: [AdvisoryTarget]
    var versionStartIncluding: String?
    var versionStartExcluding: String?
    var versionEndIncluding: String?
    var versionEndExcluding: String?

    init(criteria: String, matchCriteriaID: String? = nil, vulnerable: Bool = true, bundleIDs: [String] = [],
         targets: [AdvisoryTarget] = [], versionStartIncluding: String? = nil, versionStartExcluding: String? = nil,
         versionEndIncluding: String? = nil, versionEndExcluding: String? = nil) {
        self.criteria = criteria
        self.matchCriteriaID = matchCriteriaID
        self.vulnerable = vulnerable
        self.bundleIDs = bundleIDs
        self.targets = targets
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
        case targets
        case versionStartIncluding
        case versionStartExcluding
        case versionEndIncluding
        case versionEndExcluding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        criteria = try container.decode(String.self, forKey: .criteria)
        matchCriteriaID = try container.decodeIfPresent(String.self, forKey: .matchCriteriaID)
        vulnerable = try container.decode(Bool.self, forKey: .vulnerable)
        bundleIDs = try container.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        targets = try container.decodeIfPresent([AdvisoryTarget].self, forKey: .targets) ?? []
        versionStartIncluding = try container.decodeIfPresent(String.self, forKey: .versionStartIncluding)
        versionStartExcluding = try container.decodeIfPresent(String.self, forKey: .versionStartExcluding)
        versionEndIncluding = try container.decodeIfPresent(String.self, forKey: .versionEndIncluding)
        versionEndExcluding = try container.decodeIfPresent(String.self, forKey: .versionEndExcluding)
    }

    /// The CPE URI spelling used by NVD. The normalized model still keeps this as a criteria string.
    var cpeURI: String { criteria }

    /// A legacy app match without an explicit local identity is deliberately not applicable.
    func targets(bundleID: String) -> Bool {
        bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func targets(artifact: AdvisoryArtifact) -> Bool {
        if artifact.kind == .application,
           bundleIDs.contains(where: { $0.caseInsensitiveCompare(artifact.identifier) == .orderedSame }) {
            return true
        }
        return targets.contains {
            let targetManager = $0.packageManager ?? Self.legacyPackageManager(for: $0.kind)
            let artifactManager = artifact.packageManager ?? Self.legacyPackageManager(for: artifact.kind)
            let samePackageFamily = $0.kind.isPackage && artifact.kind.isPackage
                && targetManager != nil && artifactManager != nil
            guard ($0.kind == artifact.kind || samePackageFamily),
                  $0.identifier.caseInsensitiveCompare(artifact.identifier) == .orderedSame else { return false }
            if $0.kind.isPackage || artifact.kind.isPackage {
                return targetManager == artifactManager
            }
            return true
        }
    }

    private static func legacyPackageManager(for kind: AdvisoryArtifactKind) -> AdvisoryPackageManager? {
        switch kind {
        case .homebrewFormula: return .homebrewFormula
        case .homebrewCask: return .homebrewCask
        case .nodePackage: return .npm
        case .application, .executable, .package: return nil
        }
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
