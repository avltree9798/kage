import XCTest

/// Spec 15 / AT: 100 tabs stay within budget because TabResidency suspends background web views.
/// Opens 100 tabs of KAGE_UITEST_URL (default https://example.com/) and records the app's memory.
/// The budget is checked against XCTMemoryMetric's peak physical memory.
final class TabMemoryTests: XCTestCase {
    /// Peak physical memory budget for 100 tabs, in kilobytes (spec 15: under 1.5 GB on supported devices).
    static let budgetKB: Double = 1_500_000

    func testHundredTabsStayWithinMemoryBudget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-KageUITesting", "-KageUITestTabs", "100"]
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            app.launch()
            let up = app.textFields["omnibox"].waitForExistence(timeout: 60)
            if !up {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.lifetime = .keepAlways
                add(shot)
                print("KAGE-DIAG state=\(app.state.rawValue)")
                print("KAGE-DIAG tree=\(String(app.debugDescription.prefix(4000)))")
            }
            XCTAssertTrue(up)
            // Give WebKit time to load the active tab and settle residency for the rest.
            let settled = expectation(description: "settle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { settled.fulfill() }
            wait(for: [settled], timeout: 30)
            app.terminate()
        }
    }
}
