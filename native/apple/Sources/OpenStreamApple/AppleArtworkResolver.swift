import Foundation
import SwiftUI

/// Bounded, session-only artwork lookup. Source URLs remain untouched.
public actor AppleArtworkResolver {
    public enum Purpose: String, Sendable, Hashable {
        case poster, resume, hero, logo

        /// The TMDB widths this purpose requests.
        var widths: [Int] {
            switch self {
            case .poster: [92, 154, 185, 342, 500, 780]
            case .resume, .hero: [300, 780, 1280]
            case .logo: [45, 92, 154, 185, 300, 500]
            }
        }

        public func size(pixelWidth: Double) -> String {
            let sizes = widths
            let width = pixelWidth.isFinite ? max(1, pixelWidth) : 1
            let selected = sizes.last { Double($0) <= width } ?? sizes[0]
            return "w\(selected)"
        }
    }

    public struct Artwork: Equatable, Sendable {
        public let posterURL: URL?
        public let backgroundURL: URL?
        public let logoURL: URL?

        public init(posterURL: URL?, backgroundURL: URL?, logoURL: URL? = nil) {
            self.posterURL = posterURL
            self.backgroundURL = backgroundURL
            self.logoURL = logoURL
        }
    }

    private struct Key: Hashable {
        let title: String
        let kind: String
        let purpose: Purpose
        let size: String
        let configuration: String
    }

    public static let shared = AppleArtworkResolver()
    private var cache: [Key: Artwork] = [:]
    private var misses: Set<Key> = []
    private var inFlight: [Key: Task<Artwork?, Never>] = [:]
    private var activeLookups = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var lookups = 0
    private let tmdbClient: AppleTMDBClient
    private let maximumLookups: Int
    private let maximumConcurrentLookups: Int

    public init(tmdbClient: AppleTMDBClient = AppleTMDBClient(), maximumLookups: Int = 512,
                maximumConcurrentLookups: Int = 8) {
        self.tmdbClient = tmdbClient
        self.maximumLookups = max(1, maximumLookups)
        self.maximumConcurrentLookups = max(1, maximumConcurrentLookups)
    }

    private func acquireSlot() async {
        if activeLookups < maximumConcurrentLookups {
            activeLookups += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func releaseSlot() {
        if waiting.isEmpty { activeLookups -= 1 }
        else { waiting.removeFirst().resume() }
    }

    public func resolve(
        mediaID: String,
        type: String,
        existingPosterURL: URL?,
        existingBackgroundURL: URL? = nil,
        existingLogoURL: URL? = nil,
        purpose: Purpose = .poster,
        pixelWidth: Double? = nil,
        configuration: AppleTMDBConfiguration?
    ) async -> Artwork? {
        // Check settings before the cache as well: metadata-off must never
        // expose a previously cached lookup or start new requests.
        guard let configuration, !Task.isCancelled else { return nil }
        switch purpose {
        case .poster: guard existingPosterURL == nil else { return nil }
        case .resume, .hero: guard existingBackgroundURL == nil else { return nil }
        case .logo: guard existingLogoURL == nil else { return nil }
        }
        let id = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        let imdbID = String(id.split(separator: ":").first ?? "")
        guard AppleMediaIdentifier.isIMDBIdentifier(imdbID) else { return nil }
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let series = ["series", "episode"].contains(normalizedType)
        let size = pixelWidth.map { purpose.size(pixelWidth: $0) }
            ?? (purpose == .poster || purpose == .logo ? "w500" : "w1280")
        let key = Key(title: imdbID, kind: series ? "series" : "movie", purpose: purpose,
                      size: size, configuration: configuration.credential)
        let fallback: Artwork?
        if let cached = cache[key] {
            fallback = cached
        } else if misses.contains(key) {
            return nil
        } else if let pending = inFlight[key] {
            fallback = await pending.value
        } else {
            guard lookups < maximumLookups else { return nil }
            lookups += 1
            let client = tmdbClient
            // Shared work belongs to the resolver, not the first visible card.
            // One disappearing card must not cancel the other waiters.
            let task = Task {
                await self.acquireSlot()
                let details = try? await client.details(imdbID: imdbID,
                    kind: series ? .series : .movie, configuration: configuration)
                self.releaseSlot()
                guard let details else { return nil as Artwork? }
                let posterSize = purpose == .poster ? size : "w500"
                let backdropSize = purpose == .resume || purpose == .hero ? size : "w1280"
                let value = Artwork(
                    posterURL: AppleTMDBClient.resizedArtworkURL(details.posterURL, size: posterSize),
                    backgroundURL: AppleTMDBClient.resizedArtworkURL(details.backdropURL, size: backdropSize),
                    logoURL: AppleTMDBClient.resizedArtworkURL(details.logoURL, size: purpose == .logo ? size : "w500"))
                guard value.posterURL != nil || value.backgroundURL != nil || value.logoURL != nil else { return nil }
                return value
            }
            inFlight[key] = task
            fallback = await task.value
            inFlight[key] = nil
            if let fallback { cache[key] = fallback } else { misses.insert(key) }
        }
        guard let fallback, !Task.isCancelled else { return nil }
        // Do not put a caller's supplied URLs in the shared fallback cache.
        return Artwork(posterURL: existingPosterURL ?? fallback.posterURL,
                       backgroundURL: existingBackgroundURL ?? fallback.backgroundURL,
                       logoURL: existingLogoURL ?? fallback.logoURL)
    }
}

extension EnvironmentValues {
    /// The active TMDB configuration (nil when Settings > Metadata is off).
    /// Catalog cards read this to request poster fallback art lazily.
    @Entry public var appleTMDBConfiguration: AppleTMDBConfiguration? = nil
}

extension AppleSettingsStore {
    /// The TMDB configuration every artwork lookup uses, nil when Settings >
    /// Metadata is off or there is no key. One definition, so Discover and
    /// Library ask TMDB for a missing poster in the same way: Library had no
    /// configuration at all, and drew grey title tiles for the titles
    /// Discover's Your Library row showed posters for (owner, 2026-09-24).
    var tmdbConfiguration: AppleTMDBConfiguration? {
        guard metadataEnabled else { return nil }
        return try? AppleTMDBConfiguration(credential: tmdbAPIKey)
    }

    /// The Top 10 rows are TMDB's charts: with no configuration the toggle
    /// is off limits and Discover draws none.
    var top10ListsAvailable: Bool { tmdbConfiguration != nil }

    /// The TMDB configuration for a shared link, which can arrive before the
    /// Keychain gives the key (a launch before first unlock): an unreadable
    /// key is read again, a few times a second apart. Nil at once when the
    /// key is simply not set.
    func loadedTMDBConfiguration(attempts: Int = 4, interval: Duration = .seconds(1)) async -> AppleTMDBConfiguration? {
        for attempt in 1...max(attempts, 1) {
            if let tmdbConfiguration { return tmdbConfiguration }
            guard retryUnreadableSecrets(), attempt < attempts else { break }
            try? await Task.sleep(for: interval)
        }
        return tmdbConfiguration
    }
}
