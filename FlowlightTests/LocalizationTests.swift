import XCTest
@testable import Flowlight

/// Which language the interface speaks, and whether every language actually has the words.
final class LocalizationTests: XCTestCase {

    func testTheMacsLanguageIsMatchedIncludingTheChineseScripts() {
        // zh-Hans-CN and zh-CN are both Simplified; zh-TW, zh-HK and zh-Hant are Traditional. Getting this wrong
        // shows a Taiwanese user Simplified characters, which is the kind of mistake people notice immediately.
        XCTAssertEqual(AppLanguage.matching(["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-HK"]), .traditionalChinese)
    }

    func testARegionalVariantStillFindsItsLanguage() {
        XCTAssertEqual(AppLanguage.matching(["fr-CA"]), .french)
        XCTAssertEqual(AppLanguage.matching(["pt-BR"]), .portuguese)
        XCTAssertEqual(AppLanguage.matching(["es-419"]), .spanish)
        XCTAssertEqual(AppLanguage.matching(["de-AT"]), .german)
    }

    func testTheFirstLanguageFlowlightSpeaksWins() {
        // Someone whose Mac prefers Catalan and then French should get French, not English.
        XCTAssertEqual(AppLanguage.matching(["ca", "fr", "en"]), .french)
    }

    func testALanguageWeDoNotSpeakFallsBackRatherThanShowingNothing() {
        XCTAssertNil(AppLanguage.matching(["ca", "eu"]))
        XCTAssertEqual(AppLanguage.system.resolved == .english || AppLanguage.matching(Locale.preferredLanguages) != nil,
                       true, "system always resolves to something")
    }

    func testAChosenLanguageIsUsedAsIs() {
        XCTAssertEqual(AppLanguage.japanese.resolved, .japanese)
        XCTAssertEqual(AppLanguage.english.resolved, .english)
    }

    func testEveryLanguageIsNamedInItself() {
        // A picker that lists "Chinese" in English is no use to someone who reads only Chinese.
        XCTAssertEqual(AppLanguage.simplifiedChinese.title, "简体中文")
        XCTAssertEqual(AppLanguage.traditionalChinese.title, "繁體中文")
        XCTAssertEqual(AppLanguage.japanese.title, "日本語")
        XCTAssertEqual(AppLanguage.korean.title, "한국어")
        for language in AppLanguage.translated {
            XCTAssertFalse(language.title.isEmpty)
        }
    }

    func testEveryLanguageShipsAStringsFileWithTheSameKeys() throws {
        let english = try keys(for: "en")
        XCTAssertFalse(english.isEmpty, "the English table is missing from the bundle")
        for language in AppLanguage.translated where language != .english {
            let translated = try keys(for: language.rawValue)
            XCTAssertEqual(translated, english,
                           "\(language.rawValue) is missing \(english.subtracting(translated)) and has extra \(translated.subtracting(english))")
        }
    }

    /// Sample text a person is meant to type or recognise exactly: a header value and a list of example
    /// patterns. They are placeholders, not sentences, so every language keeps them as they are — translating
    /// `Bearer` would describe an HTTP scheme that doesn't exist.
    private static let verbatim: Set<String> = ["Bearer …", "github.com, 10.0.0.0/8…"]

    func testNothingIsLeftInEnglishByAccident() throws {
        // A key whose translation equals the English is either untranslated or a word that genuinely doesn't
        // change. The second is real — "Slack", "Live" in German — so this only guards the obviously wrong case.
        let untranslatedChinese = try values(for: "zh-Hans").filter { key, value in
            key == value && key.count > 6 && key.rangeOfCharacter(from: .whitespaces) != nil
                && !Self.verbatim.contains(key)
        }
        XCTAssertTrue(untranslatedChinese.isEmpty, "left in English in zh-Hans: \(untranslatedChinese.keys.sorted())")
    }

    private func table(for language: String) throws -> [String: String] {
        let path = try XCTUnwrap(Bundle(for: LocalizationTests.self).path(forResource: language, ofType: "lproj")
                                 ?? Bundle.main.path(forResource: language, ofType: "lproj"),
                                 "no \(language).lproj in the bundle")
        let file = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: file) as? [String: String], "unreadable \(language) table")
    }

    private func keys(for language: String) throws -> Set<String> { Set(try table(for: language).keys) }
    private func values(for language: String) throws -> [String: String] { try table(for: language) }
}

/// The Settings panel, which is where someone looks first after changing the language.
extension LocalizationTests {

    func testSettingsStringsAreActuallyTranslated() throws {
        let settingsKeys = ["Detection", "Storage", "Launch at login", "Run in the background",
                            "Check for updates automatically", "Ignore Apple's own apps",
                            "First contact with a new domain", "Z-score threshold"]
        for language in AppLanguage.translated where language != .english {
            let table = try values(for: language.rawValue)
            for key in settingsKeys {
                let value = try XCTUnwrap(table[key], "\(language.rawValue) has no \(key)")
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key, "\(language.rawValue) left \"\(key)\" in English")
            }
        }
    }
}
