import Foundation

enum RulePackCatalogComposition {
    /// The signed feed may replace a built-in with the same stable ID or add an official pack. Omission is not a
    /// tombstone: every built-in remains available as the signed-app emergency baseline.
    static func compose(_ catalog: VerifiedRulePackCatalog,
                        currentAppVersion: String,
                        builtIns: [RulePackDefinition] = BuiltInRulePacks.all) throws -> VerifiedRulePackCatalog {
        try RulePackValidator.validate(builtIns, currentAppVersion: currentAppVersion)
        try RulePackValidator.validate(catalog.definitions, currentAppVersion: currentAppVersion)

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
        try RulePackValidator.validate(composed.definitions, currentAppVersion: currentAppVersion)
        return composed
    }
}
