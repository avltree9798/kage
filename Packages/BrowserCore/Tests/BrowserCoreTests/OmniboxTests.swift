import Foundation
import Testing
@testable import BrowserCore

@Suite struct OmniboxTests {
    let resolver = OmniboxResolver(searchTemplate: "https://search.test/?q=%s")

    @Test(arguments: ["https://example.com/path", "example.com", "sub.example.co.uk/a?b=1", "localhost:8080"])
    func recognisesURLs(_ input: String) {
        guard case .url = resolver.resolve(input) else {
            Issue.record("expected URL for \(input)"); return
        }
    }

    @Test(arguments: ["swift actors", "what is 2+2", "kage", "Kage   browser"])
    func treatsOtherInputAsSearch(_ input: String) {
        guard case .search = resolver.resolve(input) else {
            Issue.record("expected search for \(input)"); return
        }
    }

    @Test func barePrefixGetsHTTPS() {
        #expect(resolver.resolve("example.com") == .url(URL(string: "https://example.com")!))
    }

    @Test func emptyInputResolvesToNothing() {
        #expect(resolver.resolve("   ") == nil)
    }
}
