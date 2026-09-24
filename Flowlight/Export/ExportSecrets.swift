import Foundation
import Security

/// The HTTP headers an export sends, kept in the login Keychain.
///
/// One of them is nearly always a bearer token or an API key. UserDefaults is a plist that any process running as
/// you can read and copy — which is precisely the kind of thing Flowlight exists to point at — so a credential
/// that belongs to someone's SIEM has no business living there. The whole header set goes in rather than just the
/// value, because the secret isn't always called `Authorization`: collectors variously want `X-Seq-ApiKey`,
/// `api-key`, `DD-API-KEY`, and guessing which of them is sensitive is a guess this code doesn't have to make.
///
/// Reading and writing our own item needs no prompt. A rebuild signed with a different identity is a different
/// program as far as the Keychain is concerned, so a local development build may ask once; a release build, which
/// keeps its Developer ID across versions, doesn't.
enum ExportSecrets {
    static let service = "com.flowlight.app.export"
    static let account = "headers"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> [String: String] {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let headers = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return headers
    }

    /// Replaces the stored set. Empty names and empty values are discarded, so a half-typed row in Settings never
    /// becomes a header with nothing in it, and an empty set removes the item rather than storing `{}`.
    @discardableResult
    static func save(_ headers: [String: String]) -> OSStatus {
        let cleaned = headers.filter { !$0.key.trimmed.isEmpty && !$0.value.trimmed.isEmpty }
        guard !cleaned.isEmpty else { return remove() }
        guard let data = try? JSONEncoder().encode(cleaned) else { return errSecParam }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrDescription as String] = "Flowlight export headers"
        add[kSecAttrLabel as String] = "Flowlight export"
        // This Mac only, and only while it's unlocked: a token for a collector on someone's own network has no
        // reason to travel to their other devices.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    static func remove() -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    /// Header names only, for anything that wants to say what will be sent without reading the values.
    static func names() -> [String] {
        load().keys.sorted()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
