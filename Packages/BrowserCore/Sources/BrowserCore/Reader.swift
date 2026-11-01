import Foundation

/// Spec 6.6. Extracted locally in a Kage-owned content world; nothing leaves the device.
public struct ReaderDocument: Sendable, Equatable, Codable {
    public var title: String
    public var byline: String?
    public var paragraphs: [String]
    public var sourceURL: URL?

    public init(title: String, byline: String? = nil, paragraphs: [String], sourceURL: URL? = nil) {
        self.title = title; self.byline = byline; self.paragraphs = paragraphs; self.sourceURL = sourceURL
    }

    public var text: String { paragraphs.joined(separator: "\n\n") }
    public var wordCount: Int { paragraphs.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count } }
    /// At 230 words per minute, rounded up, minimum one minute.
    public var readingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded(.up))) }
    /// Too little text means extraction failed and the UI should fall back to the page (spec 6.6).
    public var isUsable: Bool { wordCount >= 80 && !paragraphs.isEmpty }
}

public enum ReaderTheme: String, CaseIterable, Sendable, Codable { case light, dark, sepia }

public enum ReaderScripts {
    /// Scores block elements by text density and returns the best article candidate as JSON.
    /// Runs via `callAsyncJavaScript` in the Kage content world, so page scripts can't see or tamper with it.
    public static let extract = #"""
    const pick = () => {
      const bad = /comment|footer|header|nav|sidebar|sponsor|promo|related|share|social|cookie|banner|modal|subscribe/i;
      const nodes = Array.from(document.querySelectorAll('article, main, [role=main], section, div'));
      let best = null, bestScore = 0;
      for (const n of nodes) {
        const label = (n.className || '') + ' ' + (n.id || '');
        if (bad.test(label)) continue;
        const ps = n.querySelectorAll(':scope > p, :scope > div > p');
        let score = 0;
        for (const p of ps) { const t = p.innerText.trim(); if (t.length > 40) score += Math.min(t.length, 600) + 25 * (t.split(',').length); }
        if (n.tagName === 'ARTICLE') score *= 1.3;
        if (score > bestScore) { bestScore = score; best = n; }
      }
      const root = best || document.body;
      const paragraphs = Array.from(root.querySelectorAll('h2, h3, p, li, blockquote, pre'))
        .map(e => e.innerText.trim()).filter(t => t.length > 0).slice(0, 2000);
      const meta = (k) => { const m = document.querySelector(`meta[name="${k}"], meta[property="${k}"]`); return m ? m.content : null; };
      return JSON.stringify({ title: meta('og:title') || document.title || '', byline: meta('author'), paragraphs });
    };
    return pick();
    """#

    /// Visible page text for Context AI, capped in bytes by the caller.
    public static let pageText = #"""
    const sel = window.getSelection ? String(window.getSelection()) : '';
    return JSON.stringify({ title: document.title || '', selection: sel, text: (document.body ? document.body.innerText : '').slice(0, maxChars) });
    """#

    public static func decode(_ json: String, sourceURL: URL?) -> ReaderDocument? {
        struct Raw: Decodable { var title: String; var byline: String?; var paragraphs: [String] }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return nil }
        return ReaderDocument(title: raw.title, byline: raw.byline, paragraphs: raw.paragraphs, sourceURL: sourceURL)
    }
}
