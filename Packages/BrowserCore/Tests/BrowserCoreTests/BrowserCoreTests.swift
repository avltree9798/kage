import Foundation
import Testing
import KageModels
@testable import BrowserCore

@Suite struct NavigationPolicyTests {
    @Test func webSchemesAllowed() {
        #expect(NavigationPolicy.decide(URL(string: "https://a.test")!, isMainFrame: true, userInitiated: false) == .allow)
    }

    @Test func dangerousSchemesBlocked() {
        if case .block = NavigationPolicy.decide(URL(string: "javascript:alert(1)")!, isMainFrame: true, userInitiated: true) {} else { Issue.record("js not blocked") }
        if case .block = NavigationPolicy.decide(URL(string: "data:text/html,hi")!, isMainFrame: true, userInitiated: true) {} else { Issue.record("data not blocked") }
        if case .block = NavigationPolicy.decide(URL(string: "file:///etc/passwd")!, isMainFrame: true, userInitiated: true) {} else { Issue.record("file not blocked") }
        #expect(NavigationPolicy.decide(URL(string: "data:image/png;base64,AA")!, isMainFrame: false, userInitiated: false) == .allow)
    }

    @Test func externalAppsNeedAGesture() {
        let mail = URL(string: "mailto:a@b.test")!
        #expect(NavigationPolicy.decide(mail, isMainFrame: true, userInitiated: true) == .askToOpenExternally(mail))
        if case .block = NavigationPolicy.decide(mail, isMainFrame: true, userInitiated: false) {} else { Issue.record("auto external not blocked") }
    }
}

@Suite struct TabResidencyTests {
    func tab(_ age: TimeInterval, pinned: Bool = false) -> BrowserTab {
        BrowserTab(url: nil, profileID: UUID(), lastActiveAt: Date(timeIntervalSince1970: age), isPinned: pinned)
    }

    // AT02: 100 logical tabs, bounded live WebViews.
    @Test func hundredTabsKeepOnlyCapResident() {
        let tabs = (0..<100).map { tab(Double($0)) }
        let active = tabs[10].id
        let victims = TabResidencyPolicy.tabsToSuspend(resident: tabs, activeID: active, maxResident: 6)
        #expect(victims.count == 94)
        #expect(!victims.contains(active))
        // The most recently used stay resident.
        #expect(!victims.contains(tabs[99].id))
    }

    @Test func pinnedTabsSuspendedLast() {
        let a = tab(1, pinned: true), b = tab(2), c = tab(3)
        let victims = TabResidencyPolicy.tabsToSuspend(resident: [a, b, c], activeID: c.id, maxResident: 2)
        #expect(victims == [b.id])
    }

    @Test func underCapNothingSuspended() {
        #expect(TabResidencyPolicy.tabsToSuspend(resident: [tab(1)], activeID: nil, maxResident: 6).isEmpty)
    }
}

@Suite struct FilenameTests {
    @Test func stripsPathsAndControlCharacters() {
        #expect(FilenameSanitizer.sanitize("../../etc/passwd") == "passwd")
        #expect(FilenameSanitizer.sanitize("re:port?.pdf") == "report.pdf")
        #expect(FilenameSanitizer.sanitize("...") == "download")
    }

    @Test func removesBidiOverride() {
        #expect(FilenameSanitizer.sanitize("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(FilenameSanitizer.isRisky("invoicefdp.exe"))
    }

    @Test func uniqueDestinationAddsCounter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("a.pdf"))
        #expect(FilenameSanitizer.uniqueDestination(for: "a.pdf", in: dir).lastPathComponent == "a 2.pdf")
    }
}

@Suite struct ReaderTests {
    @Test func decodesAndEstimatesTime() {
        let words = Array(repeating: "word", count: 460).joined(separator: " ")
        let json = #"{"title":"T","byline":null,"paragraphs":["\#(words)"]}"#
        let doc = ReaderScripts.decode(json, sourceURL: nil)
        #expect(doc?.readingMinutes == 2)
        #expect(doc?.isUsable == true)
    }

    @Test func shortContentFallsBack() {
        #expect(ReaderDocument(title: "x", paragraphs: ["too short"]).isUsable == false)
    }
}

@Suite struct SearchEngineTests {
    @Test func engineBuildsSearchURL() {
        guard case .search(let url)? = SearchEngine.duckDuckGo.resolver.resolve("kage browser") else {
            Issue.record("no search"); return
        }
        #expect(url.absoluteString == "https://duckduckgo.com/?q=kage%20browser")
    }
}
