import XCTest

final class PoliciesInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testPolicyHeadersAndPaintedRowsUseTheirWholeVisibleTarget() {
        launchPolicies()

        let ruleSection = element("policies.section.rule.toggle")
        XCTAssertTrue(ruleSection.waitForExistence(timeout: 15))
        clickTrailingBlankArea(of: ruleSection)
        XCTAssertTrue((ruleSection.value as? String)?.contains("Collapsed") == true)
        clickTrailingBlankArea(of: ruleSection)
        XCTAssertEqual(ruleSection.value as? String, "Expanded")

        let ruleID = "a14da4c2-7930-45c0-a8b9-3b8cd69c4a4e"
        let ruleButton = element("policies.rule.\(ruleID).edit")
        XCTAssertTrue(ruleButton.waitForExistence(timeout: 10))
        clickPaintedMargin(of: ruleButton)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))

        let ruleToggle = element("policies.rule.\(ruleID).enabled")
        XCTAssertTrue(ruleToggle.exists)
        ruleToggle.click()
        XCTAssertFalse(app.sheets.firstMatch.exists, "the independent switch must not invoke Edit")

        let ruleMenu = element("policies.rule.\(ruleID).menu")
        XCTAssertTrue(ruleMenu.exists)
        ruleMenu.click()
        XCTAssertTrue(app.menuItems["Edit…"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])

        let allowlistSection = element("policies.section.allowlist.toggle")
        XCTAssertTrue(allowlistSection.waitForExistence(timeout: 10))
        clickTrailingBlankArea(of: allowlistSection)
        XCTAssertTrue((allowlistSection.value as? String)?.contains("Collapsed") == true)

        let packSection = element("policies.section.pack.toggle")
        XCTAssertTrue(packSection.waitForExistence(timeout: 15))
        clickTrailingBlankArea(of: packSection)
        XCTAssertTrue((packSection.value as? String)?.contains("Collapsed") == true)
        clickTrailingBlankArea(of: packSection)
        XCTAssertEqual(packSection.value as? String, "Expanded")

        let catalogDetails = element("policies.pack-catalog.details.toggle")
        XCTAssertTrue(catalogDetails.waitForExistence(timeout: 10))
        clickPaintedMargin(of: catalogDetails)
        XCTAssertEqual(catalogDetails.value as? String, "Expanded")
        XCTAssertTrue(element("policies.pack-catalog.details.content").waitForExistence(timeout: 3))

        let packButton = element("policies.pack.official.advertising.open")
        XCTAssertTrue(packButton.waitForExistence(timeout: 10))
        let packToggle = element("policies.pack.official.advertising.enabled")
        let packReview = element("policies.pack.official.advertising.review")
        XCTAssertTrue(packToggle.exists)
        XCTAssertTrue(packReview.exists)

        packToggle.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))

        packReview.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))

        clickPaintedMargin(of: packButton)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
    }

    func testUpdateWarningOpensAfterTheMainWindowCloses() {
        app.launchArguments = [
            "-FLDemo", "YES",
            "-FLDemoUITests", "YES",
            "-FLDemoUITestDefaultsSuite", uiTestDefaultsSuite(),
            "-FLDemoExtensionUpdateWarning", "YES",
            "-FLScreen", "live",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        let mainWindow = app.windows["Live"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        let close = mainWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists)
        close.click()

        let warning = element("extension-update-warning")
        XCTAssertTrue(warning.waitForExistence(timeout: 10),
                      "the always-present menu-bar scene must present recovery without the main window")
        let message = element("extension-update-warning.message")
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertTrue(message.label.contains("0.18.0/84"))
        let expected = expectedExtensionIdentity()
        XCTAssertFalse(expected.isEmpty)
        XCTAssertTrue(message.label.contains(expected))
        app.buttons["Later"].click()
        XCTAssertFalse(warning.waitForExistence(timeout: 2))
    }

    private func expectedExtensionIdentity() -> String {
        let runnerProducts = Bundle.main.bundleURL.deletingLastPathComponent()
        let extensionURL = runnerProducts
            .appendingPathComponent("Flowlight.app", isDirectory: true)
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("com.flowlight.app.filter.systemextension", isDirectory: true)
        guard let bundle = Bundle(url: extensionURL),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !version.isEmpty, !build.isEmpty else {
            XCTFail("the UI runner must sit beside the exact Flowlight product it launches")
            return ""
        }
        return "\(version)/\(build)"
    }

    private func launchPolicies() {
        app.launchArguments = [
            "-FLDemo", "YES",
            "-FLDemoUITests", "YES",
            "-FLDemoUITestDefaultsSuite", uiTestDefaultsSuite(),
            "-FLDemoPackReview", "YES",
            "-FLScreen", "rules",
            "-FLRulesTab", "rules",
            "-FLDisableMotion", "YES",
            "-AppleLanguages", "(en)",
        ]
        app.launch()
    }

    private func uiTestDefaultsSuite() -> String {
        "com.flowlight.ui-tests.\(UUID().uuidString)"
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func clickTrailingBlankArea(of element: XCUIElement) {
        XCTAssertGreaterThan(element.frame.width, 120, "the disclosure hit target must span the painted row")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
    }

    private func clickPaintedMargin(of element: XCUIElement) {
        XCTAssertGreaterThan(element.frame.width, 120, "the painted card must expose its full geometry")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.9)).click()
    }
}
