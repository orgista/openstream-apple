import Foundation

/// A title link the app opens: an IMDb or TMDB page, which resolve through
/// TMDB's API. Links to other services are not read.
public enum SharedLink: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case movie, show }
    case imdb(String)
    case tmdb(Kind, Int)

    public var provider: String {
        switch self {
        case .imdb: "IMDb"
        case .tmdb: "TMDB"
        }
    }
}

public enum AppleSharedLinkError: Error, Equatable, LocalizedError {
    case unreadable
    /// The title is not in the viewer's sources and TMDB is not set up
    /// (no key, or Settings › Metadata off).
    case metadataUnavailable
    public var errorDescription: String? {
        switch self {
        case .unreadable: "Couldn't read that link"
        case .metadataUnavailable: "Metadata unavailable"
        }
    }
}

/// URL parsing only. No UI, networking or provider credentials.
public enum AppleSharedLinkResolver {
    public struct Title: Equatable, Sendable {
        public let name: String
        public let year: Int?
        public let kind: SharedLink.Kind?
        public init(name: String, year: Int? = nil, kind: SharedLink.Kind? = nil) {
            self.name = name; self.year = year; self.kind = kind
        }
    }

    public static func parse(_ url: URL) -> SharedLink? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              url.absoluteString.count <= 8_192 else { return nil }
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        func digits(_ value: String) -> Bool { !value.isEmpty && value.count <= 18 && value.allSatisfy { $0.isASCII && $0.isNumber } }
        switch host {
        case "imdb.com", "www.imdb.com", "m.imdb.com":
            guard parts.count == 2, parts[0] == "title", parts[1].hasPrefix("tt"), digits(String(parts[1].dropFirst(2))) else { return nil }
            return .imdb(parts[1])
        case "themoviedb.org", "www.themoviedb.org":
            guard parts.count == 2, ["movie", "tv"].contains(parts[0]),
                  let number = parts[1].split(separator: "-").first.map(String.init), digits(number),
                  let id = Int(number), id > 0 else { return nil }
            return .tmdb(parts[0] == "movie" ? .movie : .show, id)
        default: return nil
        }
    }

    public static func link(in text: String) -> SharedLink? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every supported title URL has a path; ordinary typing needs no data detector.
        guard clean.contains("/") else { return nil }
        if let url = URL(string: clean), let link = parse(url) { return link }
        guard clean.count <= 8_192, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { $0.url.flatMap(parse) }
        return links.count == 1 ? links.first : nil
    }
}
