import Testing
@testable import SecurityKit

@Test func credentialDescriptionRedactsToken() {
    let c = CloudflareCredential(accountID: "acct", apiToken: "secret-token")
    #expect(!String(describing: c).contains("secret-token"))
    #expect(!String(reflecting: c).contains("secret-token"))
}
