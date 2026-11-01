#if canImport(WebKit)
import Foundation
import WebKit
import KageModels
import SecurityKit

/// One WebKit data store per profile (spec 9.6, ADR-004, ADR-011).
/// Persistent profiles use `WKWebsiteDataStore(forIdentifier:)` so cookies never cross profiles.
@MainActor public final class ProfileDataStores {
    private var nonPersistent: [UUID: WKWebsiteDataStore] = [:]
    public init() {}

    public func store(for profile: PrivacyProfile) -> WKWebsiteDataStore {
        switch profile.storeStrategy {
        case .persistent(let id): return WKWebsiteDataStore(forIdentifier: id)
        case .nonPersistent:
            if let s = nonPersistent[profile.id] { return s }
            let s = WKWebsiteDataStore.nonPersistent()
            nonPersistent[profile.id] = s
            return s
        }
    }

    /// Ends a private session: the in-memory store is dropped with its last web view (AT06).
    public func discardNonPersistent(profileID: UUID) { nonPersistent[profileID] = nil }
    public var activeNonPersistentStores: [WKWebsiteDataStore] { Array(nonPersistent.values) }
}

/// The content world Kage's own scripts run in, invisible to page JavaScript (spec 15.2).
@MainActor public enum KageContentWorld {
    public static let world = WKContentWorld.world(name: "dev.kage.native")
}

@MainActor public final class WebViewFactory {
    public let dataStores: ProfileDataStores
    public let contentBlocking: ContentBlockingManager
    private let processPool = WKProcessPool()

    public init(dataStores: ProfileDataStores = ProfileDataStores(), contentBlocking: ContentBlockingManager) {
        self.dataStores = dataStores; self.contentBlocking = contentBlocking
    }

    public func configuration(for profile: PrivacyProfile, desktopMode: Bool = false) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStores.store(for: profile)
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.defaultWebpagePreferences.preferredContentMode = desktopMode ? .desktop : .recommended
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.upgradeKnownHostsToHTTPS = true
        cfg.applicationNameForUserAgent = "Version/27.2 Safari/605.1.15"
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        cfg.dataDetectorTypes = [.phoneNumber, .link]
        #endif
        contentBlocking.apply(to: cfg.userContentController)
        return cfg
    }

    public func makeWebView(for profile: PrivacyProfile, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let cfg = configuration ?? self.configuration(for: profile)
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true
        #if os(iOS)
        wv.isFindInteractionEnabled = true
        wv.scrollView.keyboardDismissMode = .interactive
        #endif
        #if DEBUG
        wv.isInspectable = true
        #endif
        return wv
    }
}
#endif
