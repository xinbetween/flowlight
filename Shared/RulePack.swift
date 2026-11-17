import CryptoKit
import Foundation

/// A managed, versioned destination list. Pack entries never become ordinary `Rule` rows: their provenance,
/// activation, matching cost, exceptions, and event volume all have different lifecycles.
struct RulePackManifest: Codable, Equatable, Sendable, Identifiable {
    static let formatVersion: UInt16 = 1

    var id: String
    var version: String
    var generatedAt: Date
    var entryCount: Int
    var contentSHA256: String
    var minimumAppVersion: String = "0.15.0"
    var minimumExtensionProtocol: UInt16 = RulePackSnapshot.protocolVersion
    var titleKey: String
    var summaryKey: String
    var caveatKey: String
    var source: String
    var license: String
    var format: UInt16 = formatVersion
}

struct RulePackEntry: Codable, Equatable, Sendable, Identifiable {
    enum Match: String, Codable, Sendable { case exact, suffix }
    enum Category: String, Codable, Sendable { case advertising, tracking, telemetry }

    var id: UInt32
    var host: String
    var match: Match = .suffix
    var category: Category
}

struct RulePackDefinition: Codable, Equatable, Sendable, Identifiable {
    var id: String { manifest.id }
    var manifest: RulePackManifest
    var entries: [RulePackEntry]
}

struct RulePackConfiguration: Codable, Equatable, Sendable, Identifiable {
    enum Scope: String, Codable, Sendable { case allApps, selectedApps }

    var id: String { packID }
    var packID: String
    var enabled = false
    var scope: Scope = .allApps
    /// Bundle identifiers or process identities. Display names are never persisted as matching identity.
    var apps: [String] = []
    /// The exact built-in content the user reviewed. An app update cannot silently broaden an enabled pack.
    var consentedVersion: String?
    var consentedContentSHA256: String?

    func applies(to bundleID: String) -> Bool {
        enabled && (scope == .allApps || apps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
    }

    func isConsented(to definition: RulePackDefinition) -> Bool {
        consentedVersion == definition.manifest.version
            && consentedContentSHA256 == definition.manifest.contentSHA256
    }

    /// Older or interrupted writes may leave only one consent field, an empty value, or a non-SHA-256 digest. None
    /// proves that this tier was previously reviewed, so the first real switch must still inherit the active peer's
    /// exceptions. A complete pair for an older definition does prove prior review and deliberately remains established.
    var hasEstablishedConsent: Bool {
        guard let consentedVersion,
              !consentedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let consentedContentSHA256,
              consentedContentSHA256.utf8.count == 64 else { return false }
        return consentedContentSHA256.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Advertising packs are separate reviewed products, but only one may enforce at a time. Keep this relationship in
/// Shared so the app, persistence, simulation, and extension-facing matcher cannot drift or infer it from pack names.
enum AdvertisingPackTierPolicy {
    enum Risk: Equatable, Sendable { case balanced, aggressive }

    static let balancedID = "official.advertising"
    static let aggressiveID = "official.advertising-aggressive"
    static let displayOrder = [balancedID, aggressiveID]

    static func contains(_ packID: String) -> Bool { displayOrder.contains(packID) }

    static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        let leftRank = displayOrder.firstIndex(of: lhs) ?? Int.max
        let rightRank = displayOrder.firstIndex(of: rhs) ?? Int.max
        return leftRank == rightRank ? lhs < rhs : leftRank < rightRank
    }

    static func risk(for packID: String) -> Risk? {
        switch packID {
        case balancedID: .balanced
        case aggressiveID: .aggressive
        default: nil
        }
    }

    static func exclusivePeer(of packID: String) -> String? {
        switch packID {
        case balancedID: aggressiveID
        case aggressiveID: balancedID
        default: nil
        }
    }

    static func hasDualEnabled(_ configurations: [RulePackConfiguration]) -> Bool {
        let enabled = Set(configurations.lazy.filter(\.enabled).map(\.packID))
        return enabled.contains(balancedID) && enabled.contains(aggressiveID)
    }
}

struct RulePackOverride: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var packID: String
    var app: String
    var host: String
    var match: RulePackEntry.Match = .suffix
    var created = Date()

    func matches(packID candidatePack: String, bundleID: String, host candidateHost: String) -> Bool {
        guard packID == candidatePack,
              app.isEmpty || app.caseInsensitiveCompare(bundleID) == .orderedSame,
              let canonical = HostCanonicalizer.host(candidateHost) else { return false }
        return match == .exact ? canonical == host : canonical == host || canonical.hasSuffix("." + host)
    }
}

struct RulePackSnapshot: Codable, Equatable, Sendable {
    static let protocolVersion: UInt16 = 1

    var protocolVersion = Self.protocolVersion
    var generation = UUID()
    var digest: String
    var definitions: [RulePackDefinition]
    var configurations: [RulePackConfiguration]
    var overrides: [RulePackOverride]

    static func make(definitions: [RulePackDefinition], configurations: [RulePackConfiguration],
                     overrides: [RulePackOverride], generation: UUID = UUID()) -> RulePackSnapshot {
        let sortedDefinitions = definitions.sorted { $0.id < $1.id }
        let sortedConfigurations = configurations.sorted { $0.packID < $1.packID }
        let sortedOverrides = overrides.sorted { $0.id.uuidString < $1.id.uuidString }
        let digest = contentDigest(definitions: sortedDefinitions, configurations: sortedConfigurations,
                                   overrides: sortedOverrides)
        return RulePackSnapshot(generation: generation, digest: digest, definitions: sortedDefinitions,
                                configurations: sortedConfigurations, overrides: sortedOverrides)
    }

    var hasValidDigest: Bool {
        digest == Self.contentDigest(definitions: definitions.sorted { $0.id < $1.id },
                                     configurations: configurations.sorted { $0.packID < $1.packID },
                                     overrides: overrides.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private static func contentDigest(definitions: [RulePackDefinition], configurations: [RulePackConfiguration],
                                      overrides: [RulePackOverride]) -> String {
        // Each validated manifest binds its complete entry array through contentSHA256. Hashing the manifests here
        // keeps an enable or exception save proportional to the number of packs instead of serializing tens of
        // thousands of entries again; the receiving matcher still recomputes every manifest content digest.
        let envelope = DigestEnvelope(manifests: definitions.map(\.manifest),
                                      configurations: configurations, overrides: overrides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(envelope)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct DigestEnvelope: Encodable {
        var manifests: [RulePackManifest]
        var configurations: [RulePackConfiguration]
        var overrides: [RulePackOverride]
    }
}

struct RulePackMatch: Equatable, Sendable {
    var packID: String
    var packVersion: String
    var entry: RulePackEntry
    var matchedHost: String
}

/// One bounded, already-aggregated report from the extension. `bucket` is the minute it represents; count and
/// first/last preserve volume and timing without one IPC/database row per ad request.
struct RulePackHandshake: Codable, Equatable, Sendable {
    var protocolVersion: UInt16
    var activeGeneration: UUID?
    var activeDigest: String
}

struct RulePackApplyResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case accepted, committed, cleared, incompatible, invalid, stale }
    var status: Status
    var protocolVersion: UInt16 = RulePackSnapshot.protocolVersion
    var generation: UUID?
    var activeDigest: String = ""
    var activePacks = 0
    var detail = ""
}

struct RulePackTransferHeader: Codable, Equatable, Sendable {
    var protocolVersion: UInt16
    var generation: UUID
    var digest: String
    var totalBytes: Int
    var chunks: Int
    /// Compare-and-swap base. A transfer that started from an older active generation must not replace a newer one.
    var expectedActiveGeneration: UUID?
}

struct RulePackClearRequest: Codable, Equatable, Sendable {
    var expectedActiveGeneration: UUID?
}

struct RulePackEvent: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case allow, block }
    var bucket: Int64
    var packID: String
    var packVersion: String
    var entryID: UInt32
    var category: RulePackEntry.Category
    var match: RulePackEntry.Match = .suffix
    var action: Action
    var count: Int
    var firstAt: Int64
    var lastAt: Int64
    var bundleID: String
    var appName: String
    var agentKey: String
    var agentName: String
    var host: String
    var matchedHost: String
    var port: UInt16
}

/// One immutable delivery. Its ID makes an uncertain acknowledgement safe to retry without double-counting.
struct RulePackEventBatch: Codable, Equatable, Sendable {
    var id: UUID
    /// Stable for one extension process. Sequence is strictly increasing because only one batch is ever in flight.
    var deliverySession: UUID
    var sequence: Int64
    /// Extension deliveries survive uncertain cross-process acknowledgements. App-local proxy deliveries do not need
    /// a permanent watermark: their database callback and authorization state live in the same process.
    var requiresDurableWatermark: Bool
    var events: [RulePackEvent]
    var droppedHits: Int64
    var droppedKeys: Int64

    init(id: UUID = UUID(), deliverySession: UUID = UUID(), sequence: Int64 = 1,
         requiresDurableWatermark: Bool = true, events: [RulePackEvent],
         droppedHits: Int64 = 0, droppedKeys: Int64 = 0) {
        self.id = id
        self.deliverySession = deliverySession
        self.sequence = sequence
        self.requiresDurableWatermark = requiresDurableWatermark
        self.events = events
        self.droppedHits = droppedHits
        self.droppedKeys = droppedKeys
    }

    private enum CodingKeys: String, CodingKey {
        case id, deliverySession, sequence, requiresDurableWatermark, events, droppedHits, droppedKeys
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        deliverySession = try values.decode(UUID.self, forKey: .deliverySession)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        // The app can upgrade while the prior extension is still running. Its batches predate this field and need
        // the original extension behavior: durable cross-process deduplication.
        requiresDurableWatermark = try values.decodeIfPresent(Bool.self, forKey: .requiresDurableWatermark) ?? true
        events = try values.decode([RulePackEvent].self, forKey: .events)
        droppedHits = try values.decode(Int64.self, forKey: .droppedHits)
        droppedKeys = try values.decode(Int64.self, forKey: .droppedKeys)
    }
}

enum RulePackValidationError: Error, Equatable {
    case unsupportedFormat(String)
    case incompatibleProtocol(String)
    case invalidPackID(String)
    case duplicatePack(String)
    case invalidEntry(String, UInt32)
    case duplicateEntry(String, UInt32)
    case duplicateHost(String, String)
    case nonCanonicalHost(String, String)
    case unsortedEntries(String)
    case countMismatch(String)
    case digestMismatch(String)
    case exclusivePackConflict(String, String)
}

enum RulePackValidator {
    /// App-owned callers pass the running app version. The extension omits it because snapshots have already crossed
    /// that trust boundary; its compatibility contract is the independently versioned extension protocol.
    static func validate(_ definitions: [RulePackDefinition], extensionProtocol: UInt16 = RulePackSnapshot.protocolVersion,
                         currentAppVersion: String? = nil) throws {
        var packIDs = Set<String>()
        for definition in definitions {
            let manifest = definition.manifest
            guard manifest.format == RulePackManifest.formatVersion else {
                throw RulePackValidationError.unsupportedFormat(manifest.id)
            }
            guard manifest.minimumExtensionProtocol <= extensionProtocol else {
                throw RulePackValidationError.incompatibleProtocol(manifest.id)
            }
            if let currentAppVersion,
               compareVersions(manifest.minimumAppVersion, currentAppVersion) == .orderedDescending {
                throw RulePackValidationError.incompatibleProtocol(manifest.id)
            }
            guard !manifest.id.isEmpty,
                  manifest.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
                throw RulePackValidationError.invalidPackID(manifest.id)
            }
            guard packIDs.insert(manifest.id).inserted else { throw RulePackValidationError.duplicatePack(manifest.id) }
            guard manifest.entryCount == definition.entries.count else {
                throw RulePackValidationError.countMismatch(manifest.id)
            }

            var entryIDs = Set<UInt32>(), hosts = Set<String>(), previous = ""
            for entry in definition.entries {
                guard entry.id > 0 else { throw RulePackValidationError.invalidEntry(manifest.id, entry.id) }
                guard entryIDs.insert(entry.id).inserted else {
                    throw RulePackValidationError.duplicateEntry(manifest.id, entry.id)
                }
                guard let canonical = HostCanonicalizer.canonicalHost(entry.host), canonical.value == entry.host else {
                    throw RulePackValidationError.nonCanonicalHost(manifest.id, entry.host)
                }
                if entry.match == .suffix, !PublicSuffixRules.allowsSuffixEntry(canonicalHost: canonical) {
                    throw RulePackValidationError.invalidEntry(manifest.id, entry.id)
                }
                let hostKey = "\(entry.host)|\(entry.match.rawValue)"
                guard hosts.insert(hostKey).inserted else {
                    throw RulePackValidationError.duplicateHost(manifest.id, entry.host)
                }
                guard previous.isEmpty || previous < hostKey else {
                    throw RulePackValidationError.unsortedEntries(manifest.id)
                }
                previous = hostKey
            }
            guard digest(definition.entries) == manifest.contentSHA256 else {
                throw RulePackValidationError.digestMismatch(manifest.id)
            }
        }
    }

    static func digest(_ entries: [RulePackEntry]) -> String {
        let canonical = entries.map { "\($0.id)\t\($0.host)\t\($0.match.rawValue)\t\($0.category.rawValue)\n" }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Immutable after construction. Matching walks reversed labels (`com → example → ads`) and therefore depends on
/// hostname depth, not on the number of entries in the installed packs.
final class RulePackMatcher: @unchecked Sendable {
    private struct Decision {
        var packID: String
        var packVersion: String
        var entry: RulePackEntry
    }

    private struct Node {
        var children: [Substring: Int] = [:]
        var exact: [Decision] = []
        var suffix: [Decision] = []
    }

    private var nodes = [Node()]
    private let configurations: [String: RulePackConfiguration]
    private let overrides: [RulePackOverride]

    init(snapshot: RulePackSnapshot) throws {
        guard snapshot.protocolVersion == RulePackSnapshot.protocolVersion else {
            throw RulePackValidationError.incompatibleProtocol("snapshot")
        }
        guard snapshot.hasValidDigest else { throw RulePackValidationError.digestMismatch("snapshot") }
        try RulePackValidator.validate(snapshot.definitions)
        guard !AdvertisingPackTierPolicy.hasDualEnabled(snapshot.configurations) else {
            throw RulePackValidationError.exclusivePackConflict(
                AdvertisingPackTierPolicy.balancedID,
                AdvertisingPackTierPolicy.aggressiveID
            )
        }
        configurations = Dictionary(snapshot.configurations.map { ($0.packID, $0) }, uniquingKeysWith: { _, latest in latest })
        overrides = snapshot.overrides
        for definition in snapshot.definitions where configurations[definition.id]?.enabled == true {
            for entry in definition.entries { insert(entry, pack: definition) }
        }
    }

    func matches(host: String, bundleID: String) -> [RulePackMatch] {
        guard let canonical = HostCanonicalizer.host(host) else { return [] }
        let labels = canonical.split(separator: ".").reversed()
        var nodeIndex = 0
        var decisions: [Decision] = []
        for label in labels {
            guard let next = nodes[nodeIndex].children[label] else { break }
            nodeIndex = next
            decisions.append(contentsOf: nodes[nodeIndex].suffix)
        }
        decisions.append(contentsOf: nodes[nodeIndex].exact.filter { $0.entry.host == canonical })
        decisions.sort { lhs, rhs in
            let leftDepth = lhs.entry.host.split(separator: ".").count
            let rightDepth = rhs.entry.host.split(separator: ".").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            if lhs.entry.match != rhs.entry.match { return lhs.entry.match == .exact }
            if lhs.packID != rhs.packID { return lhs.packID < rhs.packID }
            return lhs.entry.id < rhs.entry.id
        }
        return decisions.compactMap { decision in
            guard configurations[decision.packID]?.applies(to: bundleID) == true else { return nil }
            if overrides.contains(where: {
                $0.matches(packID: decision.packID, bundleID: bundleID, host: canonical)
            }) { return nil }
            return RulePackMatch(packID: decision.packID, packVersion: decision.packVersion,
                                 entry: decision.entry, matchedHost: canonical)
        }
    }

    private func insert(_ entry: RulePackEntry, pack: RulePackDefinition) {
        var nodeIndex = 0
        for label in entry.host.split(separator: ".").reversed() {
            if let existing = nodes[nodeIndex].children[label] {
                nodeIndex = existing
            } else {
                let next = nodes.count
                nodes.append(Node())
                nodes[nodeIndex].children[label] = next
                nodeIndex = next
            }
        }
        let decision = Decision(packID: pack.id, packVersion: pack.manifest.version, entry: entry)
        if entry.match == .exact { nodes[nodeIndex].exact.append(decision) }
        else { nodes[nodeIndex].suffix.append(decision) }
    }
}
