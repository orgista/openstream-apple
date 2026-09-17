import Foundation

/// Decodes the handful of HTML entities that catalogue metadata actually
/// carries.
///
/// Cinemeta and TMDB both hand back overviews that were escaped for a web page
/// somewhere upstream, so a title like *9/11: One Day in America* arrives
/// describing a collaboration with the "9/11 Memorial `&amp;` Museum" and the
/// raw entity is what the viewer reads on the hero and the title page.
///
/// `&amp;` is decoded **last** on purpose: doing it first would turn the
/// already-escaped `&amp;lt;` into `<` and re-introduce the markup the source
/// deliberately escaped.
public enum AppleHTMLEntities {
    private static let replacements: [(String, String)] = [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#34;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&hellip;", "…"),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&rsquo;", "\u{2019}"),
        ("&lsquo;", "\u{2018}"),
        ("&ldquo;", "\u{201C}"),
        ("&rdquo;", "\u{201D}"),
        ("&amp;", "&"),
    ]

    /// Returns `value` with known entities decoded, unchanged when it holds no
    /// `&` at all — which is the overwhelming majority of strings.
    public static func decoded(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = value
        for (entity, character) in replacements {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// Decodes an optional display string, preserving `nil`.
    public static func decoded(_ value: String?) -> String? {
        value.map(decoded)
    }
}
