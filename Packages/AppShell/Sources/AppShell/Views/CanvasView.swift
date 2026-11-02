#if canImport(WebKit)
import SwiftUI
import KageModels
import BrowserCore
import SecurityKit
import DesignSystem

/// The browsing workspace: chrome and the active page (spec 5.1).
/// Chrome sits on a distinct surface so page content can't imitate it (spec 15.2).
///
/// `.compact` is the iPhone layout: address field on top, navigation along the bottom.
/// `.toolbar` is one row for wide windows, where the tab sidebar usually holds the address field.
struct CanvasView: View {
    enum Style { case compact, toolbar }

    @Environment(AppEnvironment.self) private var env
    var style: Style = .toolbar
    var showsOmnibox = true
    var showsTabsButton = true
    var showsContextButton = true
    /// Opens the tab sidebar (iPhone) or shows/hides it (wide).
    var onTabs: () -> Void = {}
    /// Defaults to showing or hiding the Context panel.
    var onContext: (() -> Void)?
    @State private var showReader = false
    @State private var showFind = false
    @State private var showSiteInfo = false

    var store: BrowserTabStore { env.currentStore }
    var tab: TabController? { store.activeTab }
    var tint: Color { KageTokens.profileTint(env.currentKind.rawValue) }

    var body: some View {
        VStack(spacing: 0) {
            switch style {
            case .compact: compactTop
            case .toolbar: toolbarRow
            }
            Rectangle().fill(tint).frame(height: 3).accessibilityHidden(true)
            if let tab, tab.isLoading { ProgressView(value: tab.estimatedProgress).progressViewStyle(.linear).frame(height: 2) }
            ZStack {
                WebViewHost(webView: tab?.webView)
                    .accessibilityLabel("Web page")
                if let tab, tab.crashed { CrashRecoveryView(tab: tab) }
                if let tab, let error = tab.lastError, !tab.crashed { ErrorBanner(message: error) { tab.reload() } }
            }
            #if os(macOS)
            if showFind, let tab { FindBar(tab: tab) { showFind = false } }
            #endif
            if style == .compact { bottomBar }
        }
        .sheet(isPresented: $showReader) { if let tab { ReaderView(tab: tab).environment(env) } }
        .sheet(isPresented: $showSiteInfo) { if let tab { SiteInfoView(tab: tab).environment(env) } }
        .onChange(of: tab?.isLoading) { _, loading in
            if loading == false, let t = tab, let url = t.url { env.context.pageDidBecomeReady(tabID: t.id, url: url) }
        }
    }

    // MARK: Chrome

    private var compactTop: some View {
        HStack(spacing: 8) {
            siteIdentity
            OmniboxField()
            reloadButton
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(KageTokens.chromeBackground)
        .zIndex(1)
    }

    private var bottomBar: some View {
        HStack {
            backButton
            Spacer()
            forwardButton
            if showsTabsButton { Spacer(); tabsButton }
            if showsContextButton { Spacer(); contextButton }
            Spacer()
            pageMenu
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(KageTokens.chromeBackground)
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            if showsTabsButton { tabsButton }
            backButton
            forwardButton
            reloadButton
            if showsOmnibox {
                siteIdentity
                OmniboxField()
            } else {
                siteIdentity
                Text(tab?.host ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            pageMenu
            if showsContextButton { contextButton }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(KageTokens.chromeBackground)
        .zIndex(1)
    }

    private var backButton: some View {
        Button { tab?.goBack() } label: { Image(systemName: "chevron.backward") }
            .disabled(!(tab?.canGoBack ?? false)).accessibilityLabel("Back").keyboardShortcut("[", modifiers: .command)
    }

    private var forwardButton: some View {
        Button { tab?.goForward() } label: { Image(systemName: "chevron.forward") }
            .disabled(!(tab?.canGoForward ?? false)).accessibilityLabel("Forward").keyboardShortcut("]", modifiers: .command)
    }

    @ViewBuilder private var reloadButton: some View {
        if tab?.isLoading == true {
            Button { tab?.stop() } label: { Image(systemName: "xmark") }.accessibilityLabel("Stop")
        } else {
            Button { tab?.reload() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Reload").keyboardShortcut("r", modifiers: .command)
        }
    }

    /// On iPhone it opens the sidebar; on wide windows it shows or hides the sidebar column.
    private var tabsButton: some View {
        Button(action: onTabs) {
            if style == .compact {
                Text("\(store.tabs.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(lineWidth: 2))
            } else {
                Image(systemName: "sidebar.left")
            }
        }
        .accessibilityLabel("Tabs, \(store.tabs.count) open")
        .accessibilityHint(style == .compact ? "Shows your tabs" : (env.isSidebarVisible ? "Hides the sidebar" : "Shows the sidebar"))
        .keyboardShortcut("s", modifiers: [.command, .option])
    }

    private var contextButton: some View {
        Button { if let onContext { onContext() } else { env.isContextVisible.toggle() } } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel(style == .compact ? "Context" : (env.isContextVisible ? "Hide Context" : "Show Context"))
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }

    private var siteIdentity: some View {
        Button { showSiteInfo = true } label: {
            Image(systemName: tab?.url?.scheme == "https" && tab?.hasOnlySecureContent == true ? "lock.fill" : "exclamationmark.triangle")
                .foregroundStyle(tab?.url?.scheme == "https" ? Color.secondary : Color.orange)
        }
        .accessibilityLabel(tab?.url?.scheme == "https" ? "Secure connection to \(tab?.host ?? "")" : "Connection is not secure")
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
            Button("Library", systemImage: "books.vertical") { env.destination = .library }
            Button("Privacy", systemImage: "hand.raised") { env.destination = .privacy }
            Button("Settings", systemImage: "gearshape") { env.destination = .settings }
            Button("Lock Kage", systemImage: "lock") { env.lock.lock(trigger: .manual) }
                .disabled(!env.lock.isEnabled).keyboardShortcut("l", modifiers: [.command, .shift])
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden)
        .accessibilityLabel("Page menu")
    }

    private func find() {
        #if os(iOS)
        tab?.webView?.findInteraction?.presentFindNavigator(showingReplace: false)
        #else
        showFind = true
        #endif
    }
}

/// The address and search field, with search suggestions beneath it. Used in the page chrome, or at the
/// top of the sidebar on wide windows; only one is on screen at a time, so Cmd-L has one target.
struct OmniboxField: View {
    @Environment(AppEnvironment.self) private var env
    var showsProfileChip = true
    /// Sidebar styling: a dark field on the graphite sidebar.
    var onSidebar = false
    @State private var text = ""
    @State private var editing = false
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var store: BrowserTabStore { env.currentStore }
    var tab: TabController? { store.activeTab }

    var body: some View {
        HStack(spacing: 4) {
            if showsProfileChip {
                Text(env.currentProfile.name)
                    .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(KageTokens.profileTint(env.currentKind.rawValue).opacity(0.22), in: Capsule())
                    .accessibilityLabel("Profile: \(env.currentProfile.name)")
            }
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                #endif
                .autocorrectionDisabled()
                .onSubmit { submit(text) }
                .accessibilityIdentifier("omnibox")
                .accessibilityLabel("Address and search")
                .background {
                    // Cmd-L focuses the address field (K-30 keyboard path); invisible and not an accessibility element.
                    Button("Open Location") { focused = true }
                        .keyboardShortcut("l", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
                .onChange(of: focused) { _, f in
                    editing = f
                    if !f { text = tab?.url?.absoluteString ?? text }
                }
            if editing && !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(onSidebar ? AnyShapeStyle(KageTokens.sidebarField) : AnyShapeStyle(KageTokens.fieldBackground),
                    in: RoundedRectangle(cornerRadius: KageTokens.cornerRadius))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if editing && !suggestions.isEmpty { suggestionList.offset(y: 40) }
        }
        .onAppear { text = tab?.url?.absoluteString ?? "" }
        .onChange(of: tab?.url) { _, new in if !editing { text = new?.absoluteString ?? "" } }
        .onChange(of: store.activeTabID) { _, _ in if !editing { text = tab?.url?.absoluteString ?? "" } }
        .task(id: text) { await loadSuggestions() }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggestions from \(env.settings.searchEngine.name)").font(.caption).foregroundStyle(.secondary).padding(8)
            ForEach(suggestions, id: \.self) { s in
                Button { text = s; submit(s) } label: {
                    Label(s, systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 240, maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KageTokens.cornerRadius))
    }

    private func submit(_ input: String) {
        store.searchEngine = env.settings.searchEngine
        store.openInput(input)
        focused = false
        suggestions = []
    }

    private func loadSuggestions() async {
        // Suggestions are off unless enabled, and never in Private (spec 6.1).
        guard editing, env.settings.searchSuggestions, env.currentProfile.kind != .private,
              text.count >= 2, !text.contains("/") else { suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        suggestions = await SearchSuggestionClient().suggestions(for: text, engine: env.settings.searchEngine)
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
