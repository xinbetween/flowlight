import Foundation

/// Conservative numeric version-range matching for normalized CPE data.
///
/// This is intentionally not a general-purpose semver parser. Apple bundle versions and NVD CPE bounds are
/// compared only when every component is an unsigned decimal number. Unknown, empty, wildcard, or prerelease
/// syntax is rejected rather than turned into a potentially false vulnerability finding.
enum VersionRangeMatcher {
    static func isUsable(version: String?, scheme: AdvisoryVersionScheme) -> Bool {
        switch scheme {
        case .numeric, .opaque:
            return parse(version) != nil
        case .semver:
            return SemVer.parse(version) != nil
        }
    }

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

    static func matches(_ artifact: AdvisoryArtifact, match: AdvisoryCPEMatch) -> Bool {
        guard match.vulnerable, match.targets(artifact: artifact), artifact.hasVersionEvidence else { return false }
        switch artifact.versionScheme {
        case .semver:
            return matchesSemver(version: artifact.version, range: match.versionRange, criteria: match.criteria)
        case .numeric, .opaque:
            guard let version = parse(artifact.version), matches(version: artifact.version, range: match.versionRange) else {
                return false
            }
            if let criteriaVersion = criteriaVersion(match.criteria) {
                return compare(version, criteriaVersion) == .orderedSame
            }
            return criteriaHasWildcardVersion(match.criteria)
        }
    }

    private struct SemVer: Equatable {
        var major: UInt64
        var minor: UInt64
        var patch: UInt64
        var prerelease: [String]

        static func parse(_ value: String?) -> SemVer? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard numbers.count == 3,
                  numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  numbers.allSatisfy({ $0.count == 1 || $0.first != "0" }),
                  let major = UInt64(numbers[0]), let minor = UInt64(numbers[1]), let patch = UInt64(numbers[2]) else {
                return nil
            }
            let prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
            guard prerelease.allSatisfy({ component in
                guard !component.isEmpty, component.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) else { return false }
                return !component.allSatisfy(\.isNumber) || component.count == 1 || component.first != "0"
            }) else {
                return nil
            }
            return SemVer(major: major, minor: minor, patch: patch, prerelease: prerelease)
        }
    }

    private static func compare(_ lhs: SemVer, _ rhs: SemVer) -> ComparisonResult {
        for (left, right) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] {
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return .orderedSame }
        if lhs.prerelease.isEmpty { return .orderedDescending }
        if rhs.prerelease.isEmpty { return .orderedAscending }
        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index], right = rhs.prerelease[index]
            if left == right { continue }
            if let leftNumber = UInt64(left), let rightNumber = UInt64(right) {
                return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
            }
            if UInt64(left) != nil { return .orderedAscending }
            if UInt64(right) != nil { return .orderedDescending }
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhs.prerelease.count == rhs.prerelease.count { return .orderedSame }
        return lhs.prerelease.count < rhs.prerelease.count ? .orderedAscending : .orderedDescending
    }

    private static func matchesSemver(version: String?, range: AdvisoryVersionRange, criteria: String) -> Bool {
        guard let version = SemVer.parse(version) else { return false }
        func bound(_ value: String?) -> SemVer? { value == nil ? nil : SemVer.parse(value) }
        if let start = bound(range.startIncluding), compare(version, start) == .orderedAscending { return false }
        if range.startIncluding != nil && bound(range.startIncluding) == nil { return false }
        if let start = bound(range.startExcluding), compare(version, start) != .orderedDescending { return false }
        if range.startExcluding != nil && bound(range.startExcluding) == nil { return false }
        if let end = bound(range.endIncluding), compare(version, end) == .orderedDescending { return false }
        if range.endIncluding != nil && bound(range.endIncluding) == nil { return false }
        if let end = bound(range.endExcluding), compare(version, end) != .orderedAscending { return false }
        if range.endExcluding != nil && bound(range.endExcluding) == nil { return false }
        if let criteriaVersion = SemVer.parse(criteriaVersionString(criteria)) {
            return compare(version, criteriaVersion) == .orderedSame
        }
        return criteriaHasWildcardVersion(criteria)
    }

    private static func criteriaVersionString(_ criteria: String) -> String? {
        if criteria.hasPrefix("cpe:2.3:") {
            let components = criteria.split(separator: ":", omittingEmptySubsequences: false)
            return components.count > 5 ? String(components[5]) : nil
        }
        if criteria.hasPrefix("cpe:/") {
            let components = criteria.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false)
            return components.count > 3 ? String(components[3]) : nil
        }
        return nil
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

    func matches(_ artifact: AdvisoryArtifact) -> Bool {
        configurations.contains { configuration in
            configuration.nodes.allSatisfy { node in
                let results = node.matches.map { VersionRangeMatcher.matches(artifact, match: $0) }
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
}
