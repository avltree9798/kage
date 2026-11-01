import Foundation
import Testing
import KageModels
@testable import AppShell

@Suite struct NetworkProtectionTests {
    // AT16: with status unknown, the UI never claims verified protection.
    @Test func unknownNeverClaimsProtection() {
        for s in [NetworkProtectionState.notConfigured, .statusUnknown(detail: "warp=on"), .connecting, .disconnected, .restricted("x")] {
            #expect(!s.claimsProtection)
            #expect(s.symbol == "shield.slash")
        }
        #expect(NetworkProtectionState.verifiedConnected.claimsProtection)
    }

    @MainActor @Test func monitorStartsUnconfiguredAndStaysUnknown() {
        let m = NetworkProtectionMonitor()
        #expect(m.state == .notConfigured)
        m.userSaysWARPInstalled = true
        #expect(m.state == .statusUnknown(detail: nil))
        #expect(!m.state.claimsProtection)
    }
}

@Suite struct BookmarkHTMLTests {
    @Test func roundTrip() {
        let b = [Bookmark(url: URL(string: "https://a.test/?x=1&y=2")!, title: "A & B <c>", tags: ["t"])]
        let parsed = BookmarkHTML.parse(BookmarkHTML.render(b))
        #expect(parsed.count == 1)
        #expect(parsed[0].url == b[0].url)
        #expect(parsed[0].title == "A & B <c>")
    }

    @Test func ignoresNonWebLinks() {
        let html = #"<DT><A HREF="javascript:alert(1)">x</A><DT><A HREF="https://ok.test">ok</A>"#
        #expect(BookmarkHTML.parse(html).map(\.title) == ["ok"])
    }
}

@MainActor @Suite struct SettingsTests {
    @Test func defaultsArePrivate() {
        let d = UserDefaults(suiteName: "kage.tests.\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(s.smartPreSummary == false)          // spec 8.4: default off
        #expect(s.searchSuggestions == false)        // spec 6.1: optional
        #expect(s.lockMode == .none)
        #expect(s.retentionOverride == nil)
        s.retentionMinutes = 0
        #expect(s.retentionOverride == .onTabClose)
        #expect(AppSettings(defaults: d).retentionMinutes == 0)
    }
}
