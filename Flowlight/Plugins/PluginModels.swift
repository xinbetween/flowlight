import Foundation

struct PluginImportResult: Sendable {
    var manifest: PluginManifest
    var installed: Bool
}

struct PluginBackfillResult: Sendable {
    var pluginID: String?
    var findingCount: Int
}

/// Advisory plugin definitions and findings. Plugins do not alter traffic; they add derived context to inspected exchanges.
struct PluginManifest: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var kind: Kind
    var enabled: Bool = true
    var source: Source = .builtIn
    var publisher: Publisher = .official
    var guardrailProvider: GuardrailProvider = .flowlight
    var description: String
    var ruleVersion: Int = 1
    var privacySummary: String
    var capabilities: [Capability] = [.annotate]
    var configuration: [String: String] = [:]
    var script: String = ""
    var schemaVersion: Int = 1
    var permissions: [PluginPermission] = PluginPermission.defaultMetadata
    var privacy: PluginPrivacyDisclosure = PluginPrivacyDisclosure()
    var provenance: PluginProvenance = PluginProvenance()

    enum Kind: String, Codable, Sendable { case traffic, llmMCP }
    enum Source: String, Codable, Sendable { case builtIn, installed }
    enum Publisher: String, Codable, Sendable { case official, thirdParty }
    enum GuardrailProvider: String, Codable, Sendable, CaseIterable {
        case flowlight, presidio, bedrock, lakera, aporia, noma, prismaAIRS, custom

        var title: String {
            switch self {
            case .flowlight: return "Flowlight"
            case .presidio: return "Presidio"
            case .bedrock: return "Bedrock"
            case .lakera: return "Lakera"
            case .aporia: return "Aporia"
            case .noma: return "Noma"
            case .prismaAIRS: return "PANW Prisma AIRS"
            case .custom: return "Custom"
            }
        }
    }
    enum Capability: String, Codable, Sendable { case annotate, suggestGuardrail }

    init(id: String, name: String, version: String, kind: Kind, enabled: Bool = true, source: Source = .builtIn,
         publisher: Publisher = .official, guardrailProvider: GuardrailProvider = .flowlight, description: String,
         ruleVersion: Int = 1, privacySummary: String, capabilities: [Capability] = [.annotate],
         configuration: [String: String] = [:], script: String = "", schemaVersion: Int = 1,
         permissions: [PluginPermission] = PluginPermission.defaultMetadata,
         privacy: PluginPrivacyDisclosure = PluginPrivacyDisclosure(), provenance: PluginProvenance = PluginProvenance()) {
        self.id = id
        self.name = name
        self.version = version
        self.kind = kind
        self.enabled = enabled
        self.source = source
        self.publisher = publisher
        self.guardrailProvider = guardrailProvider
        self.description = description
        self.ruleVersion = ruleVersion
        self.privacySummary = privacySummary
        self.capabilities = capabilities
        self.configuration = configuration
        self.script = script
        self.schemaVersion = schemaVersion
        self.permissions = permissions
        self.privacy = privacy
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, kind, enabled, source, publisher, guardrailProvider, description, ruleVersion, privacySummary, capabilities, configuration, script, schemaVersion, permissions, privacy, provenance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        kind = try values.decode(Kind.self, forKey: .kind)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .builtIn
        publisher = try values.decodeIfPresent(Publisher.self, forKey: .publisher) ?? .official
        guardrailProvider = try values.decodeIfPresent(GuardrailProvider.self, forKey: .guardrailProvider) ?? .flowlight
        description = try values.decode(String.self, forKey: .description)
        ruleVersion = try values.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? 1
        privacySummary = try values.decode(String.self, forKey: .privacySummary)
        capabilities = try values.decodeIfPresent([Capability].self, forKey: .capabilities) ?? [.annotate]
        configuration = try values.decodeIfPresent([String: String].self, forKey: .configuration) ?? [:]
        script = try values.decodeIfPresent(String.self, forKey: .script) ?? ""
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        permissions = try values.decodeIfPresent([PluginPermission].self, forKey: .permissions) ?? PluginPermission.defaultMetadata
        privacy = try values.decodeIfPresent(PluginPrivacyDisclosure.self, forKey: .privacy) ?? PluginPrivacyDisclosure()
        provenance = try values.decodeIfPresent(PluginProvenance.self, forKey: .provenance) ?? PluginProvenance()
    }
}

/// What sanitized metadata a plugin declares it uses. These are not mutation powers.
enum PluginPermission: String, Codable, CaseIterable, Sendable {
    case trafficMetadata
    case headerNames
    case appIdentity
    case llmMetadata
    case mcpMetadata
    case suggestGuardrail

    static let defaultMetadata: [PluginPermission] = [.trafficMetadata, .headerNames, .appIdentity, .llmMetadata, .mcpMetadata]

    var title: String {
        switch self {
        case .trafficMetadata: return L("Traffic metadata")
        case .headerNames: return L("Header names")
        case .appIdentity: return L("App identity")
        case .llmMetadata: return L("LLM metadata")
        case .mcpMetadata: return L("MCP metadata")
        case .suggestGuardrail: return L("Suggest guardrails")
        }
    }
}

struct PluginPrivacyDisclosure: Codable, Equatable, Sendable {
    var categories: [Category]
    var summary: String

    init(categories: [Category] = [.metadataOnly], summary: String = "") {
        self.categories = categories
        self.summary = summary
    }

    enum Category: String, Codable, CaseIterable, Sendable {
        case metadataOnly
        case headerNames
        case appIdentity
        case toolNames
        case mcpMetadata
        case guardrailSuggestions

        var title: String {
            switch self {
            case .metadataOnly: return L("Metadata only")
            case .headerNames: return L("Header names")
            case .appIdentity: return L("App identity")
            case .toolNames: return L("Tool names")
            case .mcpMetadata: return L("MCP metadata")
            case .guardrailSuggestions: return L("Guardrail suggestions")
            }
        }
    }
}

struct PluginProvenance: Codable, Equatable, Sendable {
    var packageDigest: String
    var scriptDigest: String
    var sourceURL: String
    var repositoryURL: String
    var distributionChannel: DistributionChannel
    var publisherName: String
    var signingKeyID: String
    var signedAt: String
    var reviewStatus: ReviewStatus
    var reviewerNote: String
    var approvalFingerprint: String

    init(packageDigest: String = "", scriptDigest: String = "", sourceURL: String = "", repositoryURL: String = "",
         distributionChannel: DistributionChannel = .local, publisherName: String = "", signingKeyID: String = "",
         signedAt: String = "", reviewStatus: ReviewStatus = .unsigned, reviewerNote: String = "", approvalFingerprint: String = "") {
        self.packageDigest = packageDigest
        self.scriptDigest = scriptDigest
        self.sourceURL = sourceURL
        self.repositoryURL = repositoryURL
        self.distributionChannel = distributionChannel
        self.publisherName = publisherName
        self.signingKeyID = signingKeyID
        self.signedAt = signedAt
        self.reviewStatus = reviewStatus
        self.reviewerNote = reviewerNote
        self.approvalFingerprint = approvalFingerprint
    }

    enum DistributionChannel: String, Codable, Sendable {
        case builtIn, local, community, official

        var title: String {
            switch self {
            case .builtIn: return L("Built-in")
            case .local: return L("Local file")
            case .community: return L("Community")
            case .official: return L("Official")
            }
        }
    }

    enum ReviewStatus: String, Codable, Sendable {
        case builtIn, unsigned, verifiedOfficial, verifiedCommunity, rejected

        var title: String {
            switch self {
            case .builtIn: return L("Built-in")
            case .unsigned: return L("Unsigned local")
            case .verifiedOfficial: return L("Verified official")
            case .verifiedCommunity: return L("Verified community")
            case .rejected: return L("Rejected")
            }
        }
    }
}

struct PluginSignature: Codable, Equatable, Sendable {
    var algorithm: String
    var keyID: String
    var signedAt: String
    var value: String

    init(algorithm: String = "p256-sha256", keyID: String, signedAt: String = "", value: String) {
        self.algorithm = algorithm
        self.keyID = keyID
        self.signedAt = signedAt
        self.value = value
    }
}

struct PluginPackage: Codable, Equatable, Sendable {
    var manifest: PluginManifest
    var signature: PluginSignature?
    var packageVersion: Int

    init(manifest: PluginManifest, signature: PluginSignature? = nil, packageVersion: Int = 1) {
        self.manifest = manifest
        self.signature = signature
        self.packageVersion = packageVersion
    }

    init(from decoder: Decoder) throws {
        if let package = try? decoder.container(keyedBy: CodingKeys.self), package.contains(.manifest) {
            manifest = try package.decode(PluginManifest.self, forKey: .manifest)
            signature = try package.decodeIfPresent(PluginSignature.self, forKey: .signature)
            packageVersion = try package.decodeIfPresent(Int.self, forKey: .packageVersion) ?? 1
        } else {
            manifest = try PluginManifest(from: decoder)
            signature = nil
            packageVersion = 1
        }
    }

    private enum CodingKeys: String, CodingKey { case manifest, signature, packageVersion }
}

struct PluginPackageReview: Identifiable, Equatable, Sendable {
    var id: String { approvalFingerprint }
    var manifest: PluginManifest
    var signatureStatus: PluginProvenance.ReviewStatus
    var packageDigest: String
    var scriptDigest: String
    var approvalFingerprint: String
    var warnings: [String]
    var signature: PluginSignature?
}

struct PluginEvidence: Codable, Equatable, Sendable {
    var label: String
    var value: String

    init(_ label: String, _ value: String, limit: Int = 240) {
        self.label = String(label.prefix(80))
        self.value = String(value.prefix(limit))
    }
}

struct PluginFinding: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var exchangeID: Int64
    var pluginID: String
    var pluginVersion: String
    var kind: PluginManifest.Kind
    var severity: Severity
    var title: String
    var summary: String
    var evidence: [PluginEvidence]
    var suggestedGuardrail: Guardrail?
    var suggestedRule: Rule?
    var createdAt: Date

    enum Severity: String, Codable, Sendable, CaseIterable { case info, low, medium, high }
}

struct PluginFindingDraft: Equatable, Sendable {
    var pluginID: String
    var pluginVersion: String
    var kind: PluginManifest.Kind
    var severity: PluginFinding.Severity
    var title: String
    var summary: String
    var evidence: [PluginEvidence]
    var suggestedGuardrail: Guardrail?
    var suggestedRule: Rule?

    func materialize(exchangeID: Int64, createdAt: Date = Date()) -> PluginFinding {
        let stable = [String(exchangeID), pluginID, title].joined(separator: "|")
        return PluginFinding(id: StablePluginID.make(stable), exchangeID: exchangeID, pluginID: pluginID, pluginVersion: pluginVersion,
                             kind: kind, severity: severity, title: title, summary: summary, evidence: evidence,
                             suggestedGuardrail: suggestedGuardrail, suggestedRule: suggestedRule, createdAt: createdAt)
    }
}

extension PluginManifest.Kind {
    var title: String {
        switch self {
        case .traffic: return L("Traffic")
        case .llmMCP: return L("LLM/MCP")
        }
    }
}

private enum StablePluginID {
    /// Deterministic enough for de-duplicating plugin findings without pulling in a hashing dependency.
    static func make(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
