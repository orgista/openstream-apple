import Foundation

/// Where a source came from, in as few characters as a settings row can spare:
/// the row reads "Media Server · example.com" rather than a full address.
public enum AppleSourceOriginLabel: Sendable {
    /// The host, trimmed to something a person reads rather than a hostname.
    ///
    /// `https://media.example.com/library` → `example.com`. Subdomains go
    /// because they are noise rather than origin. A host that is already two
    /// labels is left alone.
    public static func origin(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        // An IP address is its own origin; do not slice it into pieces.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        // Two labels is the common case (`example.com`). Three where the last two
        // are short is usually a country second-level domain (`co.uk`).
        let tail = parts.suffix(2).joined(separator: ".")
        if parts.count >= 3, parts[parts.count - 2].count <= 3, parts[parts.count - 1].count <= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return tail
    }

    /// The subtitle a source row shows: its kind, and where it came from when
    /// that adds anything.
    public static func subtitle(kind: String, url: URL?) -> String {
        guard let origin = origin(for: url) else { return kind }
        return "\(kind) · \(origin)"
    }
}
