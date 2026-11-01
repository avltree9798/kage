import Foundation
import KageModels

/// Builds WebKit content-blocker JSON (spec 10). Pure, so it can be validated in unit tests
/// before `WKContentRuleListStore` compiles it.
public enum ContentRuleBuilder {
    /// WebKit rejects very large lists; keep each compiled list well under its limit.
    public static let maxRulesPerList = 50_000

    public struct Rule: Codable, Sendable, Equatable {
        public struct Trigger: Codable, Sendable, Equatable {
            public var urlFilter: String
            public var loadType: [String]?
            public var ifDomain: [String]?
            public var unlessDomain: [String]?
            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter", loadType = "load-type", ifDomain = "if-domain", unlessDomain = "unless-domain"
            }
        }
        public struct Action: Codable, Sendable, Equatable {
            public var type: String
        }
        public var trigger: Trigger
        public var action: Action
    }

    /// Escapes a domain for WebKit's limited regex syntax and matches it and its subdomains.
    static func filter(for domain: String) -> String {
        let escaped = domain.lowercased().replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]*\\.)?\(escaped)[/:]"
    }

    public static func rules(mode: BlockingMode, trackers: [String], exceptions: [String]) -> [Rule] {
        guard mode != .off else { return [] }
        var rules = trackers.sorted().map {
            Rule(trigger: .init(urlFilter: filter(for: $0), loadType: mode == .strict ? nil : ["third-party"]),
                 action: .init(type: "block"))
        }
        if mode == .strict {
            rules.append(Rule(trigger: .init(urlFilter: ".*", loadType: ["third-party"]), action: .init(type: "block-cookies")))
        }
        if !exceptions.isEmpty {
            // "ignore-previous-rules" must come last to override everything above for these sites.
            rules.append(Rule(trigger: .init(urlFilter: ".*", ifDomain: exceptions.sorted().map { "*" + $0.lowercased() }),
                              action: .init(type: "ignore-previous-rules")))
        }
        return rules
    }

    public static func encode(_ rules: [Rule]) throws -> [String] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var chunks: [String] = []
        var start = 0
        let exceptionRule = rules.last.flatMap { $0.action.type == "ignore-previous-rules" ? $0 : nil }
        let body = exceptionRule == nil ? rules : Array(rules.dropLast())
        repeat {
            var chunk = Array(body[start..<min(start + maxRulesPerList, body.count)])
            if let exceptionRule { chunk.append(exceptionRule) }
            chunks.append(String(decoding: try enc.encode(chunk), as: UTF8.self))
            start += maxRulesPerList
        } while start < body.count
        return chunks
    }

    /// Seed list of widely documented third-party tracking hosts. Replace with an approved,
    /// licence-compatible ruleset and signed updates (spec 24 Q9, ticket K-21).
    public static let seedTrackers: [String] = [
        "doubleclick.net", "google-analytics.com", "googletagmanager.com", "googlesyndication.com",
        "googleadservices.com", "connect.facebook.net", "scorecardresearch.com", "adnxs.com", "criteo.com",
        "criteo.net", "taboola.com", "outbrain.com", "hotjar.com", "quantserve.com", "moatads.com",
        "amazon-adsystem.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "bluekai.com", "demdex.net", "krxd.net", "chartbeat.com", "newrelic.com",
        "bat.bing.com", "ads.linkedin.com", "analytics.tiktok.com", "ads-twitter.com",
    ]
}

#if canImport(WebKit)
import WebKit

/// Compiles and caches rule lists in `WKContentRuleListStore` (spec 10).
@MainActor public final class ContentBlockingManager {
    public private(set) var mode: BlockingMode
    public private(set) var exceptions: Set<String>
    public private(set) var compiled: [WKContentRuleList] = []
    private let trackers: [String]

    public init(mode: BlockingMode = .standard, exceptions: Set<String> = [], trackers: [String] = ContentRuleBuilder.seedTrackers) {
        self.mode = mode; self.exceptions = exceptions; self.trackers = trackers
    }

    public func update(mode: BlockingMode, exceptions: Set<String>) async throws {
        self.mode = mode; self.exceptions = exceptions
        let json = try ContentRuleBuilder.encode(
            ContentRuleBuilder.rules(mode: mode, trackers: trackers, exceptions: Array(exceptions)))
        guard let store = WKContentRuleListStore.default() else { return }
        var lists: [WKContentRuleList] = []
        if mode != .off {
            for (i, chunk) in json.enumerated() {
                if let list = try await store.compileContentRuleList(forIdentifier: "kage-\(mode.rawValue)-\(i)",
                                                                     encodedContentRuleList: chunk) {
                    lists.append(list)
                }
            }
        }
        compiled = lists
    }

    /// Installs the current lists on a configuration's controller, replacing any previous ones.
    public func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        compiled.forEach(controller.add)
    }
}
#endif
