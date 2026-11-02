#if canImport(WebKit)
import SwiftUI
import KageModels
import BrowserCore

/// Local Reader Mode with themes, adjustable type and reading time (spec 6.6).
struct ReaderView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let tab: TabController
    @State private var doc: ReaderDocument?
    @State private var loading = true

    var body: some View {
        @Bindable var settings = env.settings
        NavigationStack {
            Group {
                if loading { ProgressView() }
                else if let doc, doc.isUsable { article(doc) }
                else {
                    ContentUnavailableView("Reader isn't available", systemImage: "doc.plaintext",
                                           description: Text("Kage couldn't find an article on this page. The original page is unchanged."))
                }
            }
            .background(background)
            .navigationTitle(doc?.title ?? "Reader")
            .kageInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Theme", selection: $settings.readerTheme) {
                            ForEach(ReaderTheme.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Button("Larger Text") { settings.readerFontSize = min(32, settings.readerFontSize + 2) }
                        Button("Smaller Text") { settings.readerFontSize = max(13, settings.readerFontSize - 2) }
                        if let doc {
                            Divider()
                            Button("Summarise in Context") { env.context.summarise(tabID: tab.id); env.isContextVisible = true; dismiss() }
                            Button("Save for Offline Reading") {
                                Task {
                                    if let url = doc.sourceURL {
                                        try? await env.database.bookmarks.save(Bookmark(url: url, title: doc.title, isReadingList: true,
                                                                                        savedContent: doc.text))
                                    }
                                }
                            }
                        }
                    } label: { Image(systemName: "textformat") }
                }
            }
        }
        .task {
            doc = await tab.readerDocument()
            loading = false
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 600)
        #endif
    }

    private func article(_ doc: ReaderDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(doc.title).font(.system(size: env.settings.readerFontSize * 1.5, weight: .bold, design: .serif))
                HStack {
                    if let by = doc.byline { Text(by) }
                    Text("\(doc.readingMinutes) min read")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(doc.paragraphs.enumerated()), id: \.offset) { _, p in
                    Text(verbatim: p).font(.system(size: env.settings.readerFontSize, design: .serif)).lineSpacing(5)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(foreground)
    }

    private var background: Color {
        switch env.settings.readerTheme {
        case .light: Color(white: 0.99)
        case .dark: Color(white: 0.1)
        case .sepia: Color(red: 0.96, green: 0.92, blue: 0.84)
        }
    }

    private var foreground: Color {
        switch env.settings.readerTheme {
        case .light: Color(white: 0.1)
        case .dark: Color(white: 0.9)
        case .sepia: Color(red: 0.25, green: 0.18, blue: 0.1)
        }
    }
}

/// Site identity, permissions and protection controls for the current page (spec 6.8, 9.3, 15.2).
struct SiteInfoView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let tab: TabController
    @State private var decisions: [SitePermission: PermissionDecision] = [:]

    var host: String { tab.host }
    var isProtected: Bool { env.protectedSiteList.contains { $0.matches(host: host) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Site", value: host)
                    LabeledContent("Connection", value: tab.url?.scheme == "https" && tab.hasOnlySecureContent ? "Secure (HTTPS)" : "Not fully secure")
                    LabeledContent("Profile", value: env.currentProfile.name)
                    if tab.blockedPopupCount > 0 { LabeledContent("Pop-ups blocked", value: "\(tab.blockedPopupCount)") }
                }
                Section("Permissions") {
                    ForEach([SitePermission.camera, .microphone, .popups], id: \.self) { p in
                        Picker(p.rawValue.capitalized, selection: Binding(get: { decisions[p] ?? .ask }, set: { d in
                            decisions[p] = d
                            Task { await env.permissions.set(p, host: host, d) }
                        })) {
                            Text("Ask").tag(PermissionDecision.ask)
                            Text("Allow").tag(PermissionDecision.allow)
                            Text("Deny").tag(PermissionDecision.deny)
                        }
                    }
                    Text("Your device's privacy settings still apply.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if isProtected {
                        Button("Stop protecting \(host)", role: .destructive) {
                            Task { if let s = env.protectedSiteList.first(where: { $0.matches(host: host) }) { await env.unprotect(s) } }
                        }
                    } else {
                        Button("Protect login for \(host)") { Task { await env.protect(ProtectedSite(domain: host)) } }
                    }
                } footer: {
                    Text("Protected sites keep cookies, local storage and IndexedDB through cleanup. Some sites may still sign you out.")
                }
                Section {
                    Toggle("Block trackers on this site", isOn: Binding(get: { !env.settings.blockingExceptions.contains(host) }, set: { on in
                        if on { env.settings.blockingExceptions.removeAll { $0 == host } } else { env.settings.blockingExceptions.append(host) }
                        Task { await env.applyBlockingSettings(); tab.reload() }
                    }))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(host)
            .kageInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { decisions = await env.permissions.all(host: host) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}
#endif
