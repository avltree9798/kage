#if canImport(WebKit)
import SwiftUI
import KageModels
import BrowserCore
import SecurityKit
import DesignSystem

/// The browsing workspace: chrome, omnibox and the active page (spec 5.1).
/// Chrome sits on a distinct surface so page content can't imitate it (spec 15.2).
struct CanvasView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var omniboxText = ""
    @State private var editing = false
    @State private var suggestions: [String] = []
    @State private var showTabs = false
    @State private var showReader = false
    @State private var showFind = false
    @State private var showSiteInfo = false
    @FocusState private var omniboxFocused: Bool

    var store: BrowserTabStore { env.currentStore }
    var tab: TabController? { store.activeTab }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            if let tab, tab.isLoading { ProgressView(value: tab.estimatedProgress).progressViewStyle(.linear).frame(height: 2) }
            ZStack {
                WebViewHost(webView: tab?.webView)
                    .accessibilityLabel("Web page")
                if let tab, tab.crashed { CrashRecoveryView(tab: tab) }
                if let tab, let error = tab.lastError, !tab.crashed { ErrorBanner(message: error) { tab.reload() } }
                if editing && !suggestions.isEmpty { suggestionList }
            }
            #if os(macOS)
            if showFind, let tab { FindBar(tab: tab) { showFind = false } }
            #endif
        }
        .sheet(isPresented: $showTabs) { TabOverviewView().environment(env) }
        .sheet(isPresented: $showReader) { if let tab { ReaderView(tab: tab).environment(env) } }
        .sheet(isPresented: $showSiteInfo) { if let tab { SiteInfoView(tab: tab).environment(env) } }
        .onChange(of: tab?.url) { _, new in if !editing { omniboxText = new?.absoluteString ?? "" } }
        .onChange(of: tab?.isLoading) { _, loading in
            if loading == false, let t = tab, let url = t.url { env.context.pageDidBecomeReady(tabID: t.id, url: url) }
        }
        .task(id: omniboxText) { await loadSuggestions() }
    }

    // MARK: Chrome

    private var chrome: some View {
        HStack(spacing: 8) {
            Button { tab?.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!(tab?.canGoBack ?? false)).accessibilityLabel("Back").keyboardShortcut("[", modifiers: .command)
            Button { tab?.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!(tab?.canGoForward ?? false)).accessibilityLabel("Forward").keyboardShortcut("]", modifiers: .command)
            siteIdentity
            omnibox
            if tab?.isLoading == true {
                Button { tab?.stop() } label: { Image(systemName: "xmark") }.accessibilityLabel("Stop")
            } else {
                Button { tab?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload").keyboardShortcut("r", modifiers: .command)
            }
            Button { showTabs = true } label: {
                Image(systemName: "square.on.square").overlay(alignment: .topTrailing) {
                    Text("\(store.tabs.count)").font(.caption2.monospacedDigit()).padding(2)
                }
            }
            .accessibilityLabel("Tabs, \(store.tabs.count) open")
            pageMenu
            Button { env.isContextVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .accessibilityLabel(env.isContextVisible ? "Hide Context" : "Show Context")
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(KageTokens.chromeBackground)
    }

    private var siteIdentity: some View {
        Button { showSiteInfo = true } label: {
            Image(systemName: tab?.url?.scheme == "https" && tab?.hasOnlySecureContent == true ? "lock.fill" : "exclamationmark.triangle")
                .foregroundStyle(tab?.url?.scheme == "https" ? Color.secondary : Color.orange)
        }
        .accessibilityLabel(tab?.url?.scheme == "https" ? "Secure connection to \(tab?.host ?? "")" : "Connection is not secure")
    }

    private var omnibox: some View {
        HStack(spacing: 4) {
            Text(env.currentProfile.name)
                .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(KageTokens.profileTint(env.currentProfile.kind.rawValue).opacity(0.18), in: Capsule())
                .accessibilityLabel("Profile: \(env.currentProfile.name)")
            TextField("Search or enter address", text: $omniboxText)
                .textFieldStyle(.plain)
                .focused($omniboxFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                #endif
                .autocorrectionDisabled()
                .onSubmit { submit(omniboxText) }
                .onChange(of: omniboxFocused) { _, f in
                    editing = f
                    if !f { omniboxText = tab?.url?.absoluteString ?? omniboxText }
                }
            if editing && !omniboxText.isEmpty {
                Button { omniboxText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(KageTokens.fieldBackground, in: RoundedRectangle(cornerRadius: KageTokens.cornerRadius))
        .frame(maxWidth: .infinity)
    }

    private var pageMenu: some View {
        Menu {
            Button("New Tab", systemImage: "plus") { store.open(env.homeURL) }.keyboardShortcut("t", modifiers: .command)
            Button("New Private Tab", systemImage: "eye.slash") { Task { await env.openNewPrivateWindow() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            if let tab, let url = tab.url {
                Button("Reader", systemImage: "doc.plaintext") { showReader = true }
                Button("Find in Page", systemImage: "magnifyingglass") { find() }.keyboardShortcut("f", modifiers: .command)
                Button(tab.desktopMode ? "Request Mobile Site" : "Request Desktop Site", systemImage: "desktopcomputer") { tab.toggleDesktopMode() }
                Menu("Zoom", systemImage: "textformat.size") {
                    Button("Zoom In") { tab.setZoom(tab.pageZoom + 0.1) }.keyboardShortcut("+", modifiers: .command)
                    Button("Zoom Out") { tab.setZoom(tab.pageZoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                    Button("Actual Size") { tab.setZoom(1) }.keyboardShortcut("0", modifiers: .command)
                }
                Divider()
                Button("Copy Link", systemImage: "link") { Clipboard.copy(url.absoluteString) }
                Button("Copy Clean Link", systemImage: "link.badge.plus") { Clipboard.copy(CleanLinks.clean(url).absoluteString) }
                ShareLink(item: CleanLinks.clean(url)) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Add Bookmark", systemImage: "bookmark") { Task { await env.throwToContext(url, target: .bookmark, title: tab.title) } }
                Button("Add to Reading List", systemImage: "eyeglasses") { Task { await env.throwToContext(url, target: .readingList, title: tab.title) } }
                Button("Duplicate Tab", systemImage: "plus.square.on.square") { store.duplicate(tab.id) }
                Button(store.pinned.contains(tab.id) ? "Unpin Tab" : "Pin Tab", systemImage: "pin") { store.togglePin(tab.id) }
                Divider()
                Button("Summarise in Context", systemImage: "text.redaction") { env.isContextVisible = true; env.context.summarise(tabID: tab.id) }
                Button("Add to Research", systemImage: "tray.and.arrow.down") { env.context.addToResearch(tab.id); env.isContextVisible = true }
            }
            Divider()
            Button("Lock Kage", systemImage: "lock") { env.lock.lock(trigger: .manual) }
                .disabled(!env.lock.isEnabled).keyboardShortcut("l", modifiers: [.command, .shift])
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden)
        .accessibilityLabel("Page menu")
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggestions from \(env.settings.searchEngine.name)").font(.caption).foregroundStyle(.secondary).padding(8)
            ForEach(suggestions, id: \.self) { s in
                Button { omniboxText = s; submit(s) } label: {
                    Label(s, systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KageTokens.cornerRadius))
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func submit(_ text: String) {
        store.searchEngine = env.settings.searchEngine
        store.openInput(text)
        omniboxFocused = false
        suggestions = []
    }

    private func find() {
        #if os(iOS)
        tab?.webView?.findInteraction?.presentFindNavigator(showingReplace: false)
        #else
        showFind = true
        #endif
    }

    private func loadSuggestions() async {
        // Suggestions are off unless enabled, and never in Private (spec 6.1).
        guard editing, env.settings.searchSuggestions, env.currentProfile.kind != .private,
              omniboxText.count >= 2, !omniboxText.contains("/") else { suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        suggestions = await SearchSuggestionClient().suggestions(for: omniboxText, engine: env.settings.searchEngine)
    }
}

struct CrashRecoveryView: View {
    let tab: TabController
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.circlepath").font(.largeTitle)
            Text("This page stopped working").font(.headline)
            Text("Anything you hadn't submitted on the page may be lost.").font(.subheadline).foregroundStyle(.secondary)
            Button("Reload Page") { tab.reload() }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center)
            Button("Try Again", action: retry).buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#if os(macOS)
struct FindBar: View {
    let tab: TabController
    let close: () -> Void
    @State private var query = ""
    @State private var notFound = false
    var body: some View {
        HStack {
            TextField("Find in page", text: $query).textFieldStyle(.roundedBorder).onSubmit { find(backwards: false) }
            Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match")
            Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match")
            if notFound { Text("Not found").foregroundStyle(.secondary) }
            Button("Done", action: close).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(8).background(KageTokens.chromeBackground)
    }
    private func find(backwards: Bool) {
        guard let wv = tab.webView, !query.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.wraps = true
        wv.find(query, configuration: cfg) { result in notFound = !result.matchFound }
    }
}
import WebKit
#endif
#endif
