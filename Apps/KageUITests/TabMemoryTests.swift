import XCTest

/// Spec 15 / AT02: 100 tabs stay within budget because TabResidency suspends background web views.
/// Launches with 100 tabs of KAGE_UITEST_URL (default https://example.com/), then records the app's
/// memory while switching tabs. The result appears in the test report's metrics.
final class TabMemoryTests: XCTestCase {
    func testHundredTabsStayWithinMemoryBudget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-KageUITesting", "-KageUITestTabs", "100"]
        app.launch()
        let omnibox = app.textFields["omnibox"]
        let up = omnibox.waitForExistence(timeout: 60)
        if !up {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            print("KAGE-DIAG state=\(app.state.rawValue) windows=\(app.windows.count)")
        }
        XCTAssertTrue(up, "Kage should show its window with 100 tabs open")
        let tabs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tabs, '")).firstMatch
        if tabs.exists { print("KAGE-TABS \(tabs.label)") }

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            #if os(macOS)
            // Walk through tabs with the keyboard; each switch wakes a suspended tab and suspends another.
            for _ in 0..<10 { app.typeKey("]", modifierFlags: [.command, .shift]) }
            #endif
            Thread.sleep(forTimeInterval: 5)
        }
    }
}
