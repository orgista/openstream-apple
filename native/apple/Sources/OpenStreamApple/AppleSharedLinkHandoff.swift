import Foundation

/// Shared with the tiny share extension; deliberately has no package or networking dependency.
public enum AppleSharedLinkHandoff {
    private static let group = "group.com.orgista.openstream"
    private static let key = "OpenStreamPendingSharedLink"

    /// IMDb and TMDB title pages, which the app resolves through TMDB's API.
    static let supportedHosts: Set<String> = ["imdb.com", "www.imdb.com", "m.imdb.com",
                                              "themoviedb.org", "www.themoviedb.org"]

    public static func deepLink(for url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              supportedHosts.contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.absoluteString.count <= 8_192 else { return nil }
        var components = URLComponents(string: "openstream://open")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components?.url
    }

    /// The app link for what a share sheet handed over: a URL, or text that
    /// holds exactly one supported link.
    public static func deepLink(inShared text: String) -> URL? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.contains(where: \.isWhitespace), let url = URL(string: clean), let link = deepLink(for: url) { return link }
        guard clean.count <= 8_192, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap(\.url)
            .compactMap(deepLink(for:))
        return links.count == 1 ? links.first : nil
    }

    public static func save(_ url: URL) {
        UserDefaults(suiteName: group)?.set(url.absoluteString, forKey: key)
    }

    public static func take() -> URL? {
        guard let defaults = UserDefaults(suiteName: group), let raw = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return URL(string: raw)
    }

    public static func clear(matching url: URL) {
        guard let defaults = UserDefaults(suiteName: group), defaults.string(forKey: key) == url.absoluteString else { return }
        defaults.removeObject(forKey: key)
    }
}
