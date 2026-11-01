import Foundation
import Observation
import KageModels
import Persistence
import PrivacyKit

/// What the native shell must supply: page content from an authorised tab via supported APIs (spec 7.2).
@MainActor public protocol PageContentProviding: AnyObject {
    func extractedContent(tabID: UUID, maxBytes: Int) async -> ExtractedContent?
    func profileID(for tabID: UUID) -> UUID
}

public struct ContextMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable { case user, assistant, notice }
    public var id = UUID()
    public var role: Role
    public var text: String
    public var proposedActions: [ProposedAction] = []
    public var sources: [URL] = []
}

/// Shown while content is on its way to Cloudflare (spec 8.2, 15.2: visible data-transmission indicators).
public struct TransmissionNotice: Sendable, Equatable {
    public var hosts: [String]
    public var bytes: Int
    public var modelName: String
}

public enum SelectionAction: String, CaseIterable, Sendable {
    case explain, translate, rewrite
}

/// Drives the Context workspace (spec 5.2, 8.3, 13.5).
@MainActor @Observable
public final class ContextCoordinator {
    public private(set) var messages: [ContextMessage] = []
    public private(set) var isWorking = false
    public private(set) var transmission: TransmissionNotice?
    public private(set) var lastError: AIError?
    public private(set) var researchTabIDs: [UUID] = []
    public var modelID: String
    public var smartPreSummaryEnabled = false
    public var translationLanguage = "English"
    /// When set, the UI asks before sending this content; the closure resolves the user's choice.
    public var consentRequest: ConsentRequest?

    public struct ConsentRequest: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var host: String
        public var reason: String
    }

    @ObservationIgnored public let registry: ModelRegistry
    @ObservationIgnored private let client: AIInferenceClient
    @ObservationIgnored private let policy: PrivacyPolicyEngine
    @ObservationIgnored private let sessions: AISessionRepository?
    @ObservationIgnored private let redactor: Redactor
    @ObservationIgnored public weak var pages: PageContentProviding?
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var preSummaryTask: Task<Void, Never>?
    @ObservationIgnored private var lastPreSummaryURL: URL?
    @ObservationIgnored private var consentContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var session: AISession?
    @ObservationIgnored private var sessionProfileID: UUID?

    public init(client: AIInferenceClient, policy: PrivacyPolicyEngine, registry: ModelRegistry = .builtIn,
                sessions: AISessionRepository?, redactor: Redactor = Redactor()) {
        self.client = client; self.policy = policy; self.registry = registry; self.sessions = sessions
        self.redactor = redactor; self.modelID = registry.defaultModelID
    }

    public var model: AIModel { registry.model(modelID) }

    // MARK: User-initiated actions (the request itself is consent for that page)

    public func summarise(tabID: UUID, style: SummaryStyle = .quick) {
        run(label: "Summarise (\(style.rawValue))", tabIDs: [tabID], task: .summary(style))
    }

    public func ask(_ question: String, tabID: UUID?) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        run(label: q, tabIDs: tabID.map { [$0] } ?? [], task: .question(q), keepHistory: true)
    }

    public func selection(_ action: SelectionAction, text: String, tabID: UUID?) {
        let t = String(text.prefix(4000))
        let task: PromptBuilder.Task = switch action {
        case .explain: .explain(t)
        case .translate: .translate(t, to: translationLanguage)
        case .rewrite: .rewrite(t, tone: "clear, concise")
        }
        // Selected text is sent on its own; the rest of the page is not.
        run(label: "\(action.rawValue.capitalized): “\(t.prefix(60))”", tabIDs: [], task: task, extraHosts: tabID.map { [$0] } ?? [])
    }

    public func compare(tabIDs: [UUID]) {
        guard tabIDs.count >= 2 else { return }
        run(label: "Compare \(tabIDs.count) tabs", tabIDs: tabIDs, task: .compare)
    }

    public func extractFacts(tabID: UUID) { run(label: "Extract facts", tabIDs: [tabID], task: .extractFacts) }

    // MARK: Research collection (Throw to Context, spec 7.2)

    public func addToResearch(_ tabID: UUID) { if !researchTabIDs.contains(tabID) { researchTabIDs.append(tabID) } }
    public func removeFromResearch(_ tabID: UUID) { researchTabIDs.removeAll { $0 == tabID } }

    public func saveNote(_ text: String, source: URL?) async {
        guard let sessions else { return }
        try? await sessions.saveNote(ResearchNote(sessionID: session?.id, text: text, sourceURL: source))
    }

    // MARK: Smart Pre-Summary (spec 8.4, default off)

    public func pageDidBecomeReady(tabID: UUID, url: URL) {
        guard smartPreSummaryEnabled, url != lastPreSummaryURL else { return }
        preSummaryTask?.cancel()
        preSummaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))   // debounce rapid navigation
            guard let self, !Task.isCancelled else { return }
            let profileID = self.pages?.profileID(for: tabID) ?? PrivacyProfile.standardID
            let sitePolicy = await self.policy.policy(for: url, profileID: profileID)
            guard sitePolicy.allowAutomaticAI, !Task.isCancelled else { return }
            self.lastPreSummaryURL = url
            self.run(label: "Pre-summary", tabIDs: [tabID], task: .summary(.quick), automatic: true)
        }
    }

    // MARK: Control

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isWorking = false
        transmission = nil
    }

    public func clear() {
        cancel()
        messages.removeAll()
        session = nil
    }

    /// Waits for the request in flight, if any. Used by tests and by callers that chain actions.
    public func waitForCurrentRequest() async { await currentTask?.value }

    public func resolveConsent(_ allowed: Bool) {
        consentRequest = nil
        consentContinuation?.resume(returning: allowed)
        consentContinuation = nil
    }

    // MARK: Pipeline (spec 13.5)

    private func run(label: String, tabIDs: [UUID], task: PromptBuilder.Task, keepHistory: Bool = false,
                     automatic: Bool = false, extraHosts: [UUID] = []) {
        currentTask?.cancel()   // a newer request makes the old one stale
        lastError = nil
        if !automatic { messages.append(ContextMessage(role: .user, text: label)) }
        let model = self.model
        let history = keepHistory ? messages.dropLast().compactMap { m -> ChatMessage? in
            switch m.role { case .user: ChatMessage(.user, m.text); case .assistant: ChatMessage(.assistant, m.text); case .notice: nil }
        }.suffix(8) : []
        currentTask = Task { [weak self] in
            guard let self else { return }
            self.isWorking = true
            defer { self.isWorking = false; self.transmission = nil }

            // 1–4: resolve tabs, check policy, extract bounded content, redact.
            var pagesContent: [ExtractedContent] = []
            let budget = model.maxInputCharacters / max(1, tabIDs.count)
            for id in tabIDs {
                guard let provider = self.pages, let raw = await provider.extractedContent(tabID: id, maxBytes: budget) else { continue }
                let profileID = provider.profileID(for: id)
                let sitePolicy = await self.policy.policy(for: raw.sourceURL, profileID: profileID)
                let profile = await self.policy.profile(id: profileID)
                if automatic && !sitePolicy.allowAutomaticAI { return }
                if sitePolicy.isSensitive || profile.kind == .private {
                    // 5: explicit consent for sensitive sites and private sessions, even when user-initiated.
                    let ok = await self.askConsent(host: raw.sourceURL.kageHost,
                                                   reason: profile.kind == .private ? "This is a private tab." : "This looks like a sensitive site.")
                    if !ok { self.messages.append(ContextMessage(role: .notice, text: "Nothing was sent.")); return }
                }
                pagesContent.append(Redactor(maxBytes: budget).redact(raw))
                self.sessionProfileID = profileID
            }
            if Task.isCancelled { return }
            if !tabIDs.isEmpty && pagesContent.isEmpty {
                self.messages.append(ContextMessage(role: .notice, text: "Kage couldn't read this page."))
                return
            }

            let prompt = PromptBuilder.messages(for: task, pages: pagesContent, history: Array(history))
            let bytes = prompt.reduce(0) { $0 + $1.content.utf8.count }
            let hostIDs = tabIDs + extraHosts
            var hosts = pagesContent.map { $0.sourceURL.kageHost }
            if hosts.isEmpty, let p = self.pages {
                for id in hostIDs { if let c = await p.extractedContent(tabID: id, maxBytes: 1) { hosts.append(c.sourceURL.kageHost) } }
            }
            self.transmission = TransmissionNotice(hosts: hosts, bytes: bytes, modelName: model.name)

            // 6–7: send natively; render reply as untrusted text with only allowlisted proposals.
            var reply = ContextMessage(role: .assistant, text: "", sources: pagesContent.map(\.sourceURL))
            self.messages.append(reply)
            let index = self.messages.count - 1
            do {
                var raw = ""
                for try await chunk in self.client.complete(prompt, modelID: model.id, stream: model.supportsStreaming) {
                    if Task.isCancelled { break }
                    raw += chunk
                    if self.messages.indices.contains(index) { self.messages[index].text = raw }
                }
                let parsed = ProposedActionParser.parse(raw)
                reply.text = parsed.text
                reply.proposedActions = parsed.proposedActions
                if self.messages.indices.contains(index) { self.messages[index] = reply }
                await self.persist()
            } catch {
                let e = (error as? AIError) ?? .malformedResponse
                self.lastError = e
                if self.messages.indices.contains(index) { self.messages.remove(at: index) }
                if e != .cancelled { self.messages.append(ContextMessage(role: .notice, text: e.userMessage)) }
            }
        }
    }

    private func askConsent(host: String, reason: String) async -> Bool {
        consentContinuation?.resume(returning: false)
        return await withCheckedContinuation { cont in
            consentContinuation = cont
            consentRequest = ConsentRequest(host: host, reason: reason)
        }
    }

    /// 8: save locally only if the profile keeps AI chats (Ghost and Private never do).
    private func persist() async {
        guard let sessions else { return }
        let profile = await policy.profile(id: sessionProfileID ?? PrivacyProfile.standardID)
        guard profile.persistsAIConversations else { return }
        var s = session ?? AISession(tabIDs: researchTabIDs, modelID: modelID)
        s.localMessages = messages.compactMap { m in
            switch m.role {
            case .user: AISession.Message(role: .user, text: m.text)
            case .assistant: AISession.Message(role: .assistant, text: m.text)
            case .notice: nil
            }
        }
        s.sourceReferences = Array(Set(messages.flatMap(\.sources)))
        session = s
        try? await sessions.save(s)
    }
}
