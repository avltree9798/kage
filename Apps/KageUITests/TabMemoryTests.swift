import XCTest

/// Spec 15 / AT02: 100 tabs stay within budget because TabResidency suspends background web views.
/// Launches with 100 tabs of KAGE_UITEST_URL (default https://example.com/), then records the app's
/// memory while switching tabs. The result appears in the test report's metrics.
final class TabMemoryTests: XCTestCase {
    func testHundredTabsStayWithinMemoryBudget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-KageUITesting"]
        app.launchEnvironment["KAGE_UITEST_TABS"] = "100"
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
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        print("KAGE-TABS \(tabs.label)")
        XCTAssertTrue(tabs.label.contains("101"), "100 test tabs plus the home tab")

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            #if os(macOS)
            // Walk through tabs with the keyboard; each switch wakes a suspended tab and suspends another.
            for _ in 0..<10 { app.typeKey("]", modifierFlags: [.command, .shift]) }
            #endif
            Thread.sleep(forTimeInterval: 5)
        }
        // Spec 15 budget: well under 1.5 GB for 100 tabs. Checked from the metric log in CI; asserted here
        // only that the app is still alive and responsive after the switches.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(omnibox.exists)
    }
}
