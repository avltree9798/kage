#if canImport(WebKit)
import Foundation
import Testing
import WebKit
import KageModels
import Persistence
@testable import PrivacyKit

/// K-19, automated half: real `WKWebsiteDataStore` cookies through the real cleanup path. A protected
/// site's login cookie survives routine cleanup and Forget Now (unprotected); everything else goes.
/// The manual half (signing in to real sites on a device) is in Docs/Architecture/AcceptanceTests.md.
@MainActor @Suite(.serialized) struct WebKitCookieIntegrationTests {
    private func cookie(_ name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: "1", .domain: domain, .path: "/", .secure: "TRUE",
            .expires: Date().addingTimeInterval(86_400),
        ])!
    }

    private func names(in store: WKWebsiteDataStore) async -> Set<String> {
        Set(await store.httpCookieStore.allCookies().map { "\($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))):\($0.name)" })
    }

    private func run(_ scope: CleanupScope) async throws -> Set<String> {
        let id = UUID()
        let store = WKWebsiteDataStore(forIdentifier: id)
        defer { Task { @MainActor in try? await WKWebsiteDataStore.remove(forIdentifier: id) } }
        for c in [cookie("session", domain: "bank.example"), cookie("sso", domain: ".login.bank.example"),
                  cookie("uid", domain: "tracker.example"), cookie("pref", domain: "news.example")] {
            await store.httpCookieStore.setCookie(c)
        }
        #expect(await names(in: store).count == 4)
        let db = try KageDatabase.inMemory()
        let service = WebsiteDataCleanupService(history: db.history, aiSessions: db.aiSessions,
                                                webKit: WebKitDataStoreAdapter(storeIdentifiers: [id]))
        let (_, report) = await service.clean(scope: scope, protectedSites: [ProtectedSite(domain: "bank.example")])
        #expect(report.failures.isEmpty)
        return await names(in: store)
    }

    @Test func routineCleanupKeepsProtectedLogin() async throws {
        let left = try await run(.routine)
        #expect(left.contains("bank.example:session"))
        #expect(left.contains("login.bank.example:sso"))
        #expect(!left.contains("tracker.example:uid"))
        #expect(!left.contains("news.example:pref"))
    }

    @Test func forgetUnprotectedKeepsProtectedLogin() async throws {
        let left = try await run(.forgetUnprotected)
        #expect(left == ["bank.example:session", "login.bank.example:sso"])
    }

    @Test func forgetEverythingRemovesProtectedLoginToo() async throws {
        let left = try await run(.everything)
        #expect(left.isEmpty)
    }
}
#endif
