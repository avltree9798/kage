#if canImport(WebKit)
import SwiftUI
import KageModels
import ContextAI
import DesignSystem

/// The Context workspace: summary, Q&A, selection tools, research and notes (spec 5.2, 8.3).
/// Dismissing it never touches the active page.
struct ContextPanel: View {
    @Environment(AppEnvironment.self) private var env
    @State private var question = ""
    @State private var selectionText = ""
    @State private var pendingAction: ProposedAction?
    @State private var showAISetup = false

    var context: ContextCoordinator { env.context }
    var activeID: UUID? { env.currentStore.activeTab?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if env.aiStatus == .notConfigured {
                notConfigured
            } else {
                transcript
                if let t = context.transmission { transmissionBar(t) }
                composer
            }
        }
        .background(KageTokens.panelBackground)
        .alert("Send this page to Cloudflare?", isPresented: Binding(get: { context.consentRequest != nil }, set: { if !$0 { context.resolveConsent(false) } })) {
            Button("Don't Send", role: .cancel) { context.resolveConsent(false) }
            Button("Send") { context.resolveConsent(true) }
        } message: {
            Text("\(context.consentRequest?.reason ?? "") Its content from \(context.consentRequest?.host ?? "") will go to your Cloudflare account.")
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button("Do it") { perform(pendingAction); pendingAction = nil }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text("The assistant suggested this. Kage only does it if you confirm.") }
    }

    private var header: some View {
        HStack {
            Text("Context").font(.headline)
            Spacer()
            if context.isWorking { Button("Stop") { context.cancel() }.buttonStyle(.borderless) }
            Menu {
                if let id = activeID {
                    Button("Quick summary") { context.summarise(tabID: id, style: .quick) }
                    Button("Detailed summary") { context.summarise(tabID: id, style: .detailed) }
                    Button("Technical summary") { context.summarise(tabID: id, style: .technical) }
                    Button("Extract facts and dates") { context.extractFacts(tabID: id) }
                }
                if context.researchTabIDs.count >= 2 {
                    Button("Compare research tabs") { context.compare(tabIDs: context.researchTabIDs) }
                }
                Divider()
                Button("Clear conversation", role: .destructive) { context.clear() }
            } label: { Image(systemName: "wand.and.stars") }
            .menuIndicator(.hidden)
            .disabled(env.aiStatus == .notConfigured)
            .accessibilityLabel("Context actions")
        }
        .padding(12)
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context AI is optional").font(.title3.weight(.semibold))
            Text("Connect your own Cloudflare account to summarise and ask about pages. Nothing is sent until you ask, and browsing works without it.")
                .foregroundStyle(.secondary)
            Button("Set up Cloudflare Workers AI") { showAISetup = true }
                .sheet(isPresented: $showAISetup) { NavigationStack { AIAccountView() }.environment(env) }
            researchList
            Spacer()
        }
        .padding(16)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    researchList
                    if context.messages.isEmpty {
                        Text("Ask about this page, or choose a summary from the wand menu.").foregroundStyle(.secondary)
                    }
                    ForEach(context.messages) { m in bubble(m).id(m.id) }
                }
                .padding(12)
            }
            .onChange(of: context.messages.last?.text) { _, _ in
                if let id = context.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var researchList: some View {
        if !context.researchTabIDs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Research").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(context.researchTabIDs, id: \.self) { id in
                    let tab = env.currentStore.tabs.first { $0.id == id }
                    HStack {
                        Text(tab?.title ?? "Tab").lineLimit(1)
                        Spacer()
                        Button { context.removeFromResearch(id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove from research")
                    }
                    .font(.footnote)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private func bubble(_ m: ContextMessage) -> some View {
        switch m.role {
        case .user:
            Text(m.text).font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .trailing)
        case .notice:
            Label(m.text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                // Plain text only: model output is untrusted and never rendered as HTML (spec 13.5 step 7).
                Text(verbatim: m.text.isEmpty ? "…" : m.text).textSelection(.enabled)
                if !m.sources.isEmpty {
                    ForEach(m.sources, id: \.self) { s in
                        Text(s.kageHost).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(m.proposedActions.enumerated()), id: \.offset) { _, a in
                    Button { pendingAction = a } label: { Label(label(for: a), systemImage: "hand.point.up.left") }
                        .buttonStyle(.bordered).font(.footnote)
                }
                HStack {
                    Button("Copy") { Clipboard.copy(m.text) }
                    Button("Save as note") { Task { await context.saveNote(m.text, source: m.sources.first) } }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func transmissionBar(_ t: TransmissionNotice) -> some View {
        Label("Sending \(ByteCountFormatter.string(fromByteCount: Int64(t.bytes), countStyle: .file)) from \(t.hosts.isEmpty ? "your selection" : t.hosts.joined(separator: ", ")) to Cloudflare (\(t.modelName))",
              systemImage: "arrow.up.circle")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack {
                Menu("Selection") {
                    ForEach(SelectionAction.allCases, id: \.self) { a in
                        Button(a.rawValue.capitalized) { Task { await runSelection(a) } }
                    }
                }
                .fixedSize()
                Spacer()
            }
            HStack {
                TextField("Ask about this page", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || context.isWorking)
                    .accessibilityLabel("Send question")
            }
        }
        .padding(12)
    }

    private func send() {
        context.ask(question, tabID: activeID)
        question = ""
    }

    private func runSelection(_ a: SelectionAction) async {
        guard let tab = env.currentStore.activeTab, let text = await tab.pageText(maxChars: 4000)?.selection, !text.isEmpty else {
            return
        }
        context.selection(a, text: text, tabID: tab.id)
    }

    private var confirmTitle: String { pendingAction.map(label(for:)) ?? "" }

    private func label(for a: ProposedAction) -> String {
        switch a {
        case .openInBackgroundTab(let u): "Open \(u.kageHost) in a background tab"
        case .saveNote: "Save suggested note"
        case .compareTabs(let ids): "Compare \(ids.count) tabs"
        }
    }

    private func perform(_ a: ProposedAction?) {
        switch a {
        case .openInBackgroundTab(let url): Task { await env.throwToContext(url, target: .backgroundTab) }
        case .saveNote(let text): Task { await context.saveNote(text, source: nil) }
        case .compareTabs(let ids): context.compare(tabIDs: ids)
        case nil: break
        }
    }
}
#endif
