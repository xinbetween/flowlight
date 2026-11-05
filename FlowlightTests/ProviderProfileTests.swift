import XCTest
@testable import Flowlight

@MainActor
final class ProviderProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "flowlight.provider-profile.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    func testStorePersistsVersionedNonSecretProfile() throws {
        let store = ProviderProfileStore(defaults: defaults)
        let id = UUID()
        try store.save(ProviderProfile(
            id: id,
            name: "  Presidio local  ",
            provider: .presidio,
            endpoint: "http://localhost:3000/analyze",
            configuration: ["policy": "strict"],
            pluginIDs: ["official.presidio", "official.presidio"],
            credentialReference: "keychain:flowlight/presidio"
        ))

        let reloaded = ProviderProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles[0].id, id)
        XCTAssertEqual(reloaded.profiles[0].name, "Presidio local")
        XCTAssertEqual(reloaded.profiles[0].pluginIDs, ["official.presidio"])
        XCTAssertEqual(reloaded.profiles[0].credentialReference, "keychain:flowlight/presidio")

        let raw = try XCTUnwrap(defaults.data(forKey: "inspectionProviderProfiles"))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\":1"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
    }

    func testValidationRejectsRemotePlaintextAndEmbeddedCredentials() {
        XCTAssertThrowsError(try ProviderProfileValidator.normalized(ProviderProfile(
            name: "Remote", provider: .custom, endpoint: "http://provider.example.test/analyze"
        ))) { XCTAssertEqual($0 as? ProviderProfileValidationError, .endpoint) }

        XCTAssertThrowsError(try ProviderProfileValidator.normalized(ProviderProfile(
            name: "Embedded", provider: .custom, endpoint: "https://user:pass@provider.example.test/analyze"
        ))) { XCTAssertEqual($0 as? ProviderProfileValidationError, .endpoint) }

        XCTAssertThrowsError(try ProviderProfileValidator.normalized(ProviderProfile(
            name: "Query secret", provider: .custom,
            endpoint: "https://provider.example.test/analyze?api_key=sk-live-secret"
        ))) { XCTAssertEqual($0 as? ProviderProfileValidationError, .endpoint) }
    }

    func testValidationRejectsCredentialValuesAndSecretConfigurationKeys() {
        XCTAssertThrowsError(try ProviderProfileValidator.normalized(ProviderProfile(
            name: "Raw secret", provider: .bedrock, credentialReference: "sk-live-secret"
        ))) { XCTAssertEqual($0 as? ProviderProfileValidationError, .credentialReference) }

        for key in ["api_key", "Authorization", "access-token", "privateKey"] {
            XCTAssertThrowsError(try ProviderProfileValidator.normalized(ProviderProfile(
                name: "Secret option", provider: .custom, configuration: [key: "not-persisted"]
            )), "must reject \(key)") { XCTAssertEqual($0 as? ProviderProfileValidationError, .configuration) }
        }
        for value in ["sk-live-secret", "Bearer opaque-value", "eyJhbGciOiJIUzI1NiJ9.payload.signature",
                      String(repeating: "a", count: 40)] {
            XCTAssertThrowsError(try ProviderProfileValidator.normalized(ProviderProfile(
                name: "Secret value", provider: .custom, configuration: ["account": value]
            )), "must reject credential-like value") {
                XCTAssertEqual($0 as? ProviderProfileValidationError, .configuration)
            }
        }
    }

    func testHealthReasonsAreDeterministicAndDoNotExposeConfiguration() {
        let plugin = PluginManifest(
            id: "official.presidio", name: "Presidio", version: "1", kind: .llmMCP,
            guardrailProvider: .presidio, description: "PII", privacySummary: "Metadata"
        )
        let profile = ProviderProfile(
            name: "PII", provider: .presidio, configuration: ["region": "private-value"],
            pluginIDs: [plugin.id], credentialReference: "keychain:flowlight/presidio"
        )

        XCTAssertEqual(profile.health(manifests: [plugin]), .ready("1 inspection plugin assigned."))
        let reason = profile.health(manifests: [plugin]).reason
        XCTAssertFalse(reason.contains("private-value"))
        XCTAssertFalse(reason.contains("keychain:"))

        var disabledPlugin = plugin
        disabledPlugin.enabled = false
        XCTAssertEqual(profile.health(manifests: [disabledPlugin]), .attention("Every assigned plugin is disabled."))
        XCTAssertEqual(profile.health(manifests: []), .attention("An assigned plugin is no longer installed."))
    }

    func testUnsupportedSchemaFailsClosedWithoutLeakingDocument() {
        defaults.set(Data(#"{"schemaVersion":99,"profiles":[]}"#.utf8), forKey: "inspectionProviderProfiles")
        let store = ProviderProfileStore(defaults: defaults)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.loadIssue, "Provider profiles could not be loaded. Create them again in Inspect.")
        XCTAssertFalse(store.loadIssue?.contains("99") == true)
    }
}
