import Foundation

/// Upgrades a hero's art to a textless backdrop *after* the hero is already on
/// screen.
///
/// A hero's background normally arrives from a Stremio meta add-on, whose
/// `background` is whatever TMDB ranked first — usually the frame with the
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
    }

    /// This is our own conclusion, not a provider payload, so it is namespaced
    /// away from the add-on responses that share the cache directory. The
    /// version suffix retires every stored answer if the choice rule changes.
    private static let cacheSource = "openstream://hero-artwork"
    private static let cacheType = "portrait-v1"

    private let client: AppleTMDBClient
    private let cache: AppleMetadataDiskCache
    /// One fetch per title even when Discover and Library ask at once.
    private var inFlight: [String: Task<Artwork, Never>] = [:]

    init(client: AppleTMDBClient = AppleTMDBClient(), cache: AppleMetadataDiskCache = .shared) {
        self.client = client
        self.cache = cache
    }

    /// The IMDB id a hero can be upgraded through, or nothing.
    ///
    /// Library and catalog items carry media ids in several shapes —
    /// `tt0119698`, `tt0944947:1:2`, `tmdb:12345`, `local-<digest>`. Only a
    /// plain IMDB id resolves on TMDB, so everything else is left alone.
    static func upgradeableIMDBID(for item: AppleCatalogItem) -> String? {
        let root = item.mediaID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard AppleStremioMetadataClient.isIMDBIdentifier(root) else { return nil }
        return root
    }

    /// `artwork`, but answering nil once `deadline` has passed: the iPhone
    /// hero picks its art before it draws and will not wait longer than
    /// this for TMDB. The lookup carries on, so its answer is cached for
    /// the next visit.
    func artwork(
        imdbID: String,
        kind: AppleMediaKind,
        configuration: AppleTMDBConfiguration,
        deadline: Duration
    ) async -> Artwork? {
        let lookup = Task { await self.artwork(imdbID: imdbID, kind: kind, configuration: configuration) }
        // A race, not a task group: a group would wait for the lookup it
        // lost to before returning, which is the wait this exists to cap.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Artwork?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await lookup.value) }
            Task {
                try? await Task.sleep(for: deadline)
                once.resume(nil)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Artwork?, Never>?
        init(_ continuation: CheckedContinuation<Artwork?, Never>) { self.continuation = continuation }
        func resume(_ value: Artwork?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    func artwork(
        imdbID: String,
        kind: AppleMediaKind,
        configuration: AppleTMDBConfiguration
    ) async -> Artwork {
        let key = "\(kind == .series ? "series" : "movie")\u{1f}\(imdbID)"
        if let stored = await cache.entry(source: Self.cacheSource, type: Self.cacheType, mediaID: key),
           stored.freshness == .fresh,
           let value = try? JSONDecoder().decode(Artwork.self, from: stored.payload) {
            return value
        }
        // Registered before the first suspension point, so a second caller
        // arriving mid-fetch joins this task instead of starting its own.
        if let running = inFlight[key] { return await running.value }
        let task = Task { [client, cache] () -> Artwork in
            let details = try? await client.details(imdbID: imdbID, kind: kind, configuration: configuration)
            // `textlessBackdropURL`, not `backdropURL`: replacing one
            // title-in-the-picture backdrop with another buys the viewer a
            // reload of the hero and nothing else.
            let value = Artwork(backdropURL: details?.textlessBackdropURL, logoURL: details?.logoURL,
                                posterURL: details?.textlessPosterURL)
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
