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
        XCTAssertTrue(waitForDisappearance(app.sheets.firstMatch, timeout: 1))

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
        XCTAssertTrue(waitForDisappearance(app.sheets.firstMatch, timeout: 1))

        element("policies.pack.official.advertising.review").click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertTrue(waitForDisappearance(app.sheets.firstMatch, timeout: 1))

        clickPaintedMargin(of: element("policies.pack.official.advertising.open"))
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
    }

    func testAdvertisingTiersAreOrderedRiskLabeledAndReplaceAtomically() {
        launchPolicies()

        let balancedRow = element("policies.pack.official.advertising.open")
        let aggressiveRow = element("policies.pack.official.advertising-aggressive.open")
        XCTAssertTrue(balancedRow.waitForExistence(timeout: 15))
        XCTAssertTrue(aggressiveRow.waitForExistence(timeout: 15))
        XCTAssertLessThan(balancedRow.frame.minY, aggressiveRow.frame.minY)
        XCTAssertTrue(accessibilityText(of: balancedRow).contains("Recommended · Balanced"))
        XCTAssertTrue(accessibilityText(of: aggressiveRow).contains("Opt-in · Higher breakage"))

        let balancedToggleID = "policies.pack.official.advertising.enabled"
        let aggressiveToggleID = "policies.pack.official.advertising-aggressive.enabled"
        let balancedToggle = element(balancedToggleID)
        let aggressiveToggle = element(aggressiveToggleID)
        XCTAssertTrue(balancedToggle.exists)
        XCTAssertTrue(aggressiveToggle.exists)
        XCTAssertNotEqual(balancedToggle.identifier, aggressiveToggle.identifier)

        balancedToggle.click()
        XCTAssertTrue(element("rule-pack-editor.official.advertising.save").waitForExistence(timeout: 5))
        XCTAssertTrue(element("rule-pack-editor.official.advertising.badge").exists)
        XCTAssertTrue(element("rule-pack-editor.official.advertising.limitations").exists)
        let balancedProvenance = element("rule-pack-editor.official.advertising.provenance")
        XCTAssertTrue(balancedProvenance.exists)
        XCTAssertTrue(accessibilityText(of: balancedProvenance).contains("The EasyList authors"))
        XCTAssertTrue(accessibilityText(of: balancedProvenance).contains("GPL-3.0-or-later · GPL-3.0 · MPL-2.0"))
        element("rule-pack-editor.official.advertising.save").click()
        XCTAssertTrue(waitForDisappearance(app.sheets.firstMatch, timeout: 3))
        XCTAssertTrue(waitForValue("1", identifier: balancedToggleID, timeout: 3))
        XCTAssertTrue(waitForValue("0", identifier: aggressiveToggleID, timeout: 3))
        XCTAssertTrue(waitForAccessibilityText(
            containing: "replaces Advertising",
            identifier: "policies.pack.official.advertising-aggressive.open",
            timeout: 3
        ))

        element(aggressiveToggleID).click()
        XCTAssertTrue(element("rule-pack-editor.official.advertising-aggressive.save").waitForExistence(timeout: 5))
        XCTAssertTrue(element("rule-pack-editor.official.advertising-aggressive.badge").exists)
        XCTAssertTrue(element("rule-pack-editor.official.advertising-aggressive.limitations").exists)
        XCTAssertTrue(element("rule-pack-editor.official.advertising-aggressive.provenance").exists)
        element("rule-pack-editor.official.advertising-aggressive.save").click()
        XCTAssertTrue(app.buttons["Replace Advertising"].waitForExistence(timeout: 3))
        app.buttons["Replace Advertising"].click()
        XCTAssertTrue(app.buttons["Enable aggressive blocking"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("rule-pack-editor.official.advertising-aggressive.cancel").exists)
        element("rule-pack-editor.official.advertising-aggressive.cancel").click()
        XCTAssertTrue(waitForDisappearance(app.sheets.firstMatch, timeout: 3))
        XCTAssertTrue(
            waitForValue("1", identifier: balancedToggleID, timeout: 3),
            "cancelling must preserve balanced enforcement"
        )
        XCTAssertTrue(
            waitForValue("0", identifier: aggressiveToggleID, timeout: 3),
            "cancelling must not enable aggressive enforcement"
        )

        element(aggressiveToggleID).click()
        XCTAssertTrue(element("rule-pack-editor.official.advertising-aggressive.save").waitForExistence(timeout: 5))
        element("rule-pack-editor.official.advertising-aggressive.save").click()
        XCTAssertTrue(app.buttons["Replace Advertising"].waitForExistence(timeout: 3))
        app.buttons["Replace Advertising"].click()
        XCTAssertTrue(app.buttons["Enable aggressive blocking"].waitForExistence(timeout: 3))
        app.buttons["Enable aggressive blocking"].click()
        XCTAssertTrue(waitForDisappearance(app.sheets.firstMatch, timeout: 5))
        XCTAssertTrue(waitForValue("0", identifier: balancedToggleID, timeout: 3))
        XCTAssertTrue(waitForValue("1", identifier: aggressiveToggleID, timeout: 3))
        XCTAssertTrue(waitForAccessibilityText(
            containing: "replaces Advertising — Aggressive",
            identifier: "policies.pack.official.advertising.open",
            timeout: 3
        ))
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
        let warningText = accessibilityText(of: message)
        XCTAssertTrue(warningText.contains("0.18.0/84"),
                      "the accessible warning must name the active filter: \(warningText)")
        let expected = expectedExtensionIdentity()
        XCTAssertFalse(expected.isEmpty)
        XCTAssertTrue(warningText.contains(expected),
                      "the accessible warning must name the installed filter: \(warningText)")
        app.buttons["Later"].click()
        XCTAssertTrue(waitForDisappearance(warning, timeout: 2))
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard element.waitForNonExistence(timeout: timeout) else { return false }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return !element.exists }
        let reappearance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: element
        )
        reappearance.isInverted = true
        return XCTWaiter.wait(for: [reappearance], timeout: remaining) == .completed
    }

    private func waitForValue(_ expected: String, identifier: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: element(identifier)
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForAccessibilityText(
        containing expected: String,
        identifier: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected),
            object: element(identifier)
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func accessibilityText(of element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
            "-FLPinScreenshotScreen", "YES",
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
