import Foundation

/// Selectable default engine (spec 6.1). Suggestions are off unless the user enables them,
/// and the UI states that typed text goes to the provider when they are on.
public struct SearchEngine: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var searchTemplate: String
    public var suggestTemplate: String?

    public static let duckDuckGo = SearchEngine(id: "ddg", name: "DuckDuckGo", searchTemplate: "https://duckduckgo.com/?q=%s",
                                                suggestTemplate: "https://duckduckgo.com/ac/?q=%s&type=list")
    public static let google = SearchEngine(id: "google", name: "Google", searchTemplate: "https://www.google.com/search?q=%s",
                                            suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s")
    public static let bing = SearchEngine(id: "bing", name: "Bing", searchTemplate: "https://www.bing.com/search?q=%s",
                                          suggestTemplate: "https://api.bing.com/osjson.aspx?query=%s")
    public static let ecosia = SearchEngine(id: "ecosia", name: "Ecosia", searchTemplate: "https://www.ecosia.org/search?q=%s",
                                            suggestTemplate: nil)
    public static let startpage = SearchEngine(id: "startpage", name: "Startpage",
                                               searchTemplate: "https://www.startpage.com/do/search?q=%s", suggestTemplate: nil)
    public static let all: [SearchEngine] = [.duckDuckGo, .google, .bing, .ecosia, .startpage]

    public var resolver: OmniboxResolver { OmniboxResolver(searchTemplate: searchTemplate) }
}

/// Fetches suggestions from the engine's OpenSearch endpoint, with no cookies sent.
public struct SearchSuggestionClient: Sendable {
    let session: URLSession
    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 3
        session = URLSession(configuration: cfg)
    }

    public func suggestions(for text: String, engine: SearchEngine) async -> [String] {
        guard let template = engine.suggestTemplate, text.count >= 2,
              let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: q)),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2, let list = json[1] as? [String] else { return [] }
        return Array(list.prefix(6))
    }
}
