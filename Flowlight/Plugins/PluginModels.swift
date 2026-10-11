import Foundation

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
         configuration: [String: String] = [:]) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, kind, enabled, source, publisher, guardrailProvider, description, ruleVersion, privacySummary, capabilities, configuration
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
    }
}

struct PluginPackage: Codable, Equatable, Sendable {
    var manifest: PluginManifest

    init(manifest: PluginManifest) {
        self.manifest = manifest
    }

    init(from decoder: Decoder) throws {
        if let package = try? decoder.container(keyedBy: CodingKeys.self), package.contains(.manifest) {
            manifest = try package.decode(PluginManifest.self, forKey: .manifest)
        } else {
            manifest = try PluginManifest(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case manifest }
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

    func materialize(exchangeID: Int64, createdAt: Date = Date()) -> PluginFinding {
        let stable = [String(exchangeID), pluginID, title].joined(separator: "|")
        return PluginFinding(id: StablePluginID.make(stable), exchangeID: exchangeID, pluginID: pluginID, pluginVersion: pluginVersion,
                             kind: kind, severity: severity, title: title, summary: summary, evidence: evidence,
                             suggestedGuardrail: suggestedGuardrail, createdAt: createdAt)
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
