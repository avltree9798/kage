#if canImport(WebKit)
import Foundation
import Observation
import KageModels
import BrowserCore

/// Turns WebKit's async prompt requests into UI state the shell renders as alerts and sheets.
/// Page-originated prompts always show the requesting host so they can't impersonate Kage (spec 15.2).
@MainActor @Observable
public final class PromptCenter: BrowserPromptPresenting {
    public enum Kind: Equatable {
        case alert(message: String, host: String)
        case confirm(message: String, host: String)
        case prompt(message: String, defaultText: String?, host: String)
        case openExternal(URL)
        case media(host: String, camera: Bool, microphone: Bool)
    }

    public struct Pending: Identifiable, Equatable {
        public let id = UUID()
        public let kind: Kind
    }

    public private(set) var pending: Pending?
    public var promptText = ""
    @ObservationIgnored private var continuation: CheckedContinuation<Answer, Never>?

    public enum Answer: Sendable { case ok, cancel, text(String?), decision(PermissionDecision) }

    public init() {}

    private func ask(_ kind: Kind) async -> Answer {
        continuation?.resume(returning: .cancel)   // one prompt at a time; a new one dismisses the old
        return await withCheckedContinuation { c in
            continuation = c
            if case .prompt(_, let d, _) = kind { promptText = d ?? "" }
            pending = Pending(kind: kind)
        }
    }

    public func answer(_ a: Answer) {
        pending = nil
        continuation?.resume(returning: a)
        continuation = nil
    }

    public func confirmOpenExternally(_ url: URL) async -> Bool {
        if case .ok = await ask(.openExternal(url)) { return true }
        return false
    }
    public func alert(message: String, from host: String) async { _ = await ask(.alert(message: message, host: host)) }
    public func confirm(message: String, from host: String) async -> Bool {
        if case .ok = await ask(.confirm(message: message, host: host)) { return true }
        return false
    }
    public func prompt(message: String, defaultText: String?, from host: String) async -> String? {
        if case .text(let t) = await ask(.prompt(message: message, defaultText: defaultText, host: host)) { return t }
        return nil
    }
    public func mediaPermission(for host: String, camera: Bool, microphone: Bool) async -> PermissionDecision {
        if case .decision(let d) = await ask(.media(host: host, camera: camera, microphone: microphone)) { return d }
        return .deny
    }
    #if os(macOS)
    public var openPanelHandler: ((Bool, Bool) async -> [URL]?)?
    public func openPanel(allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        await openPanelHandler?(allowsMultiple, allowsDirectories)
    }
    #endif
}
#endif
