import Foundation

/// Shared with the tiny share extension; deliberately has no package or networking dependency.
public enum AppleSharedLinkHandoff {
    private static let group = "group.com.orgista.openstream"
    private static let key = "OpenStreamPendingSharedLink"

    public static func deepLink(for url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.absoluteString.count <= 8_192 else { return nil }
        var components = URLComponents(string: "openstream://open")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components?.url
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
