import Foundation

/// Where a source came from, in as few characters as a settings row can spare.
///
/// The owner asked for Stremio-hosted add-ons to carry the Stremio icon so they
/// are easier to tell apart (2026-09-15). Two things argued against doing it
/// that way: the icon is not fetchable — every `strem.io` favicon path 404s and
/// the apex redirects to a page without one — and a single shared mark would
/// make *Cinemeta* and *OpenSubtitles* look identical to each other, which is
/// the opposite of telling them apart.
///
/// Naming the origin does the job with no artwork at all: "Add-on · strem.io"
/// separates the official add-ons from a self-hosted one at a glance, while the
/// per-source monogram still separates them from each other.
public enum AppleSourceOriginLabel: Sendable {
    /// The host, trimmed to something a person reads rather than a hostname.
    ///
    /// `https://v3-cinemeta.strem.io/manifest.json` → `strem.io`. Subdomains go
    /// because every official add-on lives on its own (`v3-cinemeta`,
    /// `opensubtitles-v3`), and showing those would be noise rather than
    /// origin. A host that is already two labels is left alone.
    public static func origin(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        // An IP address is its own origin; do not slice it into pieces.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        // Two labels is the common case (`strem.io`). Three where the last two
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
