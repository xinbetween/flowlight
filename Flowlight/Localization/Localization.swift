import Foundation
import SwiftUI

/// The languages Flowlight is translated into, and how it decides which one to use.
///
/// The default follows the Mac. If the system's preferred languages include one Flowlight has been translated
/// into, that is what it speaks; otherwise English, because a half-understood interface is worse than a foreign
/// one someone can at least look up. The choice can be overridden in Settings, and takes effect immediately
/// rather than on next launch — a language picker that needs a restart to show its work is a language picker
/// people assume is broken.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Whatever the Mac is set to, falling back to English.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case spanish = "es"
    case portuguese = "pt-PT"

    var id: String { rawValue }

    /// Written in the language itself, which is the only way someone looking for their own language finds it.
    var title: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        }
    }

    /// The ones with a translation, in the order the picker shows them.
    static var translated: [AppLanguage] { allCases.filter { $0 != .system } }

    /// The language this resolves to for looking strings up. `system` asks the Mac.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Self.matching(Locale.preferredLanguages) ?? .english
    }

    /// The first of the Mac's preferred languages that Flowlight speaks.
    ///
    /// Matched on the language and, for Chinese, the script — `zh-Hans-CN` and `zh-CN` are both Simplified, and
    /// `zh-TW` and `zh-HK` are both Traditional. Anything else falls through to the plain language code, so
    /// `fr-CA` gets French rather than nothing.
    static func matching(_ preferred: [String]) -> AppLanguage? {
        for tag in preferred {
            let locale = Locale(identifier: tag)
            guard let code = locale.language.languageCode?.identifier else { continue }
            if code == "zh" {
                let script = locale.language.script?.identifier
                let region = locale.region?.identifier
                if script == "Hant" || region == "TW" || region == "HK" || region == "MO" {
                    return .traditionalChinese
                }
                return .simplifiedChinese
            }
            if let match = translated.first(where: { $0.rawValue.split(separator: "-").first.map(String.init) == code }) {
                return match
            }
        }
        return nil
    }
}

/// Which language the interface is in, and the bundle its words come from.
///
/// Strings are read through `L(_:)` rather than SwiftUI's automatic lookup, because the automatic one reads the
/// main bundle's language, which is fixed for the life of the process. Holding the bundle here is what lets the
/// picker change the language while the app is running.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    enum Keys { static let language = "app.language" }

    /// Bumped on every change so the interface can be rebuilt with the new words.
    @Published private(set) var revision = 0

    private(set) var bundle: Bundle = .main

    private init() {
        apply(language)
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: Keys.language) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.language)
            apply(newValue)
            revision += 1
            objectWillChange.send()
        }
    }

    /// What the interface is actually speaking, which is what the Settings screen should say when the choice is
    /// "System" — "System" alone leaves someone guessing which language that turned out to be.
    var effective: AppLanguage { language.resolved }

    private func apply(_ language: AppLanguage) {
        let resolved = language.resolved
        bundle = Bundle.main.path(forResource: resolved.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
            ?? .main
        // Also written where macOS looks, so the parts Flowlight doesn't draw itself — standard menu items, the
        // open and save panels, system alerts — follow on the next launch.
        UserDefaults.standard.set(language == .system ? nil : [resolved.rawValue], forKey: "AppleLanguages")
    }

    func string(_ key: String, comment: String = "") -> String {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        // A key with no translation falls back to English rather than showing the key itself, which is the
        // failure mode that makes a half-translated app look broken rather than incomplete.
        guard value == key, bundle != Bundle.main,
              let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        else { return value }
        return english.localizedString(forKey: key, value: key, table: nil)
    }
}

/// One short name for the thing done on almost every line of the interface.
///
/// The key *is* the English text. That keeps the source readable — `L("Capture")` says what it will show — and it
/// means an untranslated string degrades to correct English rather than to a dotted identifier.
@MainActor
func L(_ key: String) -> String {
    Localization.shared.string(key)
}

/// Interpolating version, for the sentences that carry a number or a name.
@MainActor
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.shared.string(key), arguments: arguments)
}
