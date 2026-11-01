import Foundation
import Testing
@testable import SecurityKit

@Suite struct ContentRuleBuilderTests {
    @Test func offProducesNoRules() {
        #expect(ContentRuleBuilder.rules(mode: .off, trackers: ["a.test"], exceptions: []).isEmpty)
    }

    @Test func standardBlocksThirdPartyOnly() {
        let rules = ContentRuleBuilder.rules(mode: .standard, trackers: ["ads.test"], exceptions: [])
        #expect(rules.count == 1)
        #expect(rules[0].trigger.loadType == ["third-party"])
        #expect(rules[0].trigger.urlFilter == #"^https?://([^/]*\.)?ads\.test[/:]"#)
    }

    @Test func strictAddsCookieBlockingAndExceptionsComeLast() {
        let rules = ContentRuleBuilder.rules(mode: .strict, trackers: ["ads.test"], exceptions: ["shop.test"])
        #expect(rules.map(\.action.type) == ["block", "block-cookies", "ignore-previous-rules"])
        #expect(rules.last?.trigger.ifDomain == ["*shop.test"])
    }

    @Test func encodesValidJSONWithWebKitKeys() throws {
        let json = try ContentRuleBuilder.encode(ContentRuleBuilder.rules(mode: .standard, trackers: ["a.test"], exceptions: []))
        #expect(json.count == 1)
        #expect(json[0].contains("\"url-filter\""))
        #expect(json[0].contains("\"load-type\""))
        _ = try JSONSerialization.jsonObject(with: Data(json[0].utf8))
    }

    @Test func largeListsAreChunkedWithExceptionInEachChunk() throws {
        let trackers = (0..<(ContentRuleBuilder.maxRulesPerList + 10)).map { "t\($0).test" }
        let json = try ContentRuleBuilder.encode(ContentRuleBuilder.rules(mode: .standard, trackers: trackers, exceptions: ["ok.test"]))
        #expect(json.count == 2)
        #expect(json.allSatisfy { $0.contains("ignore-previous-rules") })
    }
}

@Suite struct CleanLinksTests {
    @Test func removesTrackingParameters() {
        let url = URL(string: "https://shop.test/item?id=42&utm_source=x&utm_medium=y&fbclid=abc")!
        #expect(CleanLinks.clean(url).absoluteString == "https://shop.test/item?id=42")
    }

    @Test func keepsFunctionalURLsUntouched() {
        let url = URL(string: "https://search.test/?q=swift&page=2")!
        #expect(CleanLinks.clean(url) == url)
    }

    @Test func dropsQueryEntirelyWhenOnlyTrackers() {
        let url = URL(string: "https://a.test/p?gclid=1")!
        #expect(CleanLinks.clean(url).absoluteString == "https://a.test/p")
    }
}

@Suite struct CredentialStoreTests {
    @Test func inMemoryStoreRoundTrip() async throws {
        let store = InMemoryCredentialStore()
        try await store.save(.init(accountID: "a", apiToken: "t"))
        #expect(try await store.load()?.apiToken == "t")
        try await store.delete()
        #expect(try await store.load() == nil)
    }
}

// K-21: the bundled EasyPrivacy list is real, attributed, and compiles in WebKit.
@Suite struct TrackerListTests {
    @Test func bundledListIsLoadedAndAttributed() throws {
        let list = TrackerList.bundled
        #expect(list.hosts.count > 1000)
        #expect(list.version != nil)
        #expect(list.hosts.allSatisfy(TrackerList.isValidHost))
        #expect(Set(list.hosts).count == list.hosts.count)
        let url = try #require(TrackerList.bundledURL)
        let header = try String(contentsOf: url, encoding: .utf8).prefix(600)
        #expect(header.contains("Creative Commons Attribution-ShareAlike 3.0"))
        #expect(header.contains("easylist.to"))
    }

    @Test func parserRejectsUnsafeHosts() {
        let list = TrackerList.parse("! EasyPrivacy version: 1; x\nok.example\nbad host.example\n.lead.example\nno-dot\n(re|gex).example\n")
        #expect(list.hosts == ["ok.example"])
        #expect(list.version == "1")
    }
}

#if canImport(WebKit)
import WebKit

@MainActor @Suite struct WebKitCompileTests {
    /// Compiles the full bundled ruleset with WebKit's real compiler in every blocking mode.
    @Test(arguments: [BlockingMode.standard, .strict])
    func fullRulesetCompiles(mode: BlockingMode) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kage-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))
        let chunks = try ContentRuleBuilder.encode(
            ContentRuleBuilder.rules(mode: mode, trackers: TrackerList.bundled.hosts, exceptions: ["bank.example"]))
        for (i, chunk) in chunks.enumerated() {
            let list = try await store.compileContentRuleList(forIdentifier: "test-\(mode.rawValue)-\(i)", encodedContentRuleList: chunk)
            #expect(list != nil)
        }
    }
}
#endif
