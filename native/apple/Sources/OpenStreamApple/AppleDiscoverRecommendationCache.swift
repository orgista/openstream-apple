import Foundation

/// A prepared Discover answer in the existing metadata cache, revalidated after first paint.
enum AppleDiscoverRecommendationCache {
    struct Key: Equatable, Sendable {
        let scope: String
        let fingerprint: String
    }

    struct WatchState: Codable, Sendable {
        var progress: [String: ApplePlaybackProgress] = [:]
        var activity: [String: ApplePlaybackProgress] = [:]
        var completed: [String: Date] = [:]
        var unwatched: [String: Date] = [:]
        var removed: [String: Date] = [:]
        var ratings: [String: Int] = [:]
    }

    private struct Fingerprint: Encodable {
        let state: WatchState
        let day: Int
    }

    private struct Item: Codable {
        let record: AppleMediaRecord
        let item: AppleCatalogItem
        let sourceID: UUID
        let updatedAt: Date?
        let continueWatchingInfo: AppleContinueWatchingTileInfo?
        let progressKeys: [String]?

        init(_ value: AppleDiscoverView.IndexedCatalogItem) {
            record = value.record
            item = value.item
            sourceID = value.source.id
            updatedAt = value.continueWatchingUpdatedAt
            continueWatchingInfo = value.continueWatchingInfo
            progressKeys = value.progressKeys
        }

        func resolve(sources: [UUID: AppleSource], favoriteIDs: Set<String>) -> AppleDiscoverView.IndexedCatalogItem? {
            guard let source = sources[sourceID] else { return nil }
            var restoredRecord = record
            restoredRecord.isFavorite = favoriteIDs.contains(record.id)
            return .init(record: restoredRecord, item: item, source: source, continueWatchingUpdatedAt: updatedAt,
                         continueWatchingInfo: continueWatchingInfo, progressKeys: progressKeys ?? [])
        }
    }

    private struct SeedRow: Codable {
        let heading: String
        let items: [Item]
        let minimumCount: Int
    }

    private struct Answer: Codable {
        let fingerprint: String
        let favoriteIDs: Set<String>
        let continueWatching: [Item]
        let heroes: [Item]
        let seedRows: [SeedRow]
        let featuredMovies: [Item]
        let featuredShows: [Item]
    }

    /// Matched titles with artwork are eligible for recommendations.
    static let entryType = "discover-v9"

    static func scope(sourceIdentity: String, namespace: String, metadataConfiguration: AppleTMDBConfiguration?,
                      top10ListsEnabled: Bool, heroTitle: String) -> String {
        [sourceIdentity, AppleSourceKind.allCases.map(\.rawValue).joined(separator: ";"), namespace,
         AppleCatalogArtworkPolicy.configurationMarker(metadataConfiguration), "top10:\(top10ListsEnabled)",
         heroTitle].joined(separator: "|")
    }

    nonisolated static func key(scope: String, state: WatchState, now: Date = .now) -> Key? {
        let fingerprint = Fingerprint(state: state, day: AppleRecommendationRowScorer.day(now))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(fingerprint) else { return nil }
        return Key(scope: ApplePlaybackIdentity.digest(for: scope),
            fingerprint: ApplePlaybackIdentity.digest(for: String(decoding: data, as: UTF8.self)))
    }

    @concurrent nonisolated static func restore(_ key: Key, sources: [AppleSource],
                                               cache: AppleMetadataDiskCache = .shared) async -> AppleDiscoverView.RecommendationResult? {
        guard let entry = await cache.entry(source: key.scope, type: entryType, mediaID: "recommendations"),
              entry.freshness == .fresh,
              let answer = try? JSONDecoder().decode(Answer.self, from: entry.payload),
              answer.fingerprint == key.fingerprint, !answer.heroes.isEmpty else { return nil }
        var enabled = Dictionary(sources.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !enabled.isEmpty, let metadata = answer.heroes.first(where: { $0.sourceID == AppleMediaAvailability.metadataOnlyInstanceID }) {
            enabled[metadata.sourceID] = AppleCatalogSearchMatch.metadataOnly(metadata.item).source
        }
        let values = answer.continueWatching + answer.heroes + answer.seedRows.flatMap(\.items)
            + answer.featuredMovies + answer.featuredShows
        guard values.allSatisfy({ enabled[$0.sourceID] != nil }) else { return nil }
        let continuing = answer.continueWatching.compactMap { $0.resolve(sources: enabled, favoriteIDs: answer.favoriteIDs) }
        return .init(continueWatching: AppleContinueWatchingResolver.merge([], incoming: continuing,
                id: { $0.id }, timestamp: { $0.continueWatchingUpdatedAt ?? .distantPast }),
            heroes: answer.heroes.compactMap { $0.resolve(sources: enabled, favoriteIDs: answer.favoriteIDs) },
            seedRows: answer.seedRows.map { row in
                .init(heading: row.heading, items: row.items.compactMap { $0.resolve(sources: enabled, favoriteIDs: answer.favoriteIDs) },
                    minimumCount: row.minimumCount)
            },
            featuredMovies: answer.featuredMovies.compactMap { $0.resolve(sources: enabled, favoriteIDs: answer.favoriteIDs) },
            featuredShows: answer.featuredShows.compactMap { $0.resolve(sources: enabled, favoriteIDs: answer.favoriteIDs) })
    }

    @concurrent nonisolated static func store(_ result: AppleDiscoverView.RecommendationResult, key: Key,
                                             favoriteIDs: Set<String>,
                                             cache: AppleMetadataDiskCache = .shared) async {
        guard !result.heroes.isEmpty else { return }
        let answer = Answer(fingerprint: key.fingerprint, favoriteIDs: favoriteIDs, continueWatching: result.continueWatching.map(Item.init),
            heroes: result.heroes.map(Item.init),
            seedRows: result.seedRows.map { SeedRow(heading: $0.heading, items: $0.items.map(Item.init), minimumCount: $0.minimumCount) },
            featuredMovies: result.featuredMovies.map(Item.init), featuredShows: result.featuredShows.map(Item.init))
        guard let data = try? JSONEncoder().encode(answer) else { return }
        await cache.store(data, source: key.scope, type: entryType, mediaID: "recommendations")
    }
}
