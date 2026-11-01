#if canImport(WebKit)
import SwiftUI
import KageModels
import BrowserCore
import DesignSystem

/// Searchable visual tab overview with groups and bulk actions (spec 6.2, 6.3).
struct TabOverviewView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var newGroupName = ""
    @State private var showNewGroup = false
    @State private var confirmCloseAll = false

    var store: BrowserTabStore { env.currentStore }

    var body: some View {
        NavigationStack {
            ScrollView {
                profilePicker.padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(store.search(query), id: \.id) { tab in
                        TabCard(tab: tab, isActive: tab.id == store.activeTabID, isPinned: store.pinned.contains(tab.id))
                            .onTapGesture { Task { await store.activate(tab.id); dismiss() } }
                            .contextMenu { menu(for: tab) }
                    }
                }
                .padding()
                if !store.groups.isEmpty { groupsSection.padding(.horizontal) }
            }
            .searchable(text: $query, prompt: "Search tabs")
            .navigationTitle("\(store.tabs.count) Tabs")
            .kageInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New Tab", systemImage: "plus") { store.open(env.homeURL); dismiss() }
                        Button("New Group", systemImage: "folder.badge.plus") { showNewGroup = true }
                        Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { store.reopenLastClosed() }
                            .disabled(store.recentlyClosed.isEmpty)
                        Divider()
                        Button("Close Other Tabs", systemImage: "xmark.square") { store.closeOtherTabs() }
                        Button("Close All Tabs", systemImage: "xmark", role: .destructive) { confirmCloseAll = true }
                    } label: { Image(systemName: "plus") }
                }
            }
            .alert("New Group", isPresented: $showNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    store.createGroup(name: newGroupName.isEmpty ? "Group" : newGroupName, colour: "indigo",
                                      tabIDs: store.activeTabID.map { [$0] } ?? [])
                    newGroupName = ""
                }
            }
            .confirmationDialog("Close all \(store.tabs.count) tabs?", isPresented: $confirmCloseAll, titleVisibility: .visible) {
                Button("Close All", role: .destructive) { store.closeAll() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 480)
        #endif
    }

    private var profilePicker: some View {
        Picker("Profile", selection: Binding(get: { env.currentKind }, set: { k in Task { await env.switchProfile(to: k) } })) {
            Text("Standard").tag(PrivacyProfile.Kind.standard)
            Text("Ghost").tag(PrivacyProfile.Kind.ghost)
            Text("Vault").tag(PrivacyProfile.Kind.vault)
            Text("Private").tag(PrivacyProfile.Kind.private)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private func menu(for tab: TabController) -> some View {
        Button(store.pinned.contains(tab.id) ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(tab.id) }
        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(tab.id) }
        if !store.groups.isEmpty {
            Menu("Move to Group") {
                Button("No Group") { store.move(tab.id, toGroup: nil) }
                ForEach(store.groups) { g in Button(g.name) { store.move(tab.id, toGroup: g.id) } }
            }
        }
        Button("Add to Research", systemImage: "tray.and.arrow.down") { env.context.addToResearch(tab.id) }
        Button("Close", systemImage: "xmark", role: .destructive) { store.close(tab.id) }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groups").font(.headline)
            ForEach(store.groups) { g in
                let members = store.tabs.filter { store.groupMembership[$0.id] == g.id }
                HStack {
                    Circle().fill(KageTokens.accents[g.colour] ?? .accentColor).frame(width: 10, height: 10)
                    Text(g.name)
                    Text("\(members.count)").foregroundStyle(.secondary)
                    Spacer()
                    ShareLink(items: store.exportGroup(g.id)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export \(g.name) as links")
                    Button(role: .destructive) { store.deleteGroup(g.id, closingTabs: false) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete group \(g.name)")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct TabCard: View {
    let tab: TabController
    let isActive: Bool
    let isPinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let img = tab.snapshotImage {
                    #if os(iOS)
                    Image(uiImage: img).resizable().scaledToFill()
                    #else
                    Image(nsImage: img).resizable().scaledToFill()
                    #endif
                } else {
                    Image(systemName: tab.isResident ? "globe" : "moon.zzz").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 4) {
                if isPinned { Image(systemName: "pin.fill").font(.caption2) }
                Text(tab.title.isEmpty ? (tab.url?.kageHost ?? "New Tab") : tab.title).font(.footnote).lineLimit(1)
            }
            Text(tab.url?.kageHost ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title), \(tab.url?.kageHost ?? "")\(isActive ? ", current tab" : "")\(tab.isResident ? "" : ", suspended")")
        .accessibilityAddTraits(.isButton)
    }
}
#endif
