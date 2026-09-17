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

public struct AppleTMDBDetails: Equatable, Sendable {
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
    public let logoURL: URL?
    public let trailerYouTubeKeys: [String]

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
        trailerYouTubeKeys: [String] = []
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
        self.logoURL = logoURL
        self.trailerYouTubeKeys = ([trailerYouTubeKey].compactMap { $0 } + trailerYouTubeKeys)
            .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
            .reduce(into: []) { keys, key in
                if !keys.contains(key) { keys.append(key) }
            }
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
        case .responseTooLarge: "TMDB returned more metadata than OpenStream can safely process."
        }
    }
}

public enum AppleTrailerPreviewPolicy {
    public static func shouldAutoplay(
        reduceMotion: Bool,
        systemVideoAutoplayEnabled: Bool
    ) -> Bool {
        !reduceMotion && systemVideoAutoplayEnabled
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

    public static func embedURL(for key: String?) -> URL? {
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
            URLQueryItem(name: "showinfo", value: "0"),
            URLQueryItem(name: "vq", value: "hd2160"),
            URLQueryItem(name: "origin", value: "https://openstream.app"),
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
        return AppleWatchProviderResponse.directory(in: envelope)
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
        guard AppleStremioMetadataClient.isIMDBIdentifier(imdb),
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
        guard AppleStremioMetadataClient.isIMDBIdentifier(imdb),
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
            path: mediaKind == .series ? "/3/tv/\(tmdbID)" : "/3/movie/\(tmdbID)",
            queryItems: [
                URLQueryItem(name: "append_to_response", value: "credits,videos,images"),
                URLQueryItem(name: "include_image_language", value: "en,null"),
            ],
            configuration: configuration,
            as: DetailsEnvelope.self
        )
        return Self.details(from: envelope)
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
        let logoPath = value.images?.logos
            .sorted { lhs, rhs in
                let lhsEnglish = lhs.language?.caseInsensitiveCompare("en") == .orderedSame
                let rhsEnglish = rhs.language?.caseInsensitiveCompare("en") == .orderedSame
                if lhsEnglish != rhsEnglish { return lhsEnglish }
                return (lhs.voteAverage ?? 0) > (rhs.voteAverage ?? 0)
            }
            .first?.filePath
        return AppleTMDBDetails(
            runtimeMinutes: runtime.flatMap { (1 ... 24 * 60).contains($0) ? $0 : nil },
            genres: value.genres.prefix(12).compactMap { bounded($0.name, limit: 60) },
            cast: cast,
            director: director,
            tagline: bounded(value.tagline, limit: 300),
            overview: bounded(value.overview, limit: 4_000),
            posterURL: imageURL(path: value.posterPath, width: "w500"),
            backdropURL: imageURL(path: value.backdropPath, width: "w1280"),
            logoURL: imageURL(path: logoPath, width: "w500"),
            trailerYouTubeKeys: trailers
        )
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(limit))
    }

    private static func imageURL(path: String?, width: String) -> URL? {
        guard let path = bounded(path, limit: 300), path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(width)\(path)")
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

    private struct DetailsEnvelope: Decodable, Sendable {
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

        enum CodingKeys: String, CodingKey {
            case runtime, genres, credits, videos, images, tagline, overview
            case episodeRunTime = "episode_run_time"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
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
        }
    }

    private struct NamedValue: Decodable, Sendable { let name: String? }
    private struct Credits: Decodable, Sendable {
        let cast: [NamedValue]
        let crew: [CrewValue]
    }
    private struct CrewValue: Decodable, Sendable { let name: String?; let job: String? }
    private struct Videos: Decodable, Sendable { let results: [Video] }
    private struct Images: Decodable, Sendable { let logos: [Logo] }
    private struct Logo: Decodable, Sendable {
        let filePath: String?
        let language: String?
        let voteAverage: Double?
        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case language = "iso_639_1"
            case voteAverage = "vote_average"
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
        try await credentialSafeSession.data(for: request)
    }
}

public struct AppleMetadataResolver: Sendable {
    private let sourceClient: AppleStremioMetadataClient
    private let tmdbClient: AppleTMDBClient
    private let requestDeadline: Duration
    private let overallDeadline: Duration
    private let defaultSource: AppleSource

    public init(
        sourceClient: AppleStremioMetadataClient = AppleStremioMetadataClient(),
        tmdbClient: AppleTMDBClient = AppleTMDBClient(),
        requestDeadline: Duration = .seconds(1),
        overallDeadline: Duration = .seconds(3),
        defaultSource: AppleSource? = nil
    ) {
        self.sourceClient = sourceClient
        self.tmdbClient = tmdbClient
        self.requestDeadline = max(requestDeadline, .milliseconds(1))
        self.overallDeadline = max(overallDeadline, .milliseconds(1))
        self.defaultSource = defaultSource ?? AppleStremioMetadataClient.defaultMetadataSource
    }

    public func resolve(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        type: String,
        mediaID: String,
        configuration: AppleTMDBConfiguration? = nil
    ) async throws -> AppleTMDBDetails? {
        let cleanID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["movie", "series", "episode"].contains(cleanType), !cleanID.isEmpty else { return nil }

        let clock = ContinuousClock()
        let end = clock.now.advanced(by: overallDeadline)
        var merged: AppleTMDBDetails?
        for source in Self.candidates(
            sources: sources,
            preferredSourceID: preferredSourceID,
            mediaID: cleanID,
            defaultSource: defaultSource
        ) {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: end)
            guard remaining > .zero else { break }
            do {
                let value = try await bounded(timeout: min(requestDeadline, remaining)) {
                    try await sourceClient.details(source: source, type: cleanType, mediaID: cleanID)
                }
                merged = Self.merge(merged, value)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        if let configuration,
           let imdbID = cleanID.split(separator: ":").first.map(String.init),
           AppleStremioMetadataClient.isIMDBIdentifier(imdbID) {
            let remaining = clock.now.duration(to: end)
            if remaining > .zero {
                do {
                    let value = try await bounded(timeout: min(requestDeadline, remaining)) {
                        try await tmdbClient.details(
                            imdbID: imdbID,
                            kind: cleanType == "series" ? .series : .movie,
                            configuration: configuration
                        )
                    }
                    merged = Self.merge(merged, value)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Source metadata remains usable when enrichment fails.
                }
            }
        }
        return merged
    }

    private static func candidates(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID?,
        mediaID: String,
        defaultSource: AppleSource
    ) -> [AppleSource] {
        let eligible = sources.filter { source in
            source.kind == .stremio
                && source.isEnabled
                && source.resources.contains { $0.caseInsensitiveCompare("meta") == .orderedSame }
        }
        var result = eligible.filter { $0.id == preferredSourceID }
            + eligible.filter { $0.id != preferredSourceID }
        let hasDefaultSource = defaultSource.manifestID.map { manifestID in
            result.contains { $0.manifestID == manifestID }
        } ?? false
        if AppleStremioMetadataClient.isIMDBIdentifier(mediaID), !hasDefaultSource {
            result.append(defaultSource)
        }
        return result
    }

    private static func merge(
        _ lhs: AppleTMDBDetails?,
        _ rhs: AppleTMDBDetails
    ) -> AppleTMDBDetails {
        guard let lhs else { return rhs }
        return AppleTMDBDetails(
            mediaID: lhs.mediaID ?? rhs.mediaID,
            mediaType: lhs.mediaType ?? rhs.mediaType,
            title: nonEmpty(lhs.title) ?? nonEmpty(rhs.title),
            releaseInfo: nonEmpty(lhs.releaseInfo) ?? nonEmpty(rhs.releaseInfo),
            runtimeMinutes: lhs.runtimeMinutes ?? rhs.runtimeMinutes,
            contentRating: nonEmpty(lhs.contentRating) ?? nonEmpty(rhs.contentRating),
            formatBadges: lhs.formatBadges.isEmpty ? rhs.formatBadges : lhs.formatBadges,
            genres: lhs.genres.isEmpty ? rhs.genres : lhs.genres,
            cast: lhs.cast.isEmpty ? rhs.cast : lhs.cast,
            director: nonEmpty(lhs.director) ?? nonEmpty(rhs.director),
            tagline: nonEmpty(lhs.tagline) ?? nonEmpty(rhs.tagline),
            overview: nonEmpty(lhs.overview) ?? nonEmpty(rhs.overview),
            posterURL: lhs.posterURL ?? rhs.posterURL,
            backdropURL: lhs.backdropURL ?? rhs.backdropURL,
            logoURL: lhs.logoURL ?? rhs.logoURL,
            trailerYouTubeKeys: lhs.trailerYouTubeKeys + rhs.trailerYouTubeKeys
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private func bounded<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ResolutionTimeout.expired
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private enum ResolutionTimeout: Error {
        case expired
    }
}
