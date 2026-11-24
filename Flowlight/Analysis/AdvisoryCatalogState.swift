import Foundation

struct AdvisoryCatalogTrustedSigner: Equatable, Sendable {
    var keyID: String
    var publisher: String
    var catalogID: String
    var advisoryIDPrefix: String
    var publicKeyPEM: String
    var validFrom: Int64
    var validUntil: Int64
    var minimumSequence: Int64 = 1
    var maximumSequence: Int64 = .max
    var revoked: Bool = false
}

struct AdvisoryCatalogSignature: Codable, Equatable, Sendable {
    var algorithm: String
    var keyID: String
    var value: String
}

struct AdvisoryCatalogWireAdvisory: Codable, Equatable, Sendable {
    var id: String
    var summary: String?
    var published: Int64?
    var lastModified: Int64?
    var configurations: [AdvisoryConfiguration]

    var advisory: SecurityAdvisory {
        SecurityAdvisory(
            id: id,
            summary: summary,
            published: published.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastModified: lastModified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            configurations: configurations
        )
    }

    init(_ advisory: SecurityAdvisory) {
        id = advisory.id
        summary = advisory.summary
        published = advisory.published.map { Int64($0.timeIntervalSince1970) }
        lastModified = advisory.lastModified.map { Int64($0.timeIntervalSince1970) }
        configurations = advisory.configurations
    }

    init(id: String, summary: String? = nil, published: Int64? = nil, lastModified: Int64? = nil,
         configurations: [AdvisoryConfiguration] = []) {
        self.id = id
        self.summary = summary
        self.published = published
        self.lastModified = lastModified
        self.configurations = configurations
    }
}

struct AdvisoryCatalogPayload: Codable, Equatable, Sendable {
    var catalogID: String
    var channel: String
    var sourceURL: String
    var sequence: Int64
    var issuedAt: Int64
    var expiresAt: Int64
    var publisher: String
    var advisories: [AdvisoryCatalogWireAdvisory]
}

struct AdvisoryCatalogEnvelope: Codable, Equatable, Sendable {
    var format: UInt16
    var payload: AdvisoryCatalogPayload
    var signatures: [AdvisoryCatalogSignature]
}

struct VerifiedAdvisoryCatalog: Equatable, Sendable {
    var advisories: [SecurityAdvisory]
    var sequence: Int64
    var digest: String
    var signerKeyID: String
    var stale: Bool
    /// Exact signed bytes. Re-encoding would invalidate signature evidence and recovery.
    var rawEnvelope: Data
}

struct AdvisoryCatalogReceipt: Equatable, Sendable {
    var catalogID: String
    var sequence: Int64
    var digest: String
    var signerKeyID: String
    var acceptedAt: Date
}

struct AdvisoryCatalogCache: Equatable, Sendable {
    var catalogID: String
    var rawEnvelope: Data
    var etag: String?
    var lastModified: String?
    var verifiedAt: Date
}

struct AdvisoryCatalogUpdateState: Equatable, Sendable {
    var catalogID: String
    /// Refreshing the catalog is an explicit network action until the person enables automatic checks.
    var automaticRefresh = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    var nextEligibleAttempt: Date?
    var failureCount = 0
    var lastStatus: String?
    var lastError: String?
}

struct AdvisoryCatalogState: Equatable, Sendable {
    var receipt: AdvisoryCatalogReceipt?
    var cache: AdvisoryCatalogCache?
    var update: AdvisoryCatalogUpdateState
}

struct AdvisoryCatalogAcceptance: Equatable, Sendable {
    var state: AdvisoryCatalogState
    var advisories: [SecurityAdvisory]
}

enum AdvisoryCatalogVerificationError: Error, Equatable {
    case dataTooLarge
    case invalidEnvelope
    case unsupportedFormat
    case wrongCatalogID
    case wrongChannel
    case wrongSourceURL
    case wrongPublisher
    case invalidSequence
    case invalidTimestamp
    case issuedTooFarInFuture
    case invalidExpiry
    case expired
    case invalidAdvisoryCount
    case tooManyAdvisories
    case invalidAdvisoryID
    case duplicateAdvisoryID(String)
    case invalidConfiguration
    case invalidCPEMatch
    case stringTooLarge
    case duplicateTrustedKeyID(String)
    case duplicateSignatureKeyID(String)
    case tooManySignatures
    case unsupportedSignatureAlgorithm
    case malformedSignature
    case unknownSigner
    case revokedSigner
    case signerNotYetValid
    case signerExpired
    case wrongSignerScope
    case invalidPublicKey
    case invalidSignature
    case invalidPriorReceipt
    case rollback
    case equivocation
}

enum AdvisoryCatalogPersistenceError: Error, Equatable {
    case invalidCatalogID
    case invalidReceipt
    case rollback
    case equivocation
}
