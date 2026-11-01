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
