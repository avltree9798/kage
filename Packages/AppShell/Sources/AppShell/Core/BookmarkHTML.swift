import Foundation
import KageModels

/// Netscape bookmark file format, used by Safari, Chrome and Firefox for import/export (spec 6.5).
public enum BookmarkHTML {
    public static func render(_ bookmarks: [Bookmark]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"
        for b in bookmarks {
            let tags = b.tags.isEmpty ? "" : " TAGS=\"\(esc(b.tags.joined(separator: ",")))\""
            out += "    <DT><A HREF=\"\(esc(b.url.absoluteString))\" ADD_DATE=\"\(Int(b.createdAt.timeIntervalSince1970))\"\(tags)>\(esc(b.title))</A>\n"
        }
        return out + "</DL><p>\n"
    }

    public static func write(_ bookmarks: [Bookmark]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kage Bookmarks.html")
        try render(bookmarks).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Extracts `<A HREF=...>title</A>` entries. Only http(s) links are imported.
    public static func parse(_ html: String) -> [Bookmark] {
        guard let re = try? NSRegularExpression(pattern: #"<A\s+[^>]*HREF="([^"]+)"[^>]*>(.*?)</A>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let href = unescape(ns.substring(with: m.range(at: 1)))
            let title = unescape(ns.substring(with: m.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: href), let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
            return Bookmark(url: url, title: title.isEmpty ? url.kageHost : title)
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
