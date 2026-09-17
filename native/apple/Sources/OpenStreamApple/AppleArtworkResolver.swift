import Foundation
import SwiftUI

/// Session-cached poster/backdrop fallback for catalog items whose source
/// add-on (e.g. Cinemeta on newly listed titles) does not return a poster
/// image. Looked up from TMDB by IMDb id when the metadata client is
/// enabled; never used to replace artwork the add-on already provided.
public actor AppleArtworkResolver {
    public struct Artwork: Equatable, Sendable {
        public let posterURL: URL?
        public let backgroundURL: URL?
    }

    public static let shared = AppleArtworkResolver()

    private var cache: [String: Artwork] = [:]
    private let tmdbClient: AppleTMDBClient

    public init(tmdbClient: AppleTMDBClient = AppleTMDBClient()) {
        self.tmdbClient = tmdbClient
    }

    /// Returns TMDB fallback artwork for `mediaID`, or nil when the item
    /// already has a poster, TMDB is disabled, the id isn't an IMDb id, or
    /// the lookup fails. Successful results are cached in-session per id so
    /// a card visible in multiple shelves only triggers one request.
    public func resolve(
        mediaID: String,
        type: String,
        existingPosterURL: URL?,
        existingBackgroundURL: URL? = nil,
        configuration: AppleTMDBConfiguration?
    ) async -> Artwork? {
        guard existingPosterURL == nil else { return nil }
        let key = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached }
        guard let configuration else { return nil }
        let imdbID = String(key.split(separator: ":").first ?? Substring(key))
        guard AppleStremioMetadataClient.isIMDBIdentifier(imdbID) else { return nil }
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind: AppleMediaKind = ["series", "episode"].contains(normalizedType) ? .series : .movie
        guard let details = try? await tmdbClient.details(imdbID: imdbID, kind: kind, configuration: configuration),
              details.posterURL != nil else {
            return nil
        }
        let value = Artwork(
            posterURL: details.posterURL,
            backgroundURL: details.backdropURL ?? existingBackgroundURL
        )
        cache[key] = value
        return value
    }
}

private struct AppleTMDBConfigurationEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppleTMDBConfiguration? = nil
}

extension EnvironmentValues {
    /// The active TMDB configuration (nil when Settings > Metadata is off).
    /// Catalog cards read this to request poster fallback art lazily.
    public var appleTMDBConfiguration: AppleTMDBConfiguration? {
        get { self[AppleTMDBConfigurationEnvironmentKey.self] }
        set { self[AppleTMDBConfigurationEnvironmentKey.self] = newValue }
    }
}
