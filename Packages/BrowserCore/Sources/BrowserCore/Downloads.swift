import Foundation
import KageModels

/// Makes server-suggested filenames safe to write (spec 15.2).
public enum FilenameSanitizer {
    public static func sanitize(_ suggested: String, fallback: String = "download") -> String {
        var name = suggested.precomposedStringWithCanonicalMapping
        // Strip any path the server tried to smuggle in.
        name = name.replacingOccurrences(of: "\\", with: "/")
        name = name.split(separator: "/").last.map(String.init) ?? ""
        let forbidden = CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters).union(.newlines)
        name = name.unicodeScalars.filter { !forbidden.contains($0) }.map(String.init).joined()
        // Bidi overrides can disguise "exe.pdf" as "fdp.exe".
        let bidi: Set<Unicode.Scalar> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !bidi.contains($0) }))
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if name.isEmpty { name = fallback }
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            name = String(base.prefix(180)) + (ext.isEmpty ? "" : "." + String(ext.prefix(15)))
        }
        return name
    }

    /// Returns a URL in `directory` that doesn't exist yet: "file.pdf", "file 2.pdf", ...
    public static func uniqueDestination(for name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// File types that run code when opened; the UI shows an extra warning before opening them.
    public static let riskyExtensions: Set<String> = ["exe", "msi", "bat", "cmd", "scr", "app", "pkg", "dmg", "command", "sh",
                                                      "jar", "js", "vbs", "ps1", "mobileconfig", "terminal", "workflow"]
    public static func isRisky(_ name: String) -> Bool {
        riskyExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
