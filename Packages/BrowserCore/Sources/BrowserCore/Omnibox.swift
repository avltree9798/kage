import Foundation

public enum OmniboxDestination: Sendable, Equatable {
    case url(URL)
    case search(URL)
}

public protocol OmniboxResolving: Sendable {
    func resolve(_ input: String) -> OmniboxDestination?
}

/// Spec 6.1 / 13.4 step 2: decide whether input is a URL or a search query.
public struct OmniboxResolver: OmniboxResolving {
    /// Search template with `%s` for the encoded query.
    public var searchTemplate: String

    public init(searchTemplate: String = "https://duckduckgo.com/?q=%s") {
        self.searchTemplate = searchTemplate
    }

    public func resolve(_ input: String) -> OmniboxDestination? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains(" ") {
            if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme), url.host != nil {
                return .url(url)
            }
            if looksLikeHost(text), let url = URL(string: "https://" + text) {
                return .url(url)
            }
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q)) else { return nil }
        return .search(url)
    }

    private func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        if hostOnly == "localhost" { return true }
        let labels = hostOnly.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }
}
