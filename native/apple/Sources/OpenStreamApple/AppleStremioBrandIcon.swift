import Foundation

/// The Stremio mark, for add-ons served from strem.io whose own manifest
/// publishes no logo this app can use.
///
/// Cinemeta publishes none at all and OpenSubtitles v3 publishes a wordmark
/// too wide to read at 44 points, so both fell back to a monogram chip. The
/// owner asked for the Stremio mark there instead — "same for any stremi.io
/// with no icons default to that it just helps differiate" (2026-09-15) — so
/// a Stremio add-on reads as a Stremio add-on rather than as a letter in a
/// box.
///
/// The mark is referenced at Stremio's own origin rather than bundled: no
/// third-party artwork ships inside OpenStream, and a row falls back to its
/// existing monogram when the fetch fails or the device is offline.
public enum AppleStremioBrandIcon {
    /// Stremio's own 120×120 mark. Square, so it never trips the wordmark
    /// ratio that rejected OpenSubtitles' logo.
    public static let url = URL(string: "https://www.strem.io/images/stremio-logo-small.png")!

    /// The domains Stremio itself serves add-ons from.
    private static let hosts = ["strem.io", "stremio.com"]

    /// True for `strem.io`, `stremio.com` and their subdomains — matched on
    /// the label boundary, so `notstrem.io` and `strem.io.example.com` do not
    /// borrow someone else's mark.
    public static func isStremioHosted(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The mark to draw for a source, or nil to leave its existing fallback
    /// alone. Only add-ons qualify: an IPTV playlist or a network share that
    /// happened to live on strem.io is not a Stremio add-on.
    public static func fallbackURL(kind: AppleSourceKind, manifestURL: URL?) -> URL? {
        guard kind == .stremio, isStremioHosted(manifestURL) else { return nil }
        return url
    }
}
