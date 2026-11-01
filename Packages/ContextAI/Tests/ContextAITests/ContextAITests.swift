import Foundation
import Testing
@testable import ContextAI

@Suite struct RedactorTests {
    let page = ExtractedContent(sourceURL: URL(string: "https://u:p@site.test/a?token=abc#x")!,
                                title: "t", text: "Mail me at someone@example.com, card 4111 1111 1111 1111.")

    @Test func removesEmailsCardsAndQuery() {
        let out = Redactor().redact(page)
        #expect(!out.text.contains("someone@example.com"))
        #expect(!out.text.contains("4111"))
        #expect(out.sourceURL.absoluteString == "https://site.test/a")
    }

    @Test func truncatesToLimit() {
        let big = ExtractedContent(sourceURL: page.sourceURL, title: "t", text: String(repeating: "a", count: 100))
        #expect(Redactor(maxBytes: 10).redact(big).text.utf8.count == 10)
    }
}

@Suite struct CloudflareRequestTests {
    @Test func requestCarriesNoCookiesAndUsesBearerToken() throws {
        let req = try CloudflareRequestBuilder.runRequest(accountID: "acct", token: "tok",
            modelID: "@cf/meta/llama-3.1-8b-instruct", messages: [("user", "hi")], stream: false)
        #expect(req.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/acct/ai/run/@cf/meta/llama-3.1-8b-instruct")
        #expect(req.httpShouldHandleCookies == false)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Cookie") == nil)
    }

    // AT08: a revoked token maps to a safe, typed error.
    @Test func revokedTokenMapsToInvalidToken() {
        #expect(CloudflareRequestBuilder.mapStatus(401) == .invalidToken)
        #expect(CloudflareRequestBuilder.mapStatus(200) == nil)
    }
}
