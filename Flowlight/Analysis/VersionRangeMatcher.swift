import Foundation

/// Conservative numeric version-range matching for normalized CPE data.
///
/// This is intentionally not a general-purpose semver parser. Apple bundle versions and NVD CPE bounds are
/// compared only when every component is an unsigned decimal number. Unknown, empty, wildcard, or prerelease
/// syntax is rejected rather than turned into a potentially false vulnerability finding.
enum VersionRangeMatcher {
    static func matches(version: String?, range: AdvisoryVersionRange) -> Bool {
        guard let version = parse(version) else { return false }
        guard let startIncluding = bound(range.startIncluding) else { return false }
        if range.startIncluding != nil, compare(version, startIncluding) == .orderedAscending { return false }
        guard let startExcluding = bound(range.startExcluding) else { return false }
        if range.startExcluding != nil, compare(version, startExcluding) != .orderedDescending { return false }
        guard let endIncluding = bound(range.endIncluding) else { return false }
        if range.endIncluding != nil, compare(version, endIncluding) == .orderedDescending { return false }
        guard let endExcluding = bound(range.endExcluding) else { return false }
        if range.endExcluding != nil, compare(version, endExcluding) != .orderedAscending { return false }
        return true
    }

    static func matches(_ app: AdvisoryAppVersion, match: AdvisoryCPEMatch) -> Bool {
        guard match.vulnerable, match.targets(bundleID: app.bundleID) else { return false }
        // Marketing version is the product version represented by CFBundleShortVersionString. Build is useful only
        // when the marketing version is absent; comparing either would let a coincidentally similar build number
        // override a known product version.
        guard let version = parse(app.marketingVersion ?? app.buildVersion),
              matches(version: app.marketingVersion ?? app.buildVersion, range: match.versionRange) else { return false }
        // An exact version in the CPE criteria remains a constraint even when NVD omitted explicit range fields.
        if let criteriaVersion = criteriaVersion(match.criteria) {
            guard compare(version, criteriaVersion) == .orderedSame else { return false }
        } else if !criteriaHasWildcardVersion(match.criteria) {
            // Do not treat an unknown CPE version spelling as an unbounded product match.
            return false
        }
        return true
    }

    private static func criteriaVersion(_ criteria: String) -> [UInt64]? {
        let components: [Substring]
        if criteria.hasPrefix("cpe:2.3:") {
            components = criteria.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count > 5 else { return nil }
            return parse(String(components[5]))
        }
        if criteria.hasPrefix("cpe:/") {
            components = criteria.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false)
            guard components.count > 3 else { return nil }
            return parse(String(components[3]))
        }
        return nil
    }

    private static func criteriaHasWildcardVersion(_ criteria: String) -> Bool {
        let components: [Substring]
        if criteria.hasPrefix("cpe:2.3:") {
            components = criteria.split(separator: ":", omittingEmptySubsequences: false)
            return components.count > 5 && (components[5] == "*" || components[5] == "-")
        }
        if criteria.hasPrefix("cpe:/") {
            components = criteria.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false)
            return components.count > 3 && (components[3] == "*" || components[3] == "-")
        }
        return false
    }

    private static func bound(_ value: String?) -> [UInt64]? {
        guard let value else { return [] }
        return parse(value)
    }

    private static func parse(_ value: String?) -> [UInt64]? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var parsed: [UInt64] = []
        parsed.reserveCapacity(components.count)
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0.isNumber }),
                  let number = UInt64(component) else { return nil }
            parsed.append(number)
        }
        return parsed
    }

    private static func compare(_ lhs: [UInt64], _ rhs: [UInt64]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

}

extension SecurityAdvisory {
    /// Returns true only when a vulnerable CPE match explicitly names this app's bundle ID and has usable version
    /// evidence. Unsupported CPE identity mappings, missing versions, and malformed ranges do not match.
    func matches(_ app: AdvisoryAppVersion) -> Bool {
        configurations.contains { configuration in
            configuration.nodes.allSatisfy { node in
                let results = node.matches.map { VersionRangeMatcher.matches(app, match: $0) }
                guard !results.isEmpty else { return false }
                let result: Bool
                switch node.operation {
                case .and: result = results.allSatisfy { $0 }
                case .or: result = results.contains(true)
                }
                return node.negate ? !result : result
            }
        }
    }

    /// Convenience overload that carries the scan's explicit version evidence into the pure matcher.
    func matches(_ app: InstalledApps.App) -> Bool {
        matches(AdvisoryAppVersion(bundleID: app.bundleID, marketingVersion: app.marketingVersion,
                                   buildVersion: app.buildVersion))
    }
}
