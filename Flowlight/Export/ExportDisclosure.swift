import Foundation
import CryptoKit

/// What leaves the Mac, shown before the first row does.
///
/// Flowlight's whole argument is that software should say what it sends and where. The export is the one place
/// Flowlight itself sends anything substantial — recorded traffic, to a collector somebody typed into a text
/// field — and until now it started doing that the moment a switch was flipped. The disclosure every other app
/// is judged by, applied here.
///
/// Consent is tied to *what was disclosed*, not to the act of agreeing once. Approving a TLS endpoint carrying
/// six fields must not silently authorise a cleartext one carrying twenty: the fingerprint below covers the
/// destination, the transport, the field set and the header names, and when any of those change the export
/// stops and asks again. That is the difference between informed consent and a dialog someone dismissed.
struct ExportDisclosure: Equatable, Identifiable {

    /// Identity is the fingerprint: a different disclosure is a different question.
    var id: String { fingerprint }

    /// One line per thing that will travel, in the order the payload carries them.
    struct Item: Equatable, Identifiable {
        var id: String { key }
        var key: String
        var what: String
        /// True for the three resource fields sent once per request rather than once per record, because
        /// "sent with every row" and "sent once" are different exposures.
        var perRequest: Bool
    }

    var endpoint: String
    var host: String
    /// Whether the collector is reached over TLS. A cleartext endpoint means every field below crosses the
    /// network readable by anything on the path, which is worth saying in those words rather than showing a
    /// scheme and expecting the reader to draw the conclusion.
    var encrypted: Bool
    var mode: ExportMode
    var items: [Item]
    /// Header *names* only. The values live in the Keychain and are never shown, not even here — a disclosure
    /// screen that prints an API token to prove it is being sent would be its own problem.
    var headerNames: [String]
    var includesAlerts: Bool
    var includesRollups: Bool

    var fieldCount: Int { items.count }

    /// A stable summary of everything disclosed. Consent is recorded against this, so changing any part of it
    /// withdraws the consent rather than inheriting it.
    var fingerprint: String {
        var parts = [endpoint, mode.rawValue, encrypted ? "tls" : "cleartext",
                     includesRollups ? "rollups" : "", includesAlerts ? "alerts" : ""]
        parts += items.map(\.key).sorted()
        parts += headerNames.sorted().map { "h:" + $0 }
        let joined = parts.joined(separator: "\u{1}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What the disclosure says in one line, for the settings row that summarises it once approved.
    var summary: String {
        // Two whole sentences, not a clause posted into a %@. A translator handed "%lld fields, %@." cannot see
        // that the second argument is "encrypted to <host>", and languages that need the destination before the
        // count have nowhere to put it. This project has shipped that mistake before.
        encrypted ? L("%lld fields, encrypted to %@.", fieldCount, host)
                  : L("%lld fields, in cleartext to %@.", fieldCount, host)
    }

    static func build(configuration: ExportConfiguration, headers: [String: String]) -> ExportDisclosure? {
        guard let url = configuration.endpointURL else { return nil }
        let fields = configuration.enabledFields
        let perRequest: Set<ExportField> = [.serviceName, .serviceVersion, .hostName]
        return ExportDisclosure(
            endpoint: url.absoluteString,
            host: url.host ?? url.absoluteString,
            encrypted: url.scheme?.lowercased() == "https",
            mode: configuration.mode,
            items: fields.map { Item(key: $0.rawValue, what: $0.what, perRequest: perRequest.contains($0)) },
            headerNames: headers.keys.sorted(),
            includesAlerts: configuration.includeAlerts,
            includesRollups: configuration.includeRollups)
    }

    // MARK: Consent

    enum Keys {
        /// The fingerprint of the disclosure the user last approved.
        static let approved = "export.disclosureApproved"
    }

    /// Whether what is about to be sent is what was agreed to.
    static func isApproved(_ disclosure: ExportDisclosure?, defaults: UserDefaults = .standard) -> Bool {
        guard let disclosure else { return false }
        return defaults.string(forKey: Keys.approved) == disclosure.fingerprint
    }

    static func approve(_ disclosure: ExportDisclosure, defaults: UserDefaults = .standard) {
        defaults.set(disclosure.fingerprint, forKey: Keys.approved)
    }

    /// Forget the approval. Used when export is switched off: turning it on again is a fresh decision, and the
    /// settings may have been edited while it was off.
    static func withdraw(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.approved)
    }
}
