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

        let ruleSectionID = "policies.section.rule.toggle"
        XCTAssertTrue(element(ruleSectionID).waitForExistence(timeout: 15))
        let ruleID = "a14da4c2-7930-45c0-a8b9-3b8cd69c4a4e"
        let ruleButton = element("policies.rule.\(ruleID).edit")
        let initiallyExpanded = ruleButton.waitForExistence(timeout: 3)

        // The macOS SwiftUI bridge does not consistently expose accessibilityValue after a coordinate click. Use the
        // row that the disclosure actually inserts/removes as the observable contract, while still clicking the
        // trailing 90% of the full visible header. This also normalizes a restored host state without trusting stale
        // accessibility metadata.
        clickTrailingBlankArea(of: element(ruleSectionID))
        if initiallyExpanded {
            XCTAssertTrue(ruleButton.waitForNonExistence(timeout: 3),
                          "a trailing click must collapse the network-rules content")
        } else {
            XCTAssertTrue(ruleButton.waitForExistence(timeout: 3),
                          "a trailing click must expand the network-rules content")
        }
        clickTrailingBlankArea(of: element(ruleSectionID))
        if initiallyExpanded {
            XCTAssertTrue(ruleButton.waitForExistence(timeout: 3),
                          "a trailing click must expand the network-rules content")
        } else {
            XCTAssertTrue(ruleButton.waitForNonExistence(timeout: 3),
                          "a trailing click must collapse the network-rules content")
        }

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

        let allowlistSectionID = "policies.section.allowlist.toggle"
        XCTAssertTrue(element(allowlistSectionID).waitForExistence(timeout: 10))
        clickTrailingBlankArea(of: element(allowlistSectionID))
        XCTAssertTrue(waitForDisclosureState("Collapsed", identifier: allowlistSectionID, timeout: 3))

        let packSectionID = "policies.section.pack.toggle"
        XCTAssertTrue(element(packSectionID).waitForExistence(timeout: 15))
        clickTrailingBlankArea(of: element(packSectionID))
        XCTAssertTrue(waitForDisclosureState("Collapsed", identifier: packSectionID, timeout: 3))
        clickTrailingBlankArea(of: element(packSectionID))
        XCTAssertTrue(waitForDisclosureState("Expanded", identifier: packSectionID, timeout: 3))

        let catalogDetailsID = "policies.pack-catalog.details.toggle"
        XCTAssertTrue(element(catalogDetailsID).waitForExistence(timeout: 10))
        clickPaintedMargin(of: element(catalogDetailsID))
        XCTAssertTrue(waitForDisclosureState("Expanded", identifier: catalogDetailsID, timeout: 3))
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
        XCTAssertTrue(app.sheets.firstMatch.buttons["Replace Advertising"].waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["Replace Advertising"].click()
        XCTAssertTrue(app.sheets.firstMatch.buttons["Enable aggressive blocking"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.sheets.firstMatch.buttons["Replace Advertising"].waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["Replace Advertising"].click()
        XCTAssertTrue(app.sheets.firstMatch.buttons["Enable aggressive blocking"].waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["Enable aggressive blocking"].click()
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
            // Keep this test independent of a prior background-only launch. The warning is expected to recover a
            // normally visible main window after it closes; background-only suppression is covered by AppKit tests.
            "-app.backgroundOnly", "NO",
            "-FLScreen", "live",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        let mainWindow = waitForMainWindow(timeout: 10)
        XCTAssertTrue(mainWindow.exists)
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

    func testMenuBarAlertReviewRestoresMinimizedAndClosedBackgroundWindow() {
        app.launchArguments = [
            "-FLDemo", "YES",
            "-FLDemoUITests", "YES",
            "-FLDemoUITestDefaultsSuite", uiTestDefaultsSuite(),
            "-FLDemoAlertReview", "YES",
            // Start with a visible scene so this test can exercise both minimize and close before using the
            // production menu-bar presentation path. Background-only launch suppression is covered separately by
            // the focused AppKit lifecycle test and the real isolated demo acceptance.
            "-app.backgroundOnly", "NO",
            "-FLScreen", "live",
            "-AppleLanguages", "(en)",
        ]
        // Newer Xcode hosts do not consistently forward every custom launch argument into the app process. Keep
        // the disposable alert fixture explicit through the launch environment as well as the documented arguments.
        app.launchEnvironment["FLDemo"] = "YES"
        app.launchEnvironment["FLDemoUITests"] = "YES"
        app.launchEnvironment["FLDemoAlertReview"] = "YES"
        app.launch()

        let liveWindow = waitForMainWindow(timeout: 10)
        XCTAssertTrue(liveWindow.exists)
        let minimize = liveWindow.buttons[XCUIIdentifierMinimizeWindow]
        XCTAssertTrue(minimize.exists)
        minimize.click()

        reviewNewAlertsFromMenuBar()
        assertNewAlertReview()
        XCTAssertEqual(app.windows.count, 1,
                       "restoring alert review must not revive duplicate main scenes")

        let alertWindow = waitForMainWindow(timeout: 10)
        XCTAssertTrue(alertWindow.exists)
        let close = alertWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists)
        close.click()
        XCTAssertTrue(alertWindow.waitForNonExistence(timeout: 3))

        reviewNewAlertsFromMenuBar()
        assertNewAlertReview()
        XCTAssertEqual(app.windows.count, 1,
                       "reopening alert review must reuse the one main scene")
    }

    private func reviewNewAlertsFromMenuBar() {
        let statusItem = app.descendants(matching: .statusItem)["menu.status"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10))
        // The status item itself is the warning/count affordance. Open it before querying the action so this test
        // verifies the behavior users need even when macOS's status-item accessibility label is stale.
        statusItem.click()

        // MenuBarExtra promotes SwiftUI Buttons into a host-native accessibility element. Newer Xcode hosts can expose
        // that element as a Button rather than a MenuItem and can drop the SwiftUI identifier, so search the complete
        // open-menu tree by its stable spoken label and its count-bearing visible label.
        let identified = element("menu.review-new-alerts")
        let labeled = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "unacknowledged alert",
                "unacknowledged alert",
                "Review new alerts"
            )
        ).firstMatch
        let review = identified.waitForExistence(timeout: 1) ? identified : labeled
        XCTAssertTrue(review.waitForExistence(timeout: 3),
                      "the open menu must expose the actionable unacknowledged-alert item")
        review.click()
    }

    private func assertNewAlertReview() {
        let mainWindow = waitForMainWindow(timeout: 10)
        XCTAssertTrue(mainWindow.exists)
        XCTAssertTrue(element("alerts.table").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAccessibilityText(containing: "New", identifier: "alerts.filter", timeout: 3))
        XCTAssertTrue(waitForValue("Selected", identifier: "alerts.row.2", timeout: 3),
                      "the newest New alert must receive keyboard selection")
        XCTAssertTrue(element("alerts.row.1").exists)
        XCTAssertFalse(element("alerts.row.3").exists,
                       "an acknowledged alert must not appear in the New-only review")
    }

    /// Window titles are localized/navigation-dependent on macOS; the scene itself is the stable contract.
    /// Prefer the legacy title when available, then fall back to the actual main scene exposed by the app.
    private func waitForMainWindow(timeout: TimeInterval) -> XCUIElement {
        let titled = app.windows["Live"]
        if titled.waitForExistence(timeout: min(timeout, 2)) { return titled }
        let named = app.windows["Flowlight"]
        if named.waitForExistence(timeout: min(timeout, 2)) { return named }
        let first = app.windows.firstMatch
        _ = first.waitForExistence(timeout: timeout)
        return first
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
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement, element.exists else { return false }
                if let value = element.value as? String { return value == expected }
                if let value = element.value as? NSNumber { return value.stringValue == expected }
                return false
            },
            object: element(identifier)
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisclosureState(
        _ expected: String,
        identifier: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement,
                      element.exists,
                      let value = element.value as? String else { return false }
                if expected == "Collapsed" {
                    return value == expected || value.hasPrefix(expected + " · ")
                }
                return value == expected
            },
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
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement, element.exists else { return false }
                return self.accessibilityText(of: element).contains(expected)
            },
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
            // Explicitly reset the shared UserDefaults key after any background-only lifecycle test.
            "-app.backgroundOnly", "NO",
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
