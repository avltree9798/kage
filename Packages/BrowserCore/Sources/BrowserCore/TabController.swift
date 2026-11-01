#if canImport(WebKit)
import Foundation
import Observation
import WebKit
import KageModels

/// Hooks the UI layer provides for prompts that need a person (JS dialogs, external apps, permissions).
@MainActor public protocol BrowserPromptPresenting: AnyObject {
    func confirmOpenExternally(_ url: URL) async -> Bool
    func alert(message: String, from host: String) async
    func confirm(message: String, from host: String) async -> Bool
    func prompt(message: String, defaultText: String?, from host: String) async -> String?
    func mediaPermission(for host: String, camera: Bool, microphone: Bool) async -> PermissionDecision
    #if os(macOS)
    func openPanel(allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]?
    #endif
}

/// Live state for one tab. Owns its `WKWebView` only while resident (spec 13.3: never Sendable).
@MainActor @Observable
public final class TabController: NSObject {
    public let id: UUID
    public private(set) var profile: PrivacyProfile
    public var title: String
    public private(set) var url: URL?
    public private(set) var estimatedProgress: Double = 0
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var hasOnlySecureContent = true
    public private(set) var lastError: String?
    /// Set when the web content process died; the UI offers reload (AT14, spec 6.2).
    public private(set) var crashed = false
    public private(set) var blockedPopupCount = 0
    public var desktopMode = false
    public var pageZoom: Double = 1

    @ObservationIgnored public private(set) var webView: WKWebView?
    @ObservationIgnored var savedInteractionState: Data?
    @ObservationIgnored var snapshot: PlatformImage?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored weak var store: BrowserTabStore?
    @ObservationIgnored weak var presenter: BrowserPromptPresenting?

    init(tab: BrowserTab, profile: PrivacyProfile) {
        id = tab.id; self.profile = profile; title = tab.title; url = tab.url
        savedInteractionState = tab.interactionState
    }

    public var isResident: Bool { webView != nil }
    public var host: String { url?.kageHost ?? "" }

    // MARK: Residency

    func attach(_ wv: WKWebView) {
        webView = wv
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.pageZoom = pageZoom
        observations = [
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = wv.estimatedProgress }
            },
            wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { if let t = wv.title, !t.isEmpty { self?.title = t } }
            },
            wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { if let u = wv.url { self?.url = u } }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
            wv.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = wv.hasOnlySecureContent }
            },
        ]
        if let state = savedInteractionState {
            wv.interactionState = state
            savedInteractionState = nil
        } else if let url {
            wv.load(URLRequest(url: url))
        }
    }

    /// Saves back/forward state and a snapshot, then releases the WebView (AT02).
    /// Unsaved form data is not preserved (spec 6.2).
    func detach() async {
        guard let wv = webView else { return }
        savedInteractionState = wv.interactionState as? Data
        if profile.kind != .private && profile.kind != .ghost {
            snapshot = try? await wv.takeSnapshot(configuration: nil)
        }
        observations.removeAll()
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        webView = nil
    }

    /// Lock purge (threat model T-11): releases the WebView at once, with no snapshot, and drops any
    /// snapshot already taken. With `keepState: false` the back/forward archive goes too.
    func purge(keepState: Bool) {
        if let wv = webView {
            if keepState { savedInteractionState = wv.interactionState as? Data }
            observations.removeAll()
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            webView = nil
        }
        if !keepState { savedInteractionState = nil }
        snapshot = nil
    }

    public var snapshotImage: PlatformImage? { snapshot }

    func persistentState() -> Data? {
        guard profile.persistsTabs else { return nil }
        return (webView?.interactionState as? Data) ?? savedInteractionState
    }

    // MARK: Navigation

    public func load(_ url: URL) {
        self.url = url
        crashed = false
        lastError = nil
        webView?.load(URLRequest(url: url))
    }

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }
    public func stop() { webView?.stopLoading() }

    /// After a crash, reload the last URL (spec 6.2, AT14).
    public func reload() {
        crashed = false
        lastError = nil
        if let wv = webView, wv.url != nil { wv.reload() } else if let url { webView?.load(URLRequest(url: url)) }
    }

    public func setZoom(_ zoom: Double) {
        pageZoom = min(3, max(0.5, zoom))
        webView?.pageZoom = pageZoom
    }

    public func toggleDesktopMode() {
        desktopMode.toggle()
        if let wv = webView {
            wv.customUserAgent = nil
            wv.reload()
        }
    }

    // MARK: Native scripts (Kage content world only)

    public func readerDocument() async -> ReaderDocument? {
        guard let wv = webView,
              let json = try? await wv.callAsyncJavaScript(ReaderScripts.extract, arguments: [:], in: nil,
                                                           contentWorld: KageContentWorld.world) as? String
        else { return nil }
        return ReaderScripts.decode(json, sourceURL: url)
    }

    public struct PageText: Sendable { public var title: String; public var selection: String; public var text: String }

    public func pageText(maxChars: Int) async -> PageText? {
        guard let wv = webView,
              let json = try? await wv.callAsyncJavaScript(ReaderScripts.pageText, arguments: ["maxChars": maxChars], in: nil,
                                                           contentWorld: KageContentWorld.world) as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        else { return nil }
        return PageText(title: obj["title"] ?? "", selection: obj["selection"] ?? "", text: obj["text"] ?? "")
    }

    public func printPDF() async -> Data? { try? await webView?.pdf() }
}

// MARK: - WKNavigationDelegate

extension TabController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = desktopMode ? .desktop : .recommended
        guard let target = navigationAction.request.url else { return (.cancel, preferences) }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let userInitiated = navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted
        switch NavigationPolicy.decide(target, isMainFrame: isMain, userInitiated: userInitiated) {
        case .allow:
            return (.allow, preferences)
        case .askToOpenExternally(let ext):
            if await presenter?.confirmOpenExternally(ext) == true { store?.openExternally(ext) }
            return (.cancel, preferences)
        case .block(let reason):
            if isMain { lastError = reason }
            return (.cancel, preferences)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        crashed = false
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url { url = u }
        if let t = webView.title, !t.isEmpty { title = t }
        store?.didFinishNavigation(in: self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // frame load interrupted by download/policy
        lastError = NavigationErrorText.message(for: ns)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashed = true
        isLoading = false
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        store?.downloads.track(download)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store?.downloads.track(download)
    }
}

// MARK: - WKUIDelegate

extension TabController: WKUIDelegate {
    /// Popups open as new tabs only for user-initiated requests (spec 6.1).
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .other,
              let store else { blockedPopupCount += 1; return nil }
        if navigationAction.navigationType == .other && !(navigationAction.sourceFrame.isMainFrame) {
            blockedPopupCount += 1
            return nil
        }
        return store.openPopup(configuration: configuration, from: self, request: navigationAction.request)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        store?.close(id)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        await presenter?.alert(message: message, from: frame.securityOrigin.host)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presenter?.confirm(message: message, from: frame.securityOrigin.host) ?? false
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await presenter?.prompt(message: prompt, defaultText: defaultText, from: frame.securityOrigin.host)
    }

    /// Camera and microphone per site (spec 6.8). Stored decisions apply; otherwise ask.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host
        let camera = type == .camera || type == .cameraAndMicrophone
        let mic = type == .microphone || type == .cameraAndMicrophone
        if let stored = await store?.permissions.decision(host: host, camera: camera, microphone: mic), stored != .ask {
            return stored == .allow ? .grant : .deny
        }
        let decision = await presenter?.mediaPermission(for: host, camera: camera, microphone: mic) ?? .deny
        return decision == .allow ? .grant : .deny
    }

    #if os(macOS)
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await presenter?.openPanel(allowsMultiple: parameters.allowsMultipleSelection,
                                   allowsDirectories: parameters.allowsDirectories)
    }
    #endif
}

public enum NavigationErrorText {
    public static func message(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorNotConnectedToInternet: return "You're offline."
        case NSURLErrorTimedOut: return "The site took too long to respond."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Kage couldn't find that site."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return "This site's security certificate isn't valid, so Kage didn't load it."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "This site doesn't support a secure connection."
        default: return error.localizedDescription
        }
    }
}

#if os(iOS)
import UIKit
public typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformImage = NSImage
#endif
#endif
