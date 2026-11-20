import Foundation

/// Upgrades a hero's art to a textless backdrop *after* the hero is already on
/// screen.
///
/// A hero's background normally arrives with the title's metadata, whose
/// backdrop is whatever TMDB ranked first — usually the frame with the
/// film's title painted onto it. Only TMDB knows which frames are textless, so
/// finding out costs a round trip. That round trip is never waited for: the
/// hero draws the art it already has, and swaps to the textless one if and
/// when a better answer turns up (owner 2026-09-20).
///
/// The answer is kept in `AppleMetadataDiskCache` — the cache the metadata
/// layer already uses — so the swap only ever happens on a title's first
/// viewing, and the second launch draws the right art immediately.
actor AppleHeroArtworkUpgrade {
    static let shared = AppleHeroArtworkUpgrade()

    /// What the hero should use instead. Either field may be nil, and both nil
    /// is a perfectly good cached answer meaning "TMDB had nothing better".
    struct Artwork: Codable, Equatable, Sendable {
        let backdropURL: URL?
        let logoURL: URL?
        /// TMDB's textless (`null`-language) poster: the iPhone portrait
        /// hero's first choice (`AppleHeroPortraitArt`).
        var posterURL: URL? = nil
        var titlePage: TitlePageArtwork? = nil
    }

    struct TitlePageArtwork: Codable, Equatable, Sendable {
        let backdropURL: URL?
        let posterURL: URL?
    }

    /// This is our own conclusion, not a provider payload, so it is namespaced
    /// away from the metadata responses that share the cache directory. The
    /// version suffix retires every stored answer if the choice rule changes.
    private static let cacheSource = "openstream://hero-artwork"
    private static let cacheType = "portrait-v4"
    private static let serverWordmarkType = "server-wordmark-v1"

    private let client: AppleTMDBClient
    private let cache: AppleMetadataDiskCache
    /// One fetch per title even when Discover and Library ask at once.
    private var inFlight: [String: Task<Artwork, Never>] = [:]

    init(client: AppleTMDBClient = AppleTMDBClient(), cache: AppleMetadataDiskCache = .shared) {
        self.client = client
        self.cache = cache
    }

    static func upgradeableIMDBID(for item: AppleCatalogItem) -> String? {
        if let imdbID = item.imdbID, !imdbID.contains(":"), AppleMediaIdentifier.isIMDBIdentifier(imdbID) { return imdbID }
        let root = item.mediaID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard AppleMediaIdentifier.isIMDBIdentifier(root) else { return nil }
        return root
    }

    private static func cacheKey(kind: AppleMediaKind, imdbID: String) -> String {
        "\(kind == .series ? "series" : "movie")\u{1f}\(imdbID)"
    }

    private static func cacheKey(for item: AppleCatalogItem) -> String {
        cacheKey(kind: item.type == "series" ? .series : .movie,
            imdbID: upgradeableIMDBID(for: item) ?? "\(item.mediaID)|\(item.name)|\(item.releaseInfo ?? "")")
    }

    private static func tmdbID(for item: AppleCatalogItem) -> String? {
        let parts = item.mediaID.split(separator: ":")
        guard parts.first == "tmdb", let id = parts.last, (Int(id) ?? 0) > 0 else { return nil }
        return String(id)
    }

    private static func serverWordmarkKey(for item: AppleCatalogItem, source: AppleSource, namespace: String) -> String {
        ApplePlaybackIdentity.digest(for: [source.id.uuidString, String(source.configurationRevision), source.url.absoluteString,
            source.mediaServerIdentity ?? "", namespace, item.mediaID, item.name, item.releaseInfo ?? ""].joined(separator: "|"))
    }

    // Stale hero art is preferable to a blank widget while the app refreshes metadata.
    func cachedArtwork(for item: AppleCatalogItem, hasLibraryMetadataMatch: Bool = false,
                       source: AppleSource? = nil, namespace: String? = nil) async -> Artwork? {
        if let source, let namespace,
           AppleMediaServerItemReference.parse(item.mediaID)?.sourceID == source.id,
           let stored = await cache.entry(source: Self.cacheSource, type: Self.serverWordmarkType,
               mediaID: Self.serverWordmarkKey(for: item, source: source, namespace: namespace)),
           let artwork = try? JSONDecoder().decode(Artwork.self, from: stored.payload) {
            return artwork
        }
        guard Self.upgradeableIMDBID(for: item) != nil || Self.tmdbID(for: item) != nil || hasLibraryMetadataMatch else { return nil }
        let key = Self.cacheKey(for: item)
        guard let stored = await cache.entry(source: Self.cacheSource, type: Self.cacheType, mediaID: key) else {
            return nil
        }
        return try? JSONDecoder().decode(Artwork.self, from: stored.payload)
    }

    func rememberServerWordmark(_ url: URL, for item: AppleCatalogItem, source: AppleSource, namespace: String) async {
        guard AppleMediaServerItemReference.parse(item.mediaID)?.sourceID == source.id else { return }
        let artwork = Artwork(backdropURL: item.backgroundURL, logoURL: url)
        guard let data = try? JSONEncoder().encode(artwork) else { return }
        await cache.store(data, source: Self.cacheSource, type: Self.serverWordmarkType,
            mediaID: Self.serverWordmarkKey(for: item, source: source, namespace: namespace))
    }

    func artwork(
        imdbID: String,
        kind: AppleMediaKind,
        configuration: AppleTMDBConfiguration,
        includingTitlePage: Bool = false
    ) async -> Artwork {
        await artwork(for: .init(mediaID: imdbID, type: kind == .series ? "series" : "movie", name: ""),
            configuration: configuration, includingTitlePage: includingTitlePage)
    }

    func artwork(for item: AppleCatalogItem, hasLibraryMetadataMatch: Bool = false, configuration: AppleTMDBConfiguration,
                 includingTitlePage: Bool = false) async -> Artwork {
        guard Self.upgradeableIMDBID(for: item) != nil || Self.tmdbID(for: item) != nil || hasLibraryMetadataMatch else {
            return Artwork(details: nil)
        }
        let key = Self.cacheKey(for: item)
        if let stored = await cache.entry(source: Self.cacheSource, type: Self.cacheType, mediaID: key),
           stored.freshness == .fresh,
           let value = try? JSONDecoder().decode(Artwork.self, from: stored.payload),
           !includingTitlePage || value.titlePage != nil {
            return value
        }
        // Registered before the first suspension point, so a second caller
        // arriving mid-fetch joins this task instead of starting its own.
        if let running = inFlight[key] { return await running.value }
        let task = Task { [client, cache] () -> Artwork in
            let kind: AppleMediaKind = item.type == "series" ? .series : .movie
            let value: Artwork
            if let imdbID = Self.upgradeableIMDBID(for: item) {
                value = Artwork(details: try? await client.details(imdbID: imdbID, kind: kind, configuration: configuration))
            } else {
                let parsed = AppleLibraryTitle(title: item.name, year: item.year ?? item.releaseInfo.flatMap { Int($0.prefix(4)) },
                    season: nil, episode: nil, kind: kind == .series ? .show : .movie)
                let match: AppleCatalogItem?
                if let id = Self.tmdbID(for: item) {
                    match = try? await client.libraryDetails(provider: "tmdb", id: id, kind: parsed.kind,
                        configuration: configuration)
                } else {
                    match = try? await client.librarySearch(parsed, configuration: configuration)
                }
                if let match, match.logoURL == nil, let imdbID = Self.upgradeableIMDBID(for: match) {
                    let details = try? await client.details(imdbID: imdbID, kind: kind, configuration: configuration)
                    value = Artwork(backdropURL: details?.textlessBackdropURL, logoURL: details?.logoURL ?? match.logoURL,
                        posterURL: details?.textlessPosterURL,
                        titlePage: .init(backdropURL: details?.textlessBackdropURL, posterURL: details?.posterURL ?? match.posterURL))
                } else {
                    value = Artwork(backdropURL: nil, logoURL: match?.logoURL,
                        titlePage: .init(backdropURL: nil, posterURL: match?.posterURL))
                }
            }
            // A failed lookup is still worth remembering for a day: the cost
            // of asking again on every visit is paid by the viewer.
            if let payload = try? JSONEncoder().encode(value) {
                await cache.store(payload, source: Self.cacheSource, type: Self.cacheType, mediaID: key)
            }
            return value
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}

extension AppleHeroArtworkUpgrade.Artwork {
    init(details: AppleTMDBDetails?) {
        self.init(backdropURL: details?.textlessBackdropURL, logoURL: details?.logoURL,
            posterURL: details?.textlessPosterURL,
            titlePage: .init(backdropURL: details?.textlessBackdropURL,
                posterURL: details?.posterURL))
    }
}
