import Foundation

/// Maps streaming catalog IDs to clean, human-readable service names.
/// Based on the Streaming Catalogs add-on (github.com/rleroi/Stremio-Streaming-Catalogs-Addon).
public enum AppleCatalogServiceName: Sendable {
    
    /// Returns the human-readable service name for a given catalog ID, or nil if it's not a known per-service catalog.
    public static func service(fromCatalogID id: String? = nil, name: String?) -> String? {
        let id = id?.lowercased() ?? ""
        switch id {
        case "nfx": return "Netflix"
        case "nfk": return "Netflix Kids"
        case "hbm": return "HBO Max"
        case "dnp": return "Disney+"
        case "hlu": return "Hulu"
        case "amp": return "Prime"
        case "pmp": return "Paramount+"
        case "atp": return "Apple TV+"
        case "pcp", "pct": return "Peacock"
        case "cru", "fmn": return "Crunchyroll"
        case "jhs", "hst": return "JioHotstar"
        case "zee": return "Zee5"
        case "vil": return "Videoland"
        case "clv": return "Clarovideo"
        case "gop": return "Globoplay"
        case "hay": return "Hayu"
        case "nlz": return "NLZIET"
        case "sst": return "SkyShowtime"
        case "mgl": return "MagellanTV"
        case "cts": return "Curiosity Stream"
        case "cpd": return "Canal+"
        case "stz": return "Starz"
        case "dpe": return "Discovery+"
        case "mbi": return "Mubi"
        case "vik": return "Rakuten Viki"
        case "sgo": return "Sky Go"
        case "sonyliv": return "Sony Liv"
        case "mp9": return "Movistar+"
        case "shd": return "Shudder"
        case "bbo": return "BritBox"
        case "act": return "Acorn TV"
        case "itv": return "ITVX"
        case "bbc": return "BBC iPlayer"
        case "al4": return "Channel 4"
        case "crc": return "Criterion Channel"
        case "iqi": return "iQIYI"
        case "sha": return "Shahid VIP"
        default:
            if id.hasPrefix("netflix-top10") {
                return "Netflix"
            }
            if let name {
                let cleaned = name
                    .replacingOccurrences(of: "Streaming Catalog", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "Catalog", with: "", options: .caseInsensitive)
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if cleaned.caseInsensitiveCompare("Prime Video") == .orderedSame {
                    return "Prime"
                }
                return cleaned.isEmpty ? nil : cleaned
            }
            return nil
        }
    }
}
