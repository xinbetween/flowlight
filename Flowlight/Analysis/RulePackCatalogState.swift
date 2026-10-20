import Foundation

struct RulePackCatalogReceipt: Equatable, Sendable {
    var catalogID: String
    var sequence: Int64
    var digest: String
    var signerKeyID: String
    var acceptedAt: Date
}

struct RulePackCatalogCache: Equatable, Sendable {
    var catalogID: String
    /// Exact signed bytes. Re-encoding would invalidate both the signature evidence and byte-for-byte recovery.
    var rawEnvelope: Data
    var etag: String?
    var lastModified: String?
    var verifiedAt: Date
}

struct RulePackCatalogUpdateState: Equatable, Sendable {
    var catalogID: String
    var automaticRefresh = true
    var lastAttempt: Date?
    var lastSuccess: Date?
    var nextEligibleAttempt: Date?
    var failureCount = 0
    var lastStatus: String?
    var lastError: String?
}

struct RulePackCatalogState: Equatable, Sendable {
    var receipt: RulePackCatalogReceipt?
    var cache: RulePackCatalogCache?
    var update: RulePackCatalogUpdateState
}

/// The exact content shown by an editor. Publisher authentication and user consent are separate decisions.
struct RulePackReviewReceipt: Equatable, Sendable {
    var packID: String
    var version: String
    var contentSHA256: String
    var catalogSequence: Int64
    var catalogDigest: String

    func matches(_ definition: RulePackDefinition, catalogSequence: Int64, catalogDigest: String) -> Bool {
        packID == definition.id
            && version == definition.manifest.version
            && contentSHA256 == definition.manifest.contentSHA256
            && self.catalogSequence == catalogSequence
            && self.catalogDigest == catalogDigest
    }
}

enum RulePackCatalogPersistenceError: Error, Equatable {
    case invalidCatalogID
    case invalidReceipt
    case rollback
    case equivocation
    case staleReview
}

struct RulePackCatalogAcceptance: Equatable, Sendable {
    var state: RulePackCatalogState
    /// All saved rows, including dormant IDs omitted by the currently active catalog.
    var configurations: [RulePackConfiguration]
}
