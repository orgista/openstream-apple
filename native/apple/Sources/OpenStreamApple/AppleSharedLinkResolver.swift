import Foundation

public enum SharedLink: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case movie, show, episode }
    case appleTV(Kind, String, String)
    case netflix(String)
    case youtube(String)
    case imdb(String)
    case tmdb(Kind, Int)
    case trakt(Kind, String)
    case letterboxd(String)

    public var provider: String {
        switch self {
        case .appleTV: "Apple TV"
        case .netflix: "Netflix"
        case .youtube: "YouTube"
        case .imdb: "IMDb"
        case .tmdb: "TMDB"
        case .trakt: "Trakt"
        case .letterboxd: "Letterboxd"
        }
    }
}

public enum AppleSharedLinkError: Error, Equatable, LocalizedError {
    case netflixUnreadable, unreadable, unsupportedYouTube
    public var errorDescription: String? {
        switch self {
        case .netflixUnreadable: "Couldn't read that Netflix link"
        case .unreadable: "Couldn't read that link"
        case .unsupportedYouTube:
            #if OPENSTREAM_ADDONS
            "YouTube links need the YouTube add-on"
            #else
            "YouTube links aren't supported."
            #endif
        }
    }
}

/// URL parsing, public-page metadata and conservative title matching. No UI or provider credentials.
public struct AppleSharedLinkResolver: Sendable {
    public struct Title: Equatable, Sendable {
        public let name: String
        public let year: Int?
        public let kind: SharedLink.Kind?
        public init(name: String, year: Int? = nil, kind: SharedLink.Kind? = nil) {
            self.name = name; self.year = year; self.kind = kind
        }
    }
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let loader: Loader
    public init(loader: @escaping Loader = { try await URLSession.shared.data(for: $0) }) {
        self.loader = loader
    }

    public static func parse(_ url: URL) -> SharedLink? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              url.absoluteString.count <= 8_192 else { return nil }
        let host = url.host?.lowercased() ?? ""
        var parts = url.path.split(separator: "/").map(String.init)
        func validSlug(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 200 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        func digits(_ value: String) -> Bool { !value.isEmpty && value.count <= 18 && value.allSatisfy { $0.isASCII && $0.isNumber } }
        switch host {
        case "tv.apple.com":
            if parts.count == 4 { parts.removeFirst() }
            guard parts.count == 3, let kind = SharedLink.Kind(rawValue: parts[0]), validSlug(parts[1]),
                  parts[2].hasPrefix("umc.cmc."), parts[2].count > 8,
                  parts[2].dropFirst(8).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return .appleTV(kind, parts[1], parts[2])
        case "netflix.com", "www.netflix.com":
            if parts.count == 3 { parts.removeFirst() }
            guard parts.count == 2, parts[0] == "title", digits(parts[1]) else { return nil }
            return .netflix(parts[1])
        case "youtu.be", "www.youtube.com", "youtube.com", "m.youtube.com":
            let id: String?
            if host == "youtu.be" { id = parts.count == 1 ? parts.first : nil }
            else if parts == ["watch"] {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else { id = parts.count == 2 && parts[0] == "shorts" ? parts[1] : nil }
            guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            return .youtube(id)
        case "imdb.com", "www.imdb.com", "m.imdb.com":
            guard parts.count == 2, parts[0] == "title", parts[1].hasPrefix("tt"), digits(String(parts[1].dropFirst(2))) else { return nil }
            return .imdb(parts[1])
        case "themoviedb.org", "www.themoviedb.org":
            guard parts.count == 2, ["movie", "tv"].contains(parts[0]),
                  let number = parts[1].split(separator: "-").first.map(String.init), digits(number),
                  let id = Int(number), id > 0 else { return nil }
            return .tmdb(parts[0] == "movie" ? .movie : .show, id)
        case "trakt.tv", "www.trakt.tv":
            guard parts.count == 2, ["movies", "shows"].contains(parts[0]), validSlug(parts[1]) else { return nil }
            return .trakt(parts[0] == "movies" ? .movie : .show, parts[1])
        case "letterboxd.com", "www.letterboxd.com":
            guard parts.count == 2, parts[0] == "film", validSlug(parts[1]) else { return nil }
            return .letterboxd(parts[1])
        default: return nil
        }
    }

    public static func link(in text: String) -> SharedLink? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: clean), let link = parse(url) { return link }
        guard clean.count <= 8_192, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { $0.url.flatMap(parse) }
        return links.count == 1 ? links.first : nil
    }

    public func title(for link: SharedLink) async throws -> Title {
        appleTrace("shared link lookup \(link.provider)")
        let url: URL
        let fallback: Title?
        switch link {
        case .appleTV(let kind, let slug, let id):
            url = URL(string: "https://tv.apple.com/us/\(kind.rawValue)/\(slug)/\(id)")!
            fallback = Title(name: Self.deslug(slug), kind: kind)
        case .netflix(let id):
            url = URL(string: "https://www.netflix.com/title/\(id)")!
            fallback = nil
        case .trakt(let kind, let slug):
            url = URL(string: "https://trakt.tv/\(kind == .movie ? "movies" : "shows")/\(slug)")!
            fallback = Self.slugTitle(slug, kind: kind)
        case .letterboxd(let slug):
            url = URL(string: "https://letterboxd.com/film/\(slug)/")!
            fallback = Self.slugTitle(slug, kind: .movie)
        default: throw AppleSharedLinkError.unreadable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await loader(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  data.count <= 4_000_000, let html = String(data: data, encoding: .utf8),
                  let value = Self.pageTitle(html) else { throw AppleSharedLinkError.unreadable }
            return Title(name: value.name, year: value.year, kind: value.kind ?? fallback?.kind)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let fallback { appleTrace("shared link lookup slug fallback \(link.provider)"); return fallback }
            throw AppleSharedLinkError.netflixUnreadable
        }
    }

    public static func pageTitle(_ html: String) -> Title? {
        func matches(_ pattern: String, _ input: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
                Range($0.range(at: 1), in: input).map { String(input[$0]) }
            }
        }
        var name: String?
        var year: Int?
        var kind: SharedLink.Kind?
        func walk(_ value: Any) {
            if let values = value as? [Any] { values.forEach(walk); return }
            guard let object = value as? [String: Any] else { return }
            let type = object["@type"] as? String ?? ""
            if ["Movie", "TVSeries", "TVEpisode"].contains(type), let title = object["name"] as? String {
                name = title
                kind = type == "Movie" ? .movie : type == "TVEpisode" ? .episode : .show
                let release = object["datePublished"] ?? object["releaseYear"]
                year = release.flatMap { Int(String(String(describing: $0).prefix(4))) }
                if type == "TVEpisode" {
                    let season = object["partOfSeason"] as? [String: Any]
                    let series = (object["partOfSeries"] as? [String: Any]) ?? (season?["partOfSeries"] as? [String: Any])
                    if let seriesName = series?["name"] as? String {
                        name = seriesName
                        kind = .show
                        let release = series?["datePublished"] ?? series?["releaseYear"]
                        year = release.flatMap { Int(String(String(describing: $0).prefix(4))) }
                    }
                }
            }
            if let graph = object["@graph"] { walk(graph) }
        }
        for script in matches("<script[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>", html) {
            if let data = script.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { walk(json) }
        }
        if name == nil {
            for tag in matches("(<meta\\b[^>]*>)", html) {
                guard matches("(?:property|name)\\s*=\\s*[\"'](og:title)[\"']", tag).isEmpty == false else { continue }
                name = matches("content\\s*=\\s*\"([^\"]*)\"", tag).first ?? matches("content\\s*=\\s*'([^']*)'", tag).first
            }
        }
        guard var clean = AppleHTMLEntities.decoded(name)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        clean = clean.replacingOccurrences(of: "\u{00a0}", with: " ")
        for suffix in ["| Apple TV", "- Apple TV", "| Netflix Official Site", "| Netflix", "• Letterboxd", "- Trakt"] {
            if clean.hasSuffix(suffix) { clean.removeLast(suffix.count) }
        }
        if clean.hasPrefix("Watch ") { clean.removeFirst(6) }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suffix = clean.range(of: #"\s*\((18|19|20|21)[0-9]{2}\)$"#, options: .regularExpression) {
            let digits = clean[suffix].filter(\.isNumber)
            if year == nil { year = Int(digits) }
            clean.removeSubrange(suffix)
        }
        guard !clean.isEmpty, clean.count <= 200,
              !["Netflix", "Apple TV", "Trakt", "Letterboxd"].contains(clean) else { return nil }
        return Title(name: clean, year: year.flatMap { (1870...2200).contains($0) ? $0 : nil }, kind: kind)
    }

    public static func bestMatch(_ title: Title, records: [AppleMediaRecord]) -> AppleMediaRecord? {
        func normalized(_ name: String) -> String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let candidates = records.filter {
            ($0.kind == .movie || $0.kind == .series)
            && normalized($0.title) == normalized(title.name)
            && (title.year == nil || $0.year == title.year)
            && (title.kind == nil || $0.kind == (title.kind == .movie ? .movie : .series))
        }
        let identities = Set(candidates.map { $0.canonicalID ?? $0.id })
        return identities.count == 1 ? candidates.first : nil
    }
    private static func deslug(_ slug: String) -> String { slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized }
    private static func slugTitle(_ slug: String, kind: SharedLink.Kind) -> Title {
        let pieces = slug.split(separator: "-")
        if pieces.count > 1, let last = pieces.last, let year = Int(last), (1870...2200).contains(year) {
            return Title(name: deslug(pieces.dropLast().joined(separator: "-")), year: year, kind: kind)
        }
        return Title(name: deslug(slug), kind: kind)
    }
}
