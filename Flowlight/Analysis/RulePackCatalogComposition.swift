import Foundation

/// A catalog whose definitions have crossed the complete validator boundary. The initializer is intentionally scoped
/// to this file: updater installs can skip repeated validation only after composition has proved both the signed feed
/// and the independently supplied built-ins. Manually constructed `VerifiedRulePackCatalog` values still take the
/// validating store overload.
struct ValidatedRulePackCatalog: Equatable, Sendable {
    let catalog: VerifiedRulePackCatalog

    fileprivate init(_ catalog: VerifiedRulePackCatalog) {
        self.catalog = catalog
    }

    var definitions: [RulePackDefinition] { catalog.definitions }
    var sequence: Int64 { catalog.sequence }
    var digest: String { catalog.digest }
    var stale: Bool { catalog.stale }
}

enum RulePackCatalogComposition {
    /// The signed feed may replace a built-in with the same stable ID or add an official pack. Omission is not a
    /// tombstone: every built-in remains available as the signed-app emergency baseline.
    static func compose(_ catalog: VerifiedRulePackCatalog,
                        currentAppVersion: String,
                        builtIns: [RulePackDefinition] = BuiltInRulePacks.all) throws -> VerifiedRulePackCatalog {
        try compose(
            catalog,
            currentAppVersion: currentAppVersion,
            builtIns: builtIns,
            validateCatalogDefinitions: true
        )
    }

    /// `RulePackCatalogVerifier.verify` already validates every signed definition. The updater uses this path to avoid
    /// repeating the full entry validation twice during startup while still validating the independent built-in set.
    static func composeVerified(_ catalog: VerifiedRulePackCatalog,
                                currentAppVersion: String,
                                builtIns: [RulePackDefinition] = BuiltInRulePacks.all) throws -> ValidatedRulePackCatalog {
        ValidatedRulePackCatalog(try compose(
            catalog,
            currentAppVersion: currentAppVersion,
            builtIns: builtIns,
            validateCatalogDefinitions: false
        ))
    }

    private static func compose(_ catalog: VerifiedRulePackCatalog,
                                currentAppVersion: String,
                                builtIns: [RulePackDefinition],
                                validateCatalogDefinitions: Bool) throws -> VerifiedRulePackCatalog {
        try RulePackValidator.validate(builtIns, currentAppVersion: currentAppVersion)
        if validateCatalogDefinitions {
            try RulePackValidator.validate(catalog.definitions, currentAppVersion: currentAppVersion)
        }

        var merged: [String: RulePackDefinition] = [:]
        for definition in builtIns {
            guard merged.updateValue(definition, forKey: definition.id) == nil else {
                throw RulePackValidationError.duplicatePack(definition.id)
            }
        }
        for definition in catalog.definitions {
            guard definition.id.hasPrefix("official.") else {
                throw RulePackValidationError.invalidPackID(definition.id)
            }
            merged[definition.id] = definition
        }

        var composed = catalog
        composed.definitions = merged.values.sorted { $0.id < $1.id }
        return composed
    }
}
