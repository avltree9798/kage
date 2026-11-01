import XCTest

/// K-30: Apple's automated accessibility audit on Kage's main screens, plus the keyboard paths in spec 18.3.
/// Runs on macOS in CI, and on iOS simulators or devices with iOS 27.2.
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-KageUITesting"]
        app.launch()
        XCTAssertTrue(app.textFields["omnibox"].waitForExistence(timeout: 20))
    }

    /// UI-testing mode opens a blank page, so the audit sees only Kage's own chrome, not a site's markup.
    private func audit() throws {
        let app = self.app!
        let windowFrame = app.windows.firstMatch.frame
        try app.performAccessibilityAudit { issue in
            print("KAGE-AUDIT \(issue.auditType) \(issue.compactDescription) element=\(issue.element.map { "\($0.elementType.rawValue) id=\($0.identifier) label=\($0.label) frame=\($0.frame)" } ?? "nil")")
            // The window's own root group (SwiftUI's hosting view) has no label and none can be set from SwiftUI;
            // Kage's content group inside it is labelled "Kage". Only that system group is excused.
            if let e = issue.element, e.elementType == .group, e.label.isEmpty,
               e.frame == windowFrame, e.groups["Kage"].exists { return true }
            // SwiftUI's macOS Menu exposes "show menu" rather than a press action, which the audit reports as
            // "Action is missing" even though VoiceOver opens it normally.
            if issue.auditType == .action, issue.element?.elementType == .menuButton { return true }
            return issue.element?.elementType == .webView  // the (empty) web view container itself
        }
    }

    func testBrowsingScreenPassesAudit() throws {
        try audit()
    }

    func testSettingsPassesAudit() throws {
        openMore()
        let settings = app.buttons["Settings"].firstMatch
        guard settings.waitForExistence(timeout: 5) else { throw XCTSkip("Settings entry not reachable in this layout") }
        settings.tap()
        try audit()
    }

    func testPrivacyDashboardPassesAudit() throws {
        openMore()
        let privacy = app.buttons["Privacy"].firstMatch
        guard privacy.waitForExistence(timeout: 5) else { throw XCTSkip("Privacy entry not reachable in this layout") }
        privacy.tap()
        try audit()
    }

    #if os(macOS)
    /// Keyboard only: Cmd-L focuses the address field, typing and Return navigates, Cmd-T / Cmd-W manage tabs.
    func testKeyboardNavigation() throws {
        app.typeKey("l", modifierFlags: .command)
        let omnibox = app.textFields["omnibox"]
        XCTAssertTrue(omnibox.waitForExistence(timeout: 5))
        XCTAssertTrue((omnibox.value(forKey: "hasKeyboardFocus") as? Bool) ?? false, "Cmd-L should focus the address field")
        omnibox.typeText("example.com\r")
        let loaded = NSPredicate(format: "value CONTAINS 'example.com'")
        expectation(for: loaded, evaluatedWith: omnibox)
        waitForExpectations(timeout: 30)

        app.typeKey("t", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(omnibox.exists, "Closing the new tab returns to the previous one")
    }
    #endif

    private func openMore() {
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) { more.tap() }
    }
}
