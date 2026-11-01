#if canImport(WebKit)
import SwiftUI
import KageModels
import Persistence
import BrowserCore
import UniformTypeIdentifiers

/// History, bookmarks, reading list, downloads and notes (spec 6.4, 6.5, 6.7).
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .history

    enum Section: String, CaseIterable, Identifiable { case history, bookmarks, readingList, downloads, notes; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                Text("History").tag(Section.history)
                Text("Bookmarks").tag(Section.bookmarks)
                Text("Reading").tag(Section.readingList)
                Text("Downloads").tag(Section.downloads)
                Text("Notes").tag(Section.notes)
            }
            .pickerStyle(.segmented).padding()
            switch section {
            case .history: HistoryList()
            case .bookmarks: BookmarkList(readingList: false)
            case .readingList: BookmarkList(readingList: true)
            case .downloads: DownloadsList()
            case .notes: NotesList()
            }
        }
        .navigationTitle("Library")
        .kageInlineTitle()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct HistoryList: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var domain: String?
    @State private var visits: [HistoryVisit] = []

    var body: some View {
        List {
            if let domain {
                Button("Showing \(domain) only. Show all") { self.domain = nil }
            }
            ForEach(visits) { v in
                Button { env.currentStore.openInput(v.url.absoluteString); dismiss() } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(v.title.isEmpty ? v.url.absoluteString : v.title).lineLimit(1)
                            if v.isProtected { Image(systemName: "checkmark.shield").accessibilityLabel("Protected") }
                        }
                        HStack {
                            Text(v.url.kageHost)
                            Text(v.lastVisitedAt, style: .relative)
                            if let e = v.expiresAt { Text("· expires \(e, style: .relative)") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Show only \(v.url.kageHost)") { domain = v.url.kageHost }
                    Button("Delete", role: .destructive) { Task { try? await env.currentHistory.delete(ids: [v.id]); await load() } }
                }
            }
            .onDelete { idx in
                let ids = idx.map { visits[$0].id }
                Task { try? await env.currentHistory.delete(ids: ids); await load() }
            }
            Text("This is Kage's own history. Websites and WebKit caches are managed separately in Privacy.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .searchable(text: $query, prompt: "Search history")
        .task(id: "\(query)|\(domain ?? "")") { await load() }
    }

    private func load() async {
        if let domain { visits = (try? await env.currentHistory.visits(host: domain, limit: 500)) ?? [] }
        else if query.isEmpty { visits = (try? await env.currentHistory.visits(host: nil, limit: 500)) ?? [] }
        else { visits = (try? await env.currentHistory.search(query, limit: 200)) ?? [] }
    }
}

struct BookmarkList: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let readingList: Bool
    @State private var items: [Bookmark] = []
    @State private var query = ""
    @State private var importing = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            ForEach(items) { b in
                Button { env.currentStore.openInput(b.url.absoluteString); dismiss() } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(b.title).lineLimit(1)
                            if b.isFavourite { Image(systemName: "star.fill").accessibilityLabel("Favourite") }
                            if b.savedContent != nil { Image(systemName: "arrow.down.circle").accessibilityLabel("Saved offline") }
                        }
                        Text(b.url.kageHost).font(.caption).foregroundStyle(.secondary)
                        if !b.tags.isEmpty { Text(b.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) { Task { try? await env.database.bookmarks.delete(id: b.id); await load() } }
                    Button(b.isFavourite ? "Unfavourite" : "Favourite") {
                        var c = b; c.isFavourite.toggle(); c.modifiedAt = .now
                        Task { try? await env.database.bookmarks.save(c); await load() }
                    }
                }
            }
            if items.isEmpty { Text(readingList ? "Nothing saved to read later." : "No bookmarks yet.").foregroundStyle(.secondary) }
        }
        .searchable(text: $query)
        .toolbar {
            if !readingList {
                ToolbarItem {
                    Menu {
                        Button("Import HTML Bookmarks") { importing = true }
                        if let exportURL { ShareLink("Export Bookmarks", item: exportURL) }
                    } label: { Image(systemName: "square.and.arrow.up.on.square") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.html]) { result in
            guard case .success(let url) = result else { return }
            Task { await importBookmarks(from: url) }
        }
        .task(id: query) { await load() }
    }

    private func load() async {
        items = query.isEmpty
            ? ((try? await env.database.bookmarks.all(folderID: nil, readingList: readingList)) ?? [])
            : ((try? await env.database.bookmarks.search(query)) ?? []).filter { $0.isReadingList == readingList }
        if !readingList { exportURL = try? BookmarkHTML.write(items) }
    }

    private func importBookmarks(from url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        for b in BookmarkHTML.parse(html) { try? await env.database.bookmarks.save(b) }
        await load()
    }
}

struct DownloadsList: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        List {
            ForEach(env.downloads.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.record.filename).lineLimit(1)
                        if item.isRisky { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("This file type can run code") }
                    }
                    Text(item.record.sourceURL.kageHost).font(.caption).foregroundStyle(.secondary)
                    switch item.record.status {
                    case .inProgress: ProgressView(value: item.record.progress ?? 0)
                    case .failed: Text(item.error ?? "Failed").font(.caption).foregroundStyle(.red)
                    default: Text(item.record.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if item.record.status == .inProgress { Button("Cancel") { env.downloads.cancel(item.id) } }
                        if item.record.status == .failed || item.record.status == .cancelled || item.record.status == .paused {
                            Button(item.canResume ? "Resume" : "Retry") { Task { await env.downloads.retry(item.id) } }
                        }
                        if let dest = item.destination, item.record.status == .completed {
                            ShareLink(item: dest) { Label("Share", systemImage: "square.and.arrow.up") }
                            #if os(macOS)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
                            #endif
                        }
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }
            if env.downloads.items.isEmpty { Text("No downloads.").foregroundStyle(.secondary) }
        }
        .toolbar { ToolbarItem { Button("Clear Finished") { env.downloads.clearFinished() } } }
    }
}

struct NotesList: View {
    @Environment(AppEnvironment.self) private var env
    @State private var notes: [ResearchNote] = []
    var body: some View {
        List(notes) { n in
            VStack(alignment: .leading) {
                Text(verbatim: n.text).lineLimit(6).textSelection(.enabled)
                if let s = n.sourceURL { Text(s.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .overlay { if notes.isEmpty { Text("Notes you save from Context appear here.").foregroundStyle(.secondary) } }
        .task { notes = (try? await env.database.aiSessions.notes(sessionID: nil)) ?? [] }
    }
}
#if os(macOS)
import AppKit
#endif
#endif
