import Foundation

public struct AppleTMDBConfiguration: Equatable, Sendable {
    public let credential: String

    public init(credential: String) throws {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 2_048,
              !value.contains("\r"),
              !value.contains("\n") else {
            throw AppleTMDBError.invalidCredential
        }
        self.credential = value
    }

    fileprivate var bearerToken: String? {
        credential.hasPrefix("eyJ") ? credential : nil
    }
}

public struct AppleTMDBDetails: Equatable, Sendable, Codable {
    public let mediaID: String?
    public let mediaType: String?
    public let title: String?
    public let releaseInfo: String?
    public let runtimeMinutes: Int?
    public let contentRating: String?
    public let formatBadges: [String]
    public let genres: [String]
    public let cast: [String]
    public let director: String?
    public let writers: [String]
    public let imdbRating: Double?
    public let year: Int?
    public let tagline: String?
    public let overview: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    /// The backdrop with no title burned into it, when the record has one.
    ///
    /// `backdropURL` already prefers this, so most callers need only that one.
    /// A hero that has usable art from somewhere else needs to know whether
    /// TMDB actually found something *better*, and swapping one
    /// title-in-the-picture backdrop for another is not better.
    public let textlessBackdropURL: URL?
    /// The poster with no title burned into it (`iso_639_1 == null`), for the
    /// iPhone's portrait hero (`AppleHeroPortraitArt`). Nil when TMDB has none.
    public let textlessPosterURL: URL?
    public let logoURL: URL?
    /// The catalog's backdrop and logo when a media server's own came first.
    /// A hero tries them when the server's fail to load: Rill can list a
    /// logo or backdrop its image proxy then answers with a 502.
    public let catalogBackdropURL: URL?
    public let catalogLogoURL: URL?
    public let trailerYouTubeKeys: [String]
    /// Cast and crew with their roles and portraits, when the source has them
    /// (TMDB). `cast` stays the plain name list the similarity ranking uses.
    public let castMembers: [AppleCreditPerson]
    /// Where the title comes from, as display names ("United Kingdom").
    public let countries: [String]
    /// The original language's code or name ("en"), and the spoken ones.
    public let originalLanguage: String?
    public let spokenLanguages: [String]

    public var trailerYouTubeKey: String? { trailerYouTubeKeys.first }

    public init(
        mediaID: String? = nil,
        mediaType: String? = nil,
        title: String? = nil,
        releaseInfo: String? = nil,
        runtimeMinutes: Int? = nil,
        contentRating: String? = nil,
        formatBadges: [String] = [],
        genres: [String] = [],
        cast: [String] = [],
        director: String? = nil,
        writers: [String] = [],
        imdbRating: Double? = nil,
        year: Int? = nil,
        tagline: String? = nil,
        overview: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        logoURL: URL? = nil,
        trailerYouTubeKey: String? = nil,
        trailerYouTubeKeys: [String] = [],
        textlessBackdropURL: URL? = nil,
        castMembers: [AppleCreditPerson] = [],
        countries: [String] = [],
        originalLanguage: String? = nil,
        spokenLanguages: [String] = [],
        textlessPosterURL: URL? = nil,
        catalogBackdropURL: URL? = nil,
        catalogLogoURL: URL? = nil
    ) {
        self.mediaID = mediaID
        self.mediaType = mediaType
        self.title = AppleHTMLEntities.decoded(title)
        self.releaseInfo = releaseInfo
        self.runtimeMinutes = runtimeMinutes
        self.contentRating = contentRating
        self.formatBadges = formatBadges
        self.genres = genres
        self.cast = cast
        self.director = director
        self.writers = writers
        self.imdbRating = imdbRating.flatMap { $0.isFinite && (0 ... 10).contains($0) ? $0 : nil }
        self.year = year.flatMap { (1_870 ... 2_200).contains($0) ? $0 : nil }
        self.tagline = AppleHTMLEntities.decoded(tagline)
        self.overview = AppleHTMLEntities.decoded(overview)
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.textlessBackdropURL = textlessBackdropURL
        self.textlessPosterURL = textlessPosterURL
        self.catalogBackdropURL = catalogBackdropURL
        self.catalogLogoURL = catalogLogoURL
        self.logoURL = logoURL
        self.trailerYouTubeKeys = ([trailerYouTubeKey].compactMap { $0 } + trailerYouTubeKeys)
            .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
            .reduce(into: []) { keys, key in
                if !keys.contains(key) { keys.append(key) }
            }
        self.castMembers = Array(castMembers.filter { !$0.name.isEmpty }.prefix(30))
        self.countries = Self.bounded(countries, limit: 12)
        let language = originalLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.originalLanguage = language.isEmpty ? nil : String(language.prefix(60))
        self.spokenLanguages = Self.bounded(spokenLanguages, limit: 30)
    }

    private static func bounded(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return values.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(limit).map { $0 }
    }
}

public enum AppleTMDBError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredential
    case invalidIdentifier
    case titleNotFound
    case invalidResponse
    case requestFailed(Int)
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "The TMDB API credential is missing or invalid."
        case .invalidIdentifier: "This title does not have a valid IMDB identifier."
        case .titleNotFound: "TMDB could not find this title."
        case .invalidResponse: "TMDB returned an invalid response."
        case .requestFailed(let status): "TMDB returned HTTP \(status)."
        case .responseTooLarge: "TMDB returned more metadata than oStream can safely process."
        }
    }
}

public enum AppleTrailerPreviewPolicy {
    public static func shouldAutoplay(
        reduceMotion: Bool,
        systemVideoAutoplayEnabled: Bool,
        lowPowerMode: Bool = false
    ) -> Bool {
        !reduceMotion && systemVideoAutoplayEnabled && !lowPowerMode
    }

    /// The devices a title page's hero trailer can autoplay on.
    public enum TitlePageDevice: Sendable {
        case phoneOrPad, vision, mac, tv
    }

    /// Whether a title page's hero trailer plays by itself: with Autoplay
    /// Trailers on and Reduce Motion off, as each Discover hero does. The
    /// iPhone and iPad also honour the system's video autoplay setting; the
    /// Mac autoplays like its Discover hero (N69, owner 2026-09-25); the
    /// Apple TV plays no trailer at all.
    public static func titlePageAutoplays(
        on device: TitlePageDevice,
        setting: Bool,
        reduceMotion: Bool,
        systemVideoAutoplayEnabled: Bool = true,
        lowPowerMode: Bool = false
    ) -> Bool {
        guard setting, shouldAutoplay(reduceMotion: reduceMotion,
            systemVideoAutoplayEnabled: systemVideoAutoplayEnabled, lowPowerMode: lowPowerMode) else { return false }
        switch device {
        case .phoneOrPad: return systemVideoAutoplayEnabled
        case .vision, .mac: return true
        case .tv: return false
        }
    }

    public static func validYouTubeKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6 ... 24).contains(clean.count),
              clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return clean
    }

    public static func watchURL(for key: String?) -> URL? {
        guard let key = validYouTubeKey(key),
              var components = URLComponents(string: "https://www.youtube.com/watch") else { return nil }
        components.queryItems = [URLQueryItem(name: "v", value: key)]
        return components.url
    }

    public static func thumbnailURL(for key: String?) -> URL? {
        guard let key = validYouTubeKey(key) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(key)/hqdefault.jpg")
    }

    /// YouTube's quality names, highest first, with the picture height each
    /// one is.
    public static let qualityLadder: [(name: String, height: Int)] = [
        ("hd2160", 2_160), ("hd1440", 1_440), ("hd1080", 1_080), ("hd720", 720), ("large", 480), ("medium", 360),
    ]

    /// The highest quality whose picture is no taller than the frame it fills,
    /// in device pixels: a 680 pt Mac hero on a Retina screen is 1,360 px tall,
    /// which asks for 1080p rather than a 4K stream it would scale down.
    public static func quality(forPixelHeight height: Double) -> String {
        qualityLadder.first { Double($0.height) <= height }?.name ?? "medium"
    }

    /// How many times its size the Mac lays the YouTube player out, then
    /// scales it back down. YouTube picks its stream from the player's size
    /// in CSS pixels times the screen's pixel ratio and treats `vq` as a
    /// hint: a 1,440 pt hero on a 1x display played 720p (N27). A Retina
    /// screen already doubles it; doubling again would only fetch 4K.
    public static func macLayoutScale(displayScale: Double) -> Int {
        displayScale < 2 ? 2 : 1
    }

    // YouTube requires https://<bundle-id> as the WebView referrer: https://developers.google.com/youtube/terms/required-minimum-functionality#api-client-identity-and-credentials
    static let embedOrigin = URL(string: "https://" + hostBundleIdentifier(Bundle.main.bundleIdentifier))!

    static func hostBundleIdentifier(_ bundleIdentifier: String?) -> String {
        let identifier = (bundleIdentifier ?? "com.orgista.openstream").lowercased()
        for suffix in [".share", ".widgets", ".topshelf", ".messages"] where identifier.hasSuffix(suffix) {
            return String(identifier.dropLast(suffix.count))
        }
        return identifier
    }

    public static func embedURL(for key: String?, quality: String = "hd2160") -> URL? {
        guard let key = validYouTubeKey(key),
              var components = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(key)") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "mute", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "controls", value: "0"),
            URLQueryItem(name: "disablekb", value: "1"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "fs", value: "0"),
            URLQueryItem(name: "vq", value: quality),
            URLQueryItem(name: "origin", value: embedOrigin.absoluteString),
        ]
        return components.url
    }

    public static func frameProbeURL(for key: String?) -> URL? {
        guard let key = validYouTubeKey(key) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(key)/frame0.jpg")
    }

    public static func isPortraitFrame(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return size.height > size.width
    }

    public static func firstPlayableCandidate(
        _ keys: [String],
        portraitKeys: Set<String>,
        startingAt index: Int
    ) -> Int? {
        guard index >= 0, index < keys.count else { return nil }
        for candidateIndex in index ..< keys.count {
            if !portraitKeys.contains(keys[candidateIndex]) {
                return candidateIndex
            }
        }
        return nil
    }
}

public struct AppleTMDBClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private static let maximumResponseBytes = 2_000_000
    private static let credentialSafeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    private let loader: Loader

    public init(loader: @escaping Loader = AppleTMDBClient.liveLoader) {
        self.loader = loader
    }

    /// Every streaming service operating in `region`, for the settings screen.
    ///
    /// Only the subscription directory is requested: the viewer is picking
    /// services they *subscribe to*, and a rental storefront is not something
    /// to subscribe to.
    public func availableWatchProviders(
        region: String,
        configuration: AppleTMDBConfiguration
    ) async throws -> [AppleWatchProvider] {
        let envelope = try await load(
            path: "/3/watch/providers/movie",
            queryItems: [URLQueryItem(name: "watch_region", value: region.uppercased())],
            configuration: configuration,
            as: AppleWatchProviderResponse.DirectoryEnvelope.self
        )
        return AppleWatchProviderResponse.directory(in: envelope, region: region)
    }

    /// Where a title can be watched in `region`, as TMDB reports it.
    ///
    /// Returns **everything** including rent and buy;
    /// `AppleWatchProviderPolicy.visible(_:enabledProviderIDs:)` is the single
    /// place that decides what a viewer actually sees, so the purchase
    /// exclusion stays one tested rule rather than being scattered.
    ///
    /// `region` is required, not defaulted: availability genuinely differs by
    /// country, and the wrong country's answer is worse than none.
    public func watchProviders(
        imdbID: String,
        kind: AppleMediaKind,
        region: String,
        configuration: AppleTMDBConfiguration
    ) async throws -> [AppleWatchProvider] {
        let imdb = imdbID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppleMediaIdentifier.isIMDBIdentifier(imdb),
              !imdb.contains(":") else { throw AppleTMDBError.invalidIdentifier }

        let find = try await load(
            path: "/3/find/\(imdb)",
            queryItems: [URLQueryItem(name: "external_source", value: "imdb_id")],
            configuration: configuration,
            as: FindEnvelope.self
        )
        let mediaKind = kind == .series || kind == .episode ? AppleMediaKind.series : .movie
        let tmdbID = mediaKind == .series ? find.tvResults.first?.id : find.movieResults.first?.id
        guard let tmdbID, tmdbID > 0 else { throw AppleTMDBError.titleNotFound }

        let envelope = try await load(
            path: mediaKind == .series
                ? "/3/tv/\(tmdbID)/watch/providers"
                : "/3/movie/\(tmdbID)/watch/providers",
            queryItems: [],
            configuration: configuration,
            as: AppleWatchProviderResponse.Envelope.self
        )
        return AppleWatchProviderResponse.providers(in: envelope, region: region)
    }

    public func details(
        imdbID: String,
        kind: AppleMediaKind,
        configuration: AppleTMDBConfiguration
    ) async throws -> AppleTMDBDetails {
        let imdb = imdbID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppleMediaIdentifier.isIMDBIdentifier(imdb),
              !imdb.contains(":") else { throw AppleTMDBError.invalidIdentifier }

        let find = try await load(
            path: "/3/find/\(imdb)",
            queryItems: [URLQueryItem(name: "external_source", value: "imdb_id")],
            configuration: configuration,
            as: FindEnvelope.self
        )
        let mediaKind = kind == .series || kind == .episode ? AppleMediaKind.series : .movie
        let tmdbID = mediaKind == .series ? find.tvResults.first?.id : find.movieResults.first?.id
        guard let tmdbID, tmdbID > 0 else { throw AppleTMDBError.titleNotFound }

        return try await details(tmdbID: tmdbID, kind: mediaKind, configuration: configuration, relationSeed: imdb)
    }

    func details(tmdbID: Int, kind: AppleMediaKind, configuration: AppleTMDBConfiguration,
                 relationSeed: String? = nil) async throws -> AppleTMDBDetails {
        guard tmdbID > 0 else { throw AppleTMDBError.invalidIdentifier }
        let mediaKind: AppleMediaKind = kind == .series || kind == .episode ? .series : .movie
        let envelope = try await load(
            path: mediaKind == .series ? "/3/tv/\(tmdbID)" : "/3/movie/\(tmdbID)",
            queryItems: [
                // Apple TV uses direct server trailers; its TMDB lookup supplies artwork.
                URLQueryItem(name: "append_to_response",
                             value: AppleTitlePagePolicy.offersTrailers() ? "credits,videos,images,recommendations,similar" : "credits,images,recommendations,similar"),
                URLQueryItem(name: "include_image_language", value: "en,null"),
            ],
            configuration: configuration,
            as: DetailsEnvelope.self
        )
        let type = mediaKind == .series ? "series" : "movie"
        let targets = [(envelope.recommendations, AppleTMDBRelation.Origin.recommendation),
                       (envelope.similar, AppleTMDBRelation.Origin.similar)].flatMap { list, origin in
            (list?.results ?? []).prefix(20).compactMap { value -> AppleTMDBRelation.Target? in
                guard value.id > 0 else { return nil }
                let title = String((value.title ?? value.name ?? "").prefix(300))
                let date = value.releaseDate ?? value.firstAirDate ?? ""
                let year = Int(date.prefix(4)).flatMap { (1870...2200).contains($0) ? $0 : nil }
                return AppleTMDBRelation.Target(id: value.id, type: type, title: title, year: year, origin: origin)
            }
        }
        if let relationSeed {
            await AppleTMDBRelationCache.shared.store(AppleTMDBRelation(seedID: relationSeed, type: type,
                targets: targets, storedAt: .now), configuration: configuration)
        }
        return Self.details(from: envelope)
    }

    /// `details(imdbID:)` through the metadata disk cache, per credential,
    /// title and kind: a fresh answer comes from disk, a stale one stands in
    /// when TMDB cannot be reached. The title page's Cast & Crew for a
    /// media-server title reads it, so a title seen before draws its credits
    /// without waiting on either the server or TMDB.
    func cachedDetails(imdbID: String, kind: AppleMediaKind, configuration: AppleTMDBConfiguration,
                       cache: AppleMetadataDiskCache = .shared) async throws -> AppleTMDBDetails {
        let source = AppleLibraryMetadataResolver.configurationDigest(configuration.credential, "")
        let key = "\(imdbID):\(kind == .series || kind == .episode ? "series" : "movie")"
        let cached = await cache.entry(source: source, type: "tmdb-details", mediaID: key)
        let saved = cached.flatMap { try? JSONDecoder().decode(AppleTMDBDetails.self, from: $0.payload) }
        if cached?.freshness == .fresh, let saved { return saved }
        do {
            let fetched = try await details(imdbID: imdbID, kind: kind, configuration: configuration)
            await cache.store(try JSONEncoder().encode(fetched), source: source, type: "tmdb-details", mediaID: key)
            return fetched
        } catch {
            try Task.checkCancellation()
            if let saved { return saved }
            throw error
        }
    }

    /// A matched series' episode metadata, cached per credential, title and season.
    func seasonEpisodes(mediaID: String, season: Int, configuration: AppleTMDBConfiguration,
                        cache: AppleMetadataDiskCache = .shared) async throws -> [AppleMediaEpisode] {
        let parts = mediaID.split(separator: ":", omittingEmptySubsequences: false)
        let directID = parts.count == 3 && parts[0] == "tmdb" && parts[1] == "tv" ? Int(parts[2]) : nil
        guard season >= 0,
              (AppleMediaIdentifier.isIMDBIdentifier(mediaID) && !mediaID.contains(":")) || (directID ?? 0) > 0 else {
            throw AppleTMDBError.invalidIdentifier
        }
        try Task.checkCancellation()
        let source = AppleLibraryMetadataResolver.configurationDigest(configuration.credential, "")
        let key = "\(mediaID):\(season)"
        let cached = await cache.entry(source: source, type: "tmdb-season", mediaID: key)
        let saved = cached.flatMap { try? JSONDecoder().decode([AppleMediaEpisode].self, from: $0.payload) }
        if cached?.freshness == .fresh, let saved, !saved.isEmpty { return saved }
        do {
            let seriesID: Int
            if let directID {
                seriesID = directID
            } else {
                let found = try await load(path: "/3/find/\(mediaID)",
                    queryItems: [.init(name: "external_source", value: "imdb_id")],
                    configuration: configuration, as: FindEnvelope.self)
                guard let id = found.tvResults.first?.id, id > 0 else { throw AppleTMDBError.titleNotFound }
                seriesID = id
            }
            let response = try await load(path: "/3/tv/\(seriesID)/season/\(season)", queryItems: [],
                configuration: configuration, as: SeasonEnvelope.self)
            try Task.checkCancellation()
            var seen = Set<Int>()
            let episodes = response.episodes.compactMap { value -> AppleMediaEpisode? in
                guard value.seasonNumber == season, value.episodeNumber > 0,
                      seen.insert(value.episodeNumber).inserted else { return nil }
                return AppleMediaEpisode(id: "\(mediaID):\(season):\(value.episodeNumber)", title: value.name ?? "",
                    season: season, episode: value.episodeNumber, releaseInfo: value.airDate,
                    runtimeMinutes: value.runtime, overview: value.overview,
                    thumbnailURL: Self.imageURL(path: value.stillPath, width: "w780"))
            }
            if !episodes.isEmpty {
                await cache.store(try JSONEncoder().encode(episodes), source: source, type: "tmdb-season", mediaID: key)
            }
            return episodes
        } catch {
            try Task.checkCancellation()
            if let saved { return saved }
            throw error
        }
    }

    /// Shared links use the same credential-safe TMDB transport as title metadata.
    public func sharedLinkSearch(title: AppleSharedLinkResolver.Title,
                                 configuration: AppleTMDBConfiguration) async throws -> [AppleCatalogItem] {
        let kinds: [SharedLink.Kind] = title.kind.map { [$0 == .movie ? .movie : .show] } ?? [.movie, .show]
        var items: [AppleCatalogItem] = []
        for kind in kinds {
            let result = try await load(path: "/3/search/\(kind == .movie ? "movie" : "tv")",
                                        queryItems: [.init(name: "query", value: title.name)],
                                        configuration: configuration, as: SharedSearchEnvelope.self)
            items += result.results.compactMap { $0.item(kind: kind) }
        }
        return items
    }

    public func sharedLinkDetails(id: Int, kind: SharedLink.Kind,
                                  configuration: AppleTMDBConfiguration) async throws -> AppleCatalogItem {
        guard id > 0 else { throw AppleTMDBError.invalidIdentifier }
        let value = try await load(path: "/3/\(kind == .movie ? "movie" : "tv")/\(id)",
                                   queryItems: [.init(name: "append_to_response", value: "external_ids,images"),
                                                .init(name: "include_image_language", value: "en,null")],
                                   configuration: configuration, as: SharedTitleEnvelope.self)
        guard let item = value.item(kind: kind) else { throw AppleTMDBError.titleNotFound }
        return item
    }

    public func sharedLinkDetails(imdbID: String,
                                  configuration: AppleTMDBConfiguration) async throws -> AppleCatalogItem {
        guard AppleMediaIdentifier.isIMDBIdentifier(imdbID) else { throw AppleTMDBError.invalidIdentifier }
        let find = try await load(path: "/3/find/\(imdbID)",
                                  queryItems: [.init(name: "external_source", value: "imdb_id")],
                                  configuration: configuration, as: FindEnvelope.self)
        if let id = find.movieResults.first?.id {
            return try await sharedLinkDetails(id: id, kind: .movie, configuration: configuration)
        }
        if let id = find.tvResults.first?.id {
            return try await sharedLinkDetails(id: id, kind: .show, configuration: configuration)
        }
        throw AppleTMDBError.titleNotFound
    }

    /// Resolve the declared media kind; never take a movie result for a series ID.
    func libraryDetails(provider: String, id: String, kind: AppleLibraryTitle.Kind,
                        configuration: AppleTMDBConfiguration) async throws -> AppleCatalogItem {
        let mediaKind: SharedLink.Kind = kind == .show ? .show : .movie
        if provider == "tmdb" {
            guard let number = Int(id), number > 0 else { throw AppleTMDBError.invalidIdentifier }
            return try await sharedLinkDetails(id: number, kind: mediaKind, configuration: configuration)
        }
        guard provider == "imdb" || provider == "tvdb",
              provider == "imdb" ? AppleMediaIdentifier.isIMDBIdentifier(id) : (Int(id) ?? 0) > 0 else {
            throw AppleTMDBError.invalidIdentifier
        }
        let find = try await load(path: "/3/find/\(id)",
                                  queryItems: [.init(name: "external_source", value: provider + "_id")],
                                  configuration: configuration, as: FindEnvelope.self)
        let results = kind == .show ? find.tvResults : find.movieResults
        guard results.count == 1, let match = results.first else { throw AppleTMDBError.titleNotFound }
        return try await sharedLinkDetails(id: match.id, kind: mediaKind, configuration: configuration)
    }

    /// A dated title searches with TMDB's year filter first (a generic name
    /// such as "Home" or "Heat" may not reach page one without it), then once
    /// without it for release years that are off by one.
    func librarySearch(_ parsed: AppleLibraryTitle, configuration: AppleTMDBConfiguration,
                       onPoster: (@Sendable (AppleLibraryMetadataResolver.Poster) async -> Void)? = nil) async throws -> AppleCatalogItem? {
        let kind: SharedLink.Kind = parsed.kind == .show ? .show : .movie
        let years: [Int?] = parsed.year.map { [$0, nil] } ?? [nil]
        let titles = [parsed.title] + (AppleLibraryMetadataResolver.unprefixedTitle(parsed).map { [$0] } ?? [])
        for title in titles {
            for year in years {
                var queryItems = [URLQueryItem(name: "query", value: title)]
                if let year {
                    queryItems.append(.init(name: kind == .show ? "first_air_date_year" : "year", value: String(year)))
                }
                let result = try await load(path: "/3/search/\(kind == .show ? "tv" : "movie")",
                                            queryItems: queryItems,
                                            configuration: configuration, as: SharedSearchEnvelope.self)
                let items = result.results.compactMap { $0.item(kind: kind) }
                var aliases: [String: [String]] = [:]
                for value in result.results {
                    if let item = value.item(kind: kind) {
                        aliases[item.mediaID] = [value.originalTitle, value.originalName].compactMap { $0 }
                    }
                }
                guard let match = AppleLibraryMetadataResolver.bestMatch(items, parsed: parsed, aliases: aliases),
                      let record = result.results.first(where: { $0.item(kind: kind)?.mediaID == match.mediaID }) else { continue }
                if let poster = match.posterURL { await onPoster?(.init(url: poster, mediaID: match.mediaID)) }
                let value = try await sharedLinkDetails(id: record.id, kind: kind, configuration: configuration)
                // Details can replace the search's TMDB id with its IMDb id.
                if let poster = match.posterURL { await onPoster?(.init(url: poster, mediaID: value.mediaID)) }
                return value
            }
        }
        return nil
    }

    /// TMDB's ten trending titles of the week for `type` ("all", "movie" or
    /// "series"), in chart order, each with its full details (external ids,
    /// art); a title whose details fail keeps the chart's own entry.
    func weeklyTop10(type: String, configuration: AppleTMDBConfiguration) async throws -> [AppleCatalogItem] {
        let kind: SharedLink.Kind = type == "movie" ? .movie : .show
        let chartType = type == "all" ? "all" : (kind == .movie ? "movie" : "tv")
        let chart = try await load(path: "/3/trending/\(chartType)/week", queryItems: [],
                                   configuration: configuration, as: SharedSearchEnvelope.self)
        let entries = Array(chart.results.filter { type != "all" || ["movie", "tv"].contains($0.mediaType ?? "") }.prefix(10))
        return await withTaskGroup(of: (Int, AppleCatalogItem?).self) { group in
            for (rank, entry) in entries.enumerated() {
                let entryKind: SharedLink.Kind = type == "all" ? (entry.mediaType == "movie" ? .movie : .show) : kind
                group.addTask {
                    let details = try? await sharedLinkDetails(id: entry.id, kind: entryKind, configuration: configuration)
                    return (rank, details ?? entry.item(kind: entryKind))
                }
            }
            var ranked = [AppleCatalogItem?](repeating: nil, count: entries.count)
            for await (rank, item) in group { ranked[rank] = item }
            return ranked.compactMap { $0 }
        }
    }

    private struct SharedSearchEnvelope: Decodable, Sendable { let results: [SharedTitleEnvelope] }
    private struct SharedTitleEnvelope: Decodable, Sendable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let overview: String?
        let genres: [NamedValue]?
        let imdbID: String?
        let externalIDs: ExternalIDs?
        let originalTitle: String?
        let originalName: String?
        let voteCount: Int?
        let images: Images?
        struct ExternalIDs: Decodable, Sendable {
            let imdbID: String?
            enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
        }
        enum CodingKeys: String, CodingKey {
            case id, title, name, overview, images, genres
            case mediaType = "media_type"
            case releaseDate = "release_date", firstAirDate = "first_air_date"
            case posterPath = "poster_path", backdropPath = "backdrop_path"
            case imdbID = "imdb_id", externalIDs = "external_ids"
            case originalTitle = "original_title", originalName = "original_name"
            case voteCount = "vote_count"
        }
        func item(kind: SharedLink.Kind) -> AppleCatalogItem? {
            guard id > 0, let title = title ?? name, !title.isEmpty else { return nil }
            let imdb = imdbID ?? externalIDs?.imdbID
            let artwork = AppleTextlessBackdropPolicy.choose(backdrops: images?.backdrops.map(\.artworkImage) ?? [],
                backdropPath: backdropPath, posterPath: nil)
            let background: String?
            if case .textlessBackdrop(let path)? = artwork { background = path }
            else { background = backdropPath }
            return AppleCatalogItem(mediaID: imdb ?? "tmdb:\(kind == .movie ? "movie" : "tv"):\(id)",
                                    type: kind == .movie ? "movie" : "series", name: title,
                                    posterURL: AppleTMDBClient.imageURL(path: posterPath, width: "w500"),
                                    backgroundURL: AppleTMDBClient.imageURL(path: background, width: "w1280"),
                                    summary: overview,
                                    releaseInfo: releaseDate ?? firstAirDate,
                                    genres: genres?.prefix(12).compactMap { AppleTMDBClient.bounded($0.name, limit: 60) },
                                    year: (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) },
                                    logoURL: AppleTMDBClient.imageURL(path: AppleTMDBClient.logoPath(in: images), width: "w500"),
                                    voteCount: voteCount)
        }
    }

    private func load<Value: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem],
        configuration: AppleTMDBConfiguration,
        as type: Value.Type
    ) async throws -> Value {
        guard var components = URLComponents(string: "https://api.themoviedb.org") else {
            throw AppleTMDBError.invalidResponse
        }
        components.path = path
        components.queryItems = queryItems + (configuration.bearerToken == nil
            ? [URLQueryItem(name: "api_key", value: configuration.credential)]
            : [])
        guard let url = components.url else { throw AppleTMDBError.invalidResponse }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        if let bearer = configuration.bearerToken {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumResponseBytes else { throw AppleTMDBError.responseTooLarge }
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https",
              http.url?.host == "api.themoviedb.org" else { throw AppleTMDBError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AppleTMDBError.requestFailed(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw AppleTMDBError.invalidResponse
        }
        return value
    }

    private static func details(from value: DetailsEnvelope) -> AppleTMDBDetails {
        let trailers = value.videos?.results
            .compactMap { video -> (String, Int)? in
                guard video.site.caseInsensitiveCompare("YouTube") == .orderedSame,
                      ["Trailer", "Teaser"].contains(video.type),
                      let key = AppleTrailerPreviewPolicy.validYouTubeKey(video.key) else { return nil }
                let score = (video.type == "Trailer" ? 200 : 100)
                    + (video.official ? 40 : 0)
                    + (video.language?.caseInsensitiveCompare("en") == .orderedSame ? 20 : 0)
                    + (video.country?.caseInsensitiveCompare("US") == .orderedSame ? 5 : 0)
                return (key, score)
            }
            .sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0 < rhs.0 }
            .map(\.0) ?? []
        let runtime = value.runtime ?? value.episodeRunTime?.first
        let cast = value.credits?.cast.prefix(10).compactMap { bounded($0.name, limit: 100) } ?? []
        let director = value.credits?.crew.first { $0.job == "Director" }
            .flatMap { bounded($0.name, limit: 100) }
        // Actors with their characters, then the creators (a series) or the
        // director (a film), each with a portrait when TMDB has one.
        let actors = (value.credits?.cast ?? []).prefix(15).compactMap { member -> AppleCreditPerson? in
            guard let name = bounded(member.name, limit: 100) else { return nil }
            return AppleCreditPerson(name: name, role: bounded(member.character, limit: 100),
                                     portraitURL: imageURL(path: member.profilePath, width: AppleCreditPerson.tmdbPortraitSize))
        }
        let creators = (value.createdBy ?? []).prefix(4).compactMap { member -> AppleCreditPerson? in
            guard let name = bounded(member.name, limit: 100) else { return nil }
            return AppleCreditPerson(name: name, role: "Creator",
                                     portraitURL: imageURL(path: member.profilePath, width: AppleCreditPerson.tmdbPortraitSize))
        }
        let directors = (value.credits?.crew ?? []).filter { $0.job == "Director" }.prefix(2)
            .compactMap { member -> AppleCreditPerson? in
                guard let name = bounded(member.name, limit: 100) else { return nil }
                return AppleCreditPerson(name: name, role: "Director",
                                         portraitURL: imageURL(path: member.profilePath, width: AppleCreditPerson.tmdbPortraitSize))
            }
        let countryCodes = (value.originCountry ?? []) + (value.productionCountries ?? []).compactMap(\.code)
        let countries = countryCodes.compactMap { AppleTitlePagePolicy.regionName($0) }
        let spoken = (value.spokenLanguages ?? []).compactMap { language in
            AppleTitlePagePolicy.languageName(language.code) ?? bounded(language.englishName, limit: 60)
        }
        let logoPath = logoPath(in: value.images)
        // The hero draws the wordmark itself, so it wants the frame without
        // one painted on. `include_image_language=en,null` already brings the
        // textless entries back in the same request this response came from —
        // choosing between them costs nothing (owner 2026-09-20).
        let heroArtwork = AppleTextlessBackdropPolicy.choose(
            backdrops: (value.images?.backdrops ?? []).map(\.artworkImage),
            backdropPath: value.backdropPath,
            posterPath: value.posterPath
        )
        // A poster answer leaves `backdropURL` nil on purpose: `posterURL`
        // already carries it, and a hero that falls back to a poster must not
        // draw a wordmark over art that already says the name.
        let backdropPath = (heroArtwork?.isBackdrop ?? false) ? heroArtwork?.path : nil
        let textlessPath: String? = {
            guard case .textlessBackdrop(let path)? = heroArtwork else { return nil }
            return path
        }()
        return AppleTMDBDetails(
            runtimeMinutes: runtime.flatMap { (1 ... 24 * 60).contains($0) ? $0 : nil },
            genres: value.genres.prefix(12).compactMap { bounded($0.name, limit: 60) },
            cast: cast,
            director: director,
            tagline: bounded(value.tagline, limit: 300),
            overview: bounded(value.overview, limit: 4_000),
            posterURL: imageURL(path: value.posterPath, width: "w500"),
            backdropURL: imageURL(path: backdropPath, width: "w1280"),
            logoURL: imageURL(path: logoPath, width: "w500"),
            trailerYouTubeKeys: trailers,
            textlessBackdropURL: imageURL(path: textlessPath, width: "w1280"),
            castMembers: actors + creators + directors,
            countries: countries,
            originalLanguage: AppleTitlePagePolicy.languageName(value.originalLanguage),
            spokenLanguages: spoken,
            textlessPosterURL: imageURL(path: AppleTextlessBackdropPolicy.textlessPoster(
                (value.images?.posters ?? []).map(\.artworkImage)), width: "w780")
        )
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(limit))
    }

    /// Resize only TMDB's unsigned image URLs produced by this client.
    /// Provider URLs, including signed URLs and query strings, stay exact.
    static func isResizableArtworkURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "image.tmdb.org",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count >= 4 && parts[0] == "t" && parts[1] == "p"
            && (parts[2] == "original" || (parts[2].first == "w" && Int(parts[2].dropFirst()) != nil))
    }

    static func resizedArtworkURL(_ url: URL?, size: String) -> URL? {
        guard let url, isResizableArtworkURL(url) else { return url }
        let parts = url.path.split(separator: "/")
        return imageURL(path: "/" + parts.dropFirst(3).joined(separator: "/"), width: size)
    }

    private static func logoPath(in images: Images?) -> String? {
        images?.logos
            .filter { $0.filePath?.lowercased().hasSuffix(".svg") != true }
            .sorted { lhs, rhs in
                let lhsEnglish = lhs.language?.caseInsensitiveCompare("en") == .orderedSame
                let rhsEnglish = rhs.language?.caseInsensitiveCompare("en") == .orderedSame
                if lhsEnglish != rhsEnglish { return lhsEnglish }
                return (lhs.voteAverage ?? 0) > (rhs.voteAverage ?? 0)
            }
            .first?.filePath
    }

    private static func imageURL(path: String?, width: String) -> URL? {
        guard let path = bounded(path, limit: 300), path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(width)\(path)")
    }

    private struct SeasonEnvelope: Decodable, Sendable {
        let episodes: [Episode]
        struct Episode: Decodable, Sendable {
            let name: String?
            let seasonNumber: Int
            let episodeNumber: Int
            let airDate: String?
            let runtime: Int?
            let overview: String?
            let stillPath: String?
            enum CodingKeys: String, CodingKey {
                case name, runtime, overview
                case seasonNumber = "season_number", episodeNumber = "episode_number"
                case airDate = "air_date", stillPath = "still_path"
            }
        }
    }

    private struct FindEnvelope: Decodable, Sendable {
        let movieResults: [FindResult]
        let tvResults: [FindResult]
        enum CodingKeys: String, CodingKey {
            case movieResults = "movie_results"
            case tvResults = "tv_results"
        }
    }

    private struct FindResult: Decodable, Sendable { let id: Int }

    private struct RelationsEnvelope: Decodable, Sendable {
        let results: [RelationResult]
    }
    private struct RelationResult: Decodable, Sendable {
        let id: Int
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        enum CodingKeys: String, CodingKey {
            case id, title, name
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
        }
    }

    private struct DetailsEnvelope: Decodable, Sendable {
        let recommendations: RelationsEnvelope?
        let similar: RelationsEnvelope?
        let runtime: Int?
        let episodeRunTime: [Int]?
        let genres: [NamedValue]
        let credits: Credits?
        let videos: Videos?
        let images: Images?
        let tagline: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let createdBy: [PersonValue]?
        let originCountry: [String]?
        let productionCountries: [CountryValue]?
        let spokenLanguages: [LanguageValue]?
        let originalLanguage: String?

        enum CodingKeys: String, CodingKey {
            case runtime, genres, credits, videos, images, tagline, overview, recommendations, similar
            case episodeRunTime = "episode_run_time"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case createdBy = "created_by"
            case originCountry = "origin_country"
            case productionCountries = "production_countries"
            case spokenLanguages = "spoken_languages"
            case originalLanguage = "original_language"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recommendations = try? container.decode(RelationsEnvelope.self, forKey: .recommendations)
            similar = try? container.decode(RelationsEnvelope.self, forKey: .similar)
            runtime = try? container.decode(Int.self, forKey: .runtime)
            episodeRunTime = try? container.decode([Int].self, forKey: .episodeRunTime)
            genres = (try? container.decode([NamedValue].self, forKey: .genres)) ?? []
            credits = try? container.decode(Credits.self, forKey: .credits)
            videos = try? container.decode(Videos.self, forKey: .videos)
            images = try? container.decode(Images.self, forKey: .images)
            tagline = try? container.decode(String.self, forKey: .tagline)
            overview = try? container.decode(String.self, forKey: .overview)
            posterPath = try? container.decode(String.self, forKey: .posterPath)
            backdropPath = try? container.decode(String.self, forKey: .backdropPath)
            createdBy = try? container.decode([PersonValue].self, forKey: .createdBy)
            originCountry = try? container.decode([String].self, forKey: .originCountry)
            productionCountries = try? container.decode([CountryValue].self, forKey: .productionCountries)
            spokenLanguages = try? container.decode([LanguageValue].self, forKey: .spokenLanguages)
            originalLanguage = try? container.decode(String.self, forKey: .originalLanguage)
        }
    }

    private struct NamedValue: Decodable, Sendable { let name: String? }
    private struct Credits: Decodable, Sendable {
        let cast: [CastValue]
        let crew: [CrewValue]
    }
    private struct CastValue: Decodable, Sendable {
        let name: String?
        let character: String?
        let profilePath: String?
        enum CodingKeys: String, CodingKey {
            case name, character
            case profilePath = "profile_path"
        }
    }
    private struct CrewValue: Decodable, Sendable {
        let name: String?
        let job: String?
        let profilePath: String?
        enum CodingKeys: String, CodingKey {
            case name, job
            case profilePath = "profile_path"
        }
    }
    private struct PersonValue: Decodable, Sendable {
        let name: String?
        let profilePath: String?
        enum CodingKeys: String, CodingKey {
            case name
            case profilePath = "profile_path"
        }
    }
    private struct CountryValue: Decodable, Sendable {
        let code: String?
        enum CodingKeys: String, CodingKey { case code = "iso_3166_1" }
    }
    private struct LanguageValue: Decodable, Sendable {
        let code: String?
        let englishName: String?
        enum CodingKeys: String, CodingKey {
            case code = "iso_639_1"
            case englishName = "english_name"
        }
    }
    private struct Videos: Decodable, Sendable { let results: [Video] }

    /// Both lists default to empty rather than being required. `images` is
    /// decoded with `try?`, so a record that has logos but no backdrops (or
    /// the other way round) used to throw the whole block away and take the
    /// wordmark with it.
    private struct Images: Decodable, Sendable {
        let logos: [ImageEntry]
        let backdrops: [ImageEntry]
        let posters: [ImageEntry]

        enum CodingKeys: String, CodingKey { case logos, backdrops, posters }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            logos = (try? container.decode([ImageEntry].self, forKey: .logos)) ?? []
            backdrops = (try? container.decode([ImageEntry].self, forKey: .backdrops)) ?? []
            posters = (try? container.decode([ImageEntry].self, forKey: .posters)) ?? []
        }
    }

    private struct ImageEntry: Decodable, Sendable {
        let filePath: String?
        let language: String?
        let voteAverage: Double?
        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case language = "iso_639_1"
            case voteAverage = "vote_average"
        }

        var artworkImage: AppleArtworkImage {
            AppleArtworkImage(filePath: filePath, languageCode: language, voteAverage: voteAverage)
        }
    }
    private struct Video: Decodable, Sendable {
        let key: String?
        let site: String
        let type: String
        let official: Bool
        let language: String?
        let country: String?
        enum CodingKeys: String, CodingKey {
            case key, site, type, official
            case language = "iso_639_1"
            case country = "iso_3166_1"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try? container.decode(String.self, forKey: .key)
            site = (try? container.decode(String.self, forKey: .site)) ?? ""
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            official = (try? container.decode(Bool.self, forKey: .official)) ?? false
            language = try? container.decode(String.self, forKey: .language)
            country = try? container.decode(String.self, forKey: .country)
        }
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if DEBUG
        if let root = AppleNetworkStub.root {
            return try AppleNetworkStub.response(for: request, root: root)
        }
        #endif
        return try await credentialSafeSession.data(for: request)
    }
}

public struct AppleMetadataResolver: Sendable {
    private let tmdbClient: AppleTMDBClient
    public init(tmdbClient: AppleTMDBClient = AppleTMDBClient()) { self.tmdbClient = tmdbClient }
    public func resolve(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        type: String,
        mediaID: String,
        configuration: AppleTMDBConfiguration? = nil,
        fallbackName: String? = nil,
        onUpdate: (@Sendable (AppleTMDBDetails) async -> Void)? = nil
    ) async throws -> AppleTMDBDetails? {
        guard let configuration else { return nil }
        let id = mediaID.split(separator: ":").first.map(String.init) ?? mediaID
        guard AppleMediaIdentifier.isIMDBIdentifier(id) else { return nil }
        let details = try await tmdbClient.details(imdbID: id, kind: type == "series" ? .series : .movie, configuration: configuration)
        try Task.checkCancellation()
        if let onUpdate { await onUpdate(details) }
        return details
    }
}
