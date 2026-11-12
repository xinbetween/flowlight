import Foundation

/// Local routing metadata for an inspection provider. A profile may point at a
/// Keychain item, but it never owns or serializes that item's value.
struct ProviderRuntimeProfile: Equatable, Sendable {
    var id: UUID
    var provider: PluginManifest.GuardrailProvider
    var endpoint: String?
    var configuration: [String: String]
    var pluginIDs: [String]

    func applies(to manifest: PluginManifest) -> Bool {
        provider == manifest.guardrailProvider && pluginIDs.contains(manifest.id)
    }
}

struct ProviderProfile: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var id: UUID
    var name: String
    var provider: PluginManifest.GuardrailProvider
    var enabled: Bool
    var endpoint: String?
    var configuration: [String: String]
    var pluginIDs: [String]
    var credentialReference: String?

    init(
        id: UUID = UUID(),
        name: String,
        provider: PluginManifest.GuardrailProvider,
        enabled: Bool = true,
        endpoint: String? = nil,
        configuration: [String: String] = [:],
        pluginIDs: [String] = [],
        credentialReference: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.enabled = enabled
        self.endpoint = endpoint
        self.configuration = configuration
        self.pluginIDs = pluginIDs
        self.credentialReference = credentialReference
    }

    enum Health: Equatable {
        case disabled
        case attention(String)
        case ready(String)

        var title: String {
            switch self {
            case .disabled: return L("Off")
            case .attention: return L("Needs attention")
            case .ready: return L("Ready")
            }
        }

        var reason: String {
            switch self {
            case .disabled:
                return L("This provider profile is disabled.")
            case .attention(let reason), .ready(let reason):
                return reason
            }
        }
    }

    func health(manifests: [PluginManifest]) -> Health {
        guard enabled else { return .disabled }
        guard !pluginIDs.isEmpty else {
            return .attention(L("Assign at least one inspection plugin."))
        }
        let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        if pluginIDs.contains(where: { byID[$0] == nil }) {
            return .attention(L("An assigned plugin is no longer installed."))
        }
        if pluginIDs.contains(where: { byID[$0]?.guardrailProvider != provider }) {
            return .attention(L("An assigned plugin uses a different provider."))
        }
        if pluginIDs.allSatisfy({ byID[$0]?.enabled == false }) {
            return .attention(L("Every assigned plugin is disabled."))
        }
        let count = pluginIDs.count
        return .ready(count == 1 ? L("1 inspection plugin assigned.") : L("%lld inspection plugins assigned.", count))
    }
}

enum ProviderProfileValidationError: LocalizedError, Equatable {
    case name
    case endpoint
    case credentialReference
    case configuration
    case pluginID

    var errorDescription: String? {
        switch self {
        case .name: return L("Enter a provider profile name between 1 and 80 characters.")
        case .endpoint: return L("Use an HTTPS endpoint, or HTTP only for localhost. User information, query parameters, and fragments are not allowed.")
        case .credentialReference: return L("Use a Keychain reference such as keychain:service/account, not a credential value.")
        case .configuration: return L("Provider options must be short, non-secret key/value metadata.")
        case .pluginID: return L("An assigned plugin identifier is invalid.")
        }
    }
}

enum ProviderProfileValidator {
    private static let secretKeyTerms = ["apikey", "authorization", "bearer", "credential", "password", "privatekey", "secret", "token"]
    private static let credentialValuePrefixes = [
        "akia", "asia", "aiza", "bearer ", "basic ", "ghp_", "github_pat_", "keychain:", "pplx-", "sk-", "sk_", "xox",
    ]

    private static func resemblesCredential(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if credentialValuePrefixes.contains(where: lowercased.hasPrefix) { return true }
        if value.contains("-----BEGIN ") && value.contains("PRIVATE KEY-----") { return true }
        if value.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return true
        }
        // Provider options such as regions, model names, and policy labels are human-readable. A long compact token
        // belongs in the Keychain even when its option key has an innocuous name such as `account` or `value`.
        return value.count >= 32
            && value.range(of: #"^[A-Za-z0-9_+/=-]+$"#, options: .regularExpression) != nil
    }

    static func normalized(_ profile: ProviderProfile) throws -> ProviderProfile {
        var result = profile
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(result.name.count), !result.name.contains(where: { $0.isNewline }) else {
            throw ProviderProfileValidationError.name
        }

        result.endpoint = result.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).providerNilIfEmpty
        if let endpoint = result.endpoint {
            guard endpoint.count <= 500,
                  let components = URLComponents(string: endpoint),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(), !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
                throw ProviderProfileValidationError.endpoint
            }
        }

        result.credentialReference = result.credentialReference?.trimmingCharacters(in: .whitespacesAndNewlines).providerNilIfEmpty
        if let reference = result.credentialReference {
            guard reference.count <= 160,
                  reference.range(of: #"^keychain:[A-Za-z0-9._:/-]+$"#, options: .regularExpression) != nil else {
                throw ProviderProfileValidationError.credentialReference
            }
        }

        guard result.configuration.count <= 32 else { throw ProviderProfileValidationError.configuration }
        var normalizedConfiguration: [String: String] = [:]
        for (rawKey, rawValue) in result.configuration {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let comparable = key.lowercased().filter(\.isLetter)
            guard (1...80).contains(key.count), value.count <= 500,
                  !key.contains(where: { $0.isNewline }), !value.contains(where: { $0.isNewline }),
                  !secretKeyTerms.contains(where: comparable.contains), !resemblesCredential(value) else {
                throw ProviderProfileValidationError.configuration
            }
            normalizedConfiguration[key] = value
        }
        result.configuration = normalizedConfiguration

        result.pluginIDs = Array(Set(result.pluginIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard result.pluginIDs.count <= 128,
              result.pluginIDs.allSatisfy({ !$0.isEmpty && $0.count <= 160 && !$0.contains(where: { $0.isWhitespace }) }) else {
            throw ProviderProfileValidationError.pluginID
        }
        return result
    }
}

@MainActor
final class ProviderProfileStore: ObservableObject {
    @Published private(set) var profiles: [ProviderProfile] = []
    @Published private(set) var loadIssue: String?

    private let defaults: UserDefaults
    private let key: String
    private var runtimeSink: (([ProviderRuntimeProfile]) -> Void)?

    init(defaults: UserDefaults = .standard, key: String = "inspectionProviderProfiles") {
        self.defaults = defaults
        self.key = key
        reload()
    }

    /// Publishes only validated, enabled, credential-free settings. The sink is explicit rather than a Combine
    /// subscription because `@Published` announces a mutation before the new value is installed.
    func installRuntimeSink(_ sink: @escaping ([ProviderRuntimeProfile]) -> Void) {
        runtimeSink = sink
        sink(runtimeSnapshot)
    }

    func reload() {
        guard let data = defaults.data(forKey: key) else {
            profiles = []
            loadIssue = nil
            publishRuntimeSnapshot()
            return
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == ProviderProfile.schemaVersion else { throw DocumentError.schema }
            profiles = try document.profiles.map(ProviderProfileValidator.normalized).sorted(by: Self.order)
            loadIssue = nil
        } catch {
            profiles = []
            loadIssue = L("Provider profiles could not be loaded. Create them again in Inspect.")
        }
        publishRuntimeSnapshot()
    }

    func save(_ profile: ProviderProfile) throws {
        let normalized = try ProviderProfileValidator.normalized(profile)
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == normalized.id }) {
            next[index] = normalized
        } else {
            next.append(normalized)
        }
        next.sort(by: Self.order)
        try persist(next)
        profiles = next
        loadIssue = nil
        publishRuntimeSnapshot()
    }

    func remove(id: ProviderProfile.ID) throws {
        var next = profiles
        next.removeAll { $0.id == id }
        try persist(next)
        profiles = next
        loadIssue = nil
        publishRuntimeSnapshot()
    }

    private var runtimeSnapshot: [ProviderRuntimeProfile] {
        profiles.filter(\.enabled).map {
            ProviderRuntimeProfile(id: $0.id, provider: $0.provider, endpoint: $0.endpoint,
                                   configuration: $0.configuration, pluginIDs: $0.pluginIDs)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func publishRuntimeSnapshot() {
        runtimeSink?(runtimeSnapshot)
    }

    private func persist(_ profiles: [ProviderProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(Document(schemaVersion: ProviderProfile.schemaVersion, profiles: profiles)), forKey: key)
    }

    private static func order(_ lhs: ProviderProfile, _ rhs: ProviderProfile) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var profiles: [ProviderProfile]
    }

    private enum DocumentError: Error { case schema }
}

private extension String {
    var providerNilIfEmpty: String? { isEmpty ? nil : self }
}
