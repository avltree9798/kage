import Foundation
import KageModels
#if canImport(WebKit)
import WebKit

/// Owns live `WKWebView`s. Main-actor only; WebKit objects are never `Sendable` (spec 13.3).
@MainActor public protocol WebViewProviding: AnyObject {
    /// Returns the resident view, or creates one and restores it from saved `interactionState`.
    func webView(for tabID: UUID) -> WKWebView
    /// Saves `interactionState` and a snapshot, then releases the view (AT02).
    func suspend(tabID: UUID)
    /// Upper bound on resident views; older background tabs are suspended first.
    var maxResidentWebViews: Int { get set }
}
#endif

public protocol BrowserTabManaging: Sendable {
    /// `background: true` keeps the current Canvas tab active (AT12, Throw to Context).
    func open(_ url: URL, in groupID: UUID?, background: Bool) async throws -> UUID
    func close(tabID: UUID) async throws
    func activate(tabID: UUID) async throws
    func tabs() async -> [BrowserTab]
}
