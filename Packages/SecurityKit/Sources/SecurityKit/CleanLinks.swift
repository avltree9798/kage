import Foundation

/// Removes known tracking parameters from a URL before copying or sharing (spec 10).
/// Only parameters on this list are removed, so functional query strings keep working.
public enum CleanLinks {
    public static let exactParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id",
        "spm", "si", "s_cid", "ref_src", "ref_url",
    ]
    public static let prefixes = ["utm_", "pk_", "hsa_"]

    public static func clean(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !exactParameters.contains(name) && !prefixes.contains { name.hasPrefix($0) }
        }
        guard kept.count != items.count else { return url }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url ?? url
    }
}
