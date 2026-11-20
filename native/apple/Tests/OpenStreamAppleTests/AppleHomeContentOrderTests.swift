import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Home content and order")
struct AppleHomeContentOrderTests {
    private static let scanned = Date(timeIntervalSince1970: 1_900_000_000)
    private static let day: TimeInterval = 86_400

    private static func file(_ name: String, source: UUID, added: Date = scanned, modified: Date? = nil) -> AppleLibraryItem {
        AppleLibraryItem(sourceID: source, name: name, url: URL(fileURLWithPath: "/fixture/\(name)"), relativePath: name,
                         sizeBytes: 1, addedAt: added, modifiedAt: modified)
    }

    // MARK: Recently Added

    @MainActor
    @Test func oneScanStampOrdersByTheSharesChangeDateNotByName() {
        let source = UUID()
        let groups = AppleLibrarySeries.groups([
            Self.file("Alpha.2020.mkv", source: source, modified: Self.scanned.addingTimeInterval(-30 * Self.day)),
            Self.file("Beta.2021.mkv", source: source, modified: Self.scanned.addingTimeInterval(-1 * Self.day)),
            Self.file("Gamma.2022.mkv", source: source, modified: Self.scanned.addingTimeInterval(-9 * Self.day)),
            Self.file("Delta.2019.mkv", source: source),
        ])
        let store = AppleLocalLibraryStore(groups: groups)
        #expect(store.sorted(.defaultSort).map(\.parsed.title) == ["Beta", "Gamma", "Alpha", "Delta"])
        #expect(store.sorted(.title).map(\.parsed.title) == ["Alpha", "Beta", "Delta", "Gamma"])
    }

    @MainActor
    @Test func aLaterArrivalLeadsWhateverItsChangeDate() {
        let source = UUID()
        let groups = AppleLibrarySeries.groups([
            Self.file("Alpha.2020.mkv", source: source, modified: Self.scanned),
            Self.file("Zulu.2020.mkv", source: source, added: Self.scanned.addingTimeInterval(Self.day),
                      modified: Self.scanned.addingTimeInterval(-400 * Self.day)),
        ])
        #expect(AppleLocalLibraryStore(groups: groups).sorted(.added).map(\.parsed.title) == ["Zulu", "Alpha"])
    }

    @Test func aLaterCopyKeepsItsDiscoveryDateForFreshness() async throws {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let old = Self.scanned.addingTimeInterval(-400 * Self.day)
        let group = try #require(AppleLibrarySeries.groups([
            Self.file("Zulu.2020.mkv", source: source.id, modified: old),
        ]).first)
        let item = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Zulu",
            posterURL: URL(string: "https://fixture.example/poster.jpg"), genres: ["Drama"])
        let input = AppleLocalLibraryStore.CatalogSnapshot(groups: [group], metadata: [group.id: item],
            sources: [source], offlineIDs: [:])
        let result = try await AppleDiscoverView.libraryRecommendationItems(input)
        #expect(result.ranked.first?.addedAt == Self.scanned)
        #expect(AppleRecommendationRanker.freshness(addedAt: result.ranked.first?.addedAt, now: Self.scanned) == 0.3)
    }

    @Test func aSharesFirstScanIsDatedByChangeDateAndLaterFilesByDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in nil }
        let source = UUID()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let first = try await resolver.datedItems([Self.file("Alpha.mkv", source: source, added: .distantPast, modified: old)],
                                            sourceID: source)
        #expect(first.first?.addedAt == old)
        let before = Date()
        let second = try await resolver.datedItems([
            Self.file("Alpha.mkv", source: source, added: .distantPast, modified: old),
            Self.file("Beta.mkv", source: source, added: .distantPast, modified: old),
        ], sourceID: source)
        #expect(second.first?.addedAt == old)
        #expect((second.last?.addedAt ?? .distantPast) >= before)
    }

    @MainActor @Test func recentlyAddedMergesLocalAndServerTitlesNewestFirst() {
        let local = AppleSource(kind: .library, name: "Local", url: URL(fileURLWithPath: "/fixture/local"))
        let server = AppleSource(kind: .mediaServer, name: "Server", url: URL(fileURLWithPath: "/fixture/server"))
        func value(_ id: String, source: AppleSource, at: TimeInterval?) -> AppleDiscoverView.IndexedCatalogItem {
            let item = AppleCatalogItem(mediaID: id, type: "movie", name: id)
            return .init(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item,
                         source: source, addedAt: at.map { Self.scanned.addingTimeInterval($0) })
        }
        let rows = AppleDiscoverView.recentlyAdded(local: [value("old", source: local, at: -20),
            value("new", source: local, at: 0)], server: [value("middle", source: server, at: -10),
            value("undated", source: server, at: nil)])
        #expect(rows.map { $0.item.mediaID } == ["new", "middle", "old", "undated"])
    }

    @MainActor @Test func recentlyAddedPreparationIsReusedUntilItsInputsChange() {
        let source = AppleSource(kind: .library, name: "Local", url: URL(fileURLWithPath: "/fixture/local"))
        let items = (0..<2_048).map { index in
            let item = AppleCatalogItem(mediaID: "local-\(index)", type: "movie", name: "Local Title \(index)", year: 2024)
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                item: item, source: source, addedAt: Self.scanned.addingTimeInterval(Double(index)))
        }
        let cache = AppleDiscoverView.RecentlyAddedCache()
        var preparations = 0
        func prepare(_ values: [AppleDiscoverView.IndexedCatalogItem]) -> [AppleDiscoverView.IndexedCatalogItem] {
            preparations += 1
            return AppleDiscoverView.recentlyAdded(local: values, server: [])
        }
        let first = cache.values(libraryRevision: 1, sources: [source]) { prepare(items) }
        for _ in 0..<20 {
            let reused = cache.values(libraryRevision: 1, sources: [source]) { prepare([]) }
            #expect(reused.map(\.id) == first.map(\.id))
        }
        #expect(first.first?.item.mediaID == "local-2047")
        #expect(preparations == 1)
        let changed = cache.values(libraryRevision: 2, sources: [source]) { prepare(Array(items.prefix(6))) }
        #expect(changed.count == 6)
        #expect(preparations == 2)
        cache.invalidate()
        let refreshed = cache.values(libraryRevision: 2, sources: [source]) { prepare(items) }
        #expect(refreshed.count == items.count)
        #expect(preparations == 3)
        var disabled = source
        disabled.isEnabled = false
        #expect(cache.values(libraryRevision: 2, sources: [disabled]) { prepare([]) }.isEmpty)
        #expect(preparations == 4)
    }

    @MainActor @Test func chartAndOwnedCatalogItemsShareClaimsAcrossRows() throws {
        let local = AppleSource(kind: .library, name: "Local", url: URL(fileURLWithPath: "/fixture/local"))
        let server = AppleSource(kind: .mediaServer, name: "Server", url: try #require(URL(string: "https://fixture.example")))
        let movies = [("Heat", 1995, "tt0113277", 949), ("Arrival", 2016, "tt2543164", 329865),
                      ("Alien", 1979, "tt0078748", 348), ("The Matrix", 1999, "tt0133093", 603),
                      ("Dune", 2021, "tt1160419", 438631), ("Blade Runner", 1982, "tt0083658", 78),
                      ("The Godfather", 1972, "tt0068646", 238), ("Interstellar", 2014, "tt0816692", 157336),
                      ("Inception", 2010, "tt1375666", 27205), ("Spirited Away", 2001, "tt0245429", 129)]
        let chart = movies.map { name, year, _, tmdb in
            AppleCatalogItem(mediaID: "tmdb:movie:\(tmdb)", type: "movie", name: name, year: year)
        }
        let owned = movies.enumerated().map { index, movie in
            let source = index.isMultiple(of: 2) ? local : server
            let mediaID = source.kind == .mediaServer
                ? AppleMediaServerItemReference(sourceID: source.id, itemID: movie.2).mediaID : movie.2
            let item = AppleCatalogItem(mediaID: mediaID, type: "movie", name: movie.0, year: movie.1, imdbID: movie.2)
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                item: item, source: source)
        }
        let later = [("Casablanca", 1942), ("Vertigo", 1958), ("Moonlight", 2016),
                     ("Parasite", 2019), ("WALL-E", 2008), ("Jaws", 1975)].map { name, year in
            AppleCatalogItem(mediaID: name, type: "movie", name: name, year: year)
        }
        let chartKeys = chart.map(AppleDiscoverView.rowIdentity)
        let ownedKeys = owned.map { value in
            #expect(AppleDiscoverView.rowIdentity(value.item) == AppleRecommendationRowScorer.displayIdentity(value.item, source: value.source))
            return AppleDiscoverView.rowIdentity(value.item)
        }
        #expect(chartKeys == ownedKeys)
        let laterKeys = later.map(AppleDiscoverView.rowIdentity)
        let rows = AppleDiscoverView.displayedRowIDs([.continueWatching, .top10, .library, .popularMovies],
            keys: [[ownedKeys[0]], chartKeys, ownedKeys + laterKeys, ownedKeys + laterKeys], seedMinimumCounts: [])
        #expect(rows == [[ownedKeys[0]], chartKeys, laterKeys, []])
        #expect(rows[1].count == 10)
    }

    @MainActor @Test func rowIdentityIgnoresSourcesEvenWithoutAReleaseYear() throws {
        let source = AppleSource(kind: .mediaServer, name: "Server", url: try #require(URL(string: "https://fixture.example")))
        let items = [AppleCatalogItem(mediaID: "tt0113277", type: "movie", name: "Heat"),
                     AppleCatalogItem(mediaID: "tmdb:series:1396", type: "series", name: "Breaking Bad"),
                     AppleCatalogItem(mediaID: "home-video", type: "movie", name: "Family Video")]
        for item in items {
            #expect(AppleDiscoverView.rowIdentity(item) == AppleRecommendationRowScorer.displayIdentity(item, source: source))
        }
    }

    @Test func recentAndContinueWatchingInputsDoNotReserveFeaturedTitles() async throws {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let values = (0..<8).map { index in
            let item = AppleCatalogItem(mediaID: "fixture-\(index)", type: "movie", name: "Fixture \(index)",
                posterURL: URL(string: "https://fixture.example/poster.jpg"), year: 2024)
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                item: item, source: source)
        }
        let snapshot = AppleDiscoverView.RecommendationSnapshot(relations: [], sources: [source], records: [], progress: [:],
            activity: [:], completed: [:], unwatched: [:], removed: [:], ratings: [:], serverContinueWatching: [values[0]],
            serverShelves: [], artwork: [:], debugHeroTitle: nil, now: Self.scanned, libraryItems: values)
        let result = try await AppleDiscoverView.buildRecommendations(snapshot)
        #expect(Set(result.featuredMovies.map { $0.item.mediaID }) == Set(values.map { $0.item.mediaID }))
    }

    @MainActor @Test func homeRowsKeepTheFixedOrderAndHideSparseRows() {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let values = (0..<10).map { index in
            let item = AppleCatalogItem(mediaID: "fixture-\(index)", type: "movie", name: "Fixture \(index)")
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
        }
        var result = AppleDiscoverView.RecommendationResult(featuredMovies: Array(values.prefix(6)), featuredShows: Array(values.prefix(6)))
        result.seedRows = [.init(heading: "Because You Watched Fixture", items: Array(values.prefix(8))),
                           .init(heading: "Because You Watched Other", items: values)]
        let chart = AppleTop10Store.Chart(items: values.map(\.item), fetchedAt: Self.scanned)
        #expect(AppleDiscoverView.discoverRails(continueWatching: [values[0]], hasLibrary: true, recommendations: result,
            top10: chart, serverShelfIDs: ["latest", "top"]) == [.continueWatching, .top10, .featuredMovies, .library,
                .featuredShows, .becauseWatched(0), .mediaServer("latest"), .mediaServer("top")])
        result.featuredMovies = Array(values.prefix(5))
        result.featuredShows = []
        result.seedRows = [.init(heading: "Because You Watched Fixture", items: Array(values.prefix(7)))]
        #expect(AppleDiscoverView.discoverRails(continueWatching: [], hasLibrary: false, recommendations: result,
            top10: nil, serverShelfIDs: []).isEmpty)
    }

    @MainActor @Test(arguments: [3, 4, 9])
    func weeklyChartRequiresFiveTitlesWithoutFilteringContinueWatching(count: Int) {
        let chart = (0..<count).map { "chart-\($0)" }
        let rows = AppleDiscoverView.displayedRowIDs([.continueWatching, .top10], keys: [["owned"], ["owned"] + chart],
            seedMinimumCounts: [])
        #expect(rows == [["owned"], count + 1 >= 5 ? ["owned"] + chart : []])
    }

    @MainActor @Test func homeOrderIsFixedWhenCoreRowsArrive() {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let values = (0..<10).map { index in
            let item = AppleCatalogItem(mediaID: "fixture-\(index)", type: "movie", name: "Fixture \(index)")
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
        }
        let result = AppleDiscoverView.RecommendationResult(seedRows: [.init(heading: "Because You Watched Fixture", items: values)],
            featuredMovies: values, featuredShows: values)
        let rails = AppleDiscoverView.discoverRails(continueWatching: [values[0]], hasLibrary: true, recommendations: result,
            top10: .init(items: values.map(\.item), fetchedAt: Self.scanned), serverShelfIDs: (0..<20).map { "server:fixture:\($0)" })
        #expect(Array(rails.prefix(6)) == [.continueWatching, .top10, .featuredMovies, .library,
            .featuredShows, .becauseWatched(0)])
        let retained = AppleDiscoverView.RailOrder.rows(rails,
            previous: [.mediaServer("server:fixture:0"), .mediaServer("server:fixture:1")],
            serverIDs: Set((0..<20).map { "server:fixture:\($0)" }))
        #expect(retained == rails)
        let visible = AppleDiscoverView.displayedRowIDs(rails,
            keys: rails.indices.map { index in (0..<10).map { "row-\(index)-\($0)" } }, seedMinimumCounts: [8])
        #expect(visible.filter { $0.isEmpty == false }.count == 9)
    }

    @MainActor @Test func deduplicationUsesVisibleRowsAndNeverClaimsASparseRow() {
        let rails: [AppleDiscoverView.DiscoverRail] = [.continueWatching, .library, .top10, .featuredMovies,
            .featuredShows, .becauseWatched(0), .mediaServer("one"), .mediaServer("two")]
        let keys = [["resume"], (0..<40).map { "recent-\($0)" }, (0..<10).map { "chart-\($0)" },
            (0..<6).map { "movie-\($0)" }, (0..<5).map { "show-\($0)" },
            (0..<8).map { "because-\($0)" }, (0..<6).map { "show-\($0)" }, (0..<6).map { "show-\($0)" }]
        let rows = AppleDiscoverView.displayedRowIDs(rails, keys: keys, seedMinimumCounts: [8])
        #expect(rows[1].count == 30)
        #expect(rows[4].isEmpty)
        #expect(rows[6].count == 6)
        #expect(rows[7].isEmpty)
        let visible = rows.flatMap { $0 }
        #expect(visible.count == Set(visible).count)
    }

    @MainActor @Test func recentlyAddedFillsThirtySlotsAfterContinueWatchingClaimsTitles() {
        let recent = (0..<40).map { "recent-\($0)" }
        let rows = AppleDiscoverView.displayedRowIDs([.continueWatching, .library],
            keys: [Array(recent.prefix(10)), recent], seedMinimumCounts: [])
        #expect(rows[0] == Array(recent.prefix(10)))
        #expect(rows[1] == Array(recent.dropFirst(10)))
    }

    @Test func featuredShelvesKeepTheirLargePromoSizing() {
        let width = AppleCatalogCard.width(sizing: .portraitPromo, rowStyle: .phone,
            scaledCardWidth: 140, viewportWidth: 390, regularWidth: false)
        #expect(width > AppleDiscoverRowStyle.phone.posterWidth)
        #expect(AppleCatalogCard.height(sizing: .portraitPromo, width: width) == width * 1.5)
    }

    // MARK: Seed rows

    @Test func seedsPreferLikedThenFinishedAndSkipDislikes() {
        let now = Self.scanned
        let history = [
            AppleViewingSignal(titleID: "started", genres: ["Drama"], at: now, completed: false),
            AppleViewingSignal(titleID: "finished", genres: ["Drama"], at: now.addingTimeInterval(-Self.day), completed: true),
            AppleViewingSignal(titleID: "disliked", genres: ["Drama"], at: now.addingTimeInterval(-2 * Self.day), completed: true),
            AppleViewingSignal(titleID: "episode", genres: ["Drama"], at: now.addingTimeInterval(-3 * Self.day),
                               completed: false, showID: "liked-show"),
            AppleViewingSignal(titleID: "finished-older", genres: ["Drama"], at: now.addingTimeInterval(-4 * Self.day), completed: true),
        ]
        let order = AppleRecommendationRowPolicy.seedOrder(history, ratings: ["disliked": .down, "liked-show": .up])
        #expect(order.map(\.titleID) == ["episode", "finished", "finished-older", "started"])
    }

    @Test func seedHeadingNeedsEightTitles() {
        #expect(AppleRecommendationRowPolicy.heading(seed: "Heat", count: 8) == "Because You Watched Heat")
        #expect(AppleRecommendationRowPolicy.heading(seed: "Heat", count: 7) == nil)
    }

    // MARK: Ranking

    private static func title(_ id: String, genres: [String] = ["Drama"], people: [String] = [], addedAt: Date? = nil,
                              quality: Double? = nil, completed: Bool = false) -> AppleRankableTitle {
        AppleRankableTitle(id: id, genres: genres, releaseYear: 2020, metadataCompleteness: 1, isResumable: false,
                           isCompleted: completed, people: people, addedAt: addedAt, quality: quality)
    }

    @Test func sharedCastOrDirectorLiftsATitle() {
        let now = Self.scanned
        let history = [AppleViewingSignal(titleID: "seed", genres: ["Drama"], at: now, completed: true,
                                          people: ["Michael Mann", "Al Pacino"])]
        let ranked = AppleRecommendationRanker.rankWithProvenance(
            [Self.title("a"), Self.title("b", people: [" al pacino "]), Self.title("c")],
            history: history, ratings: [:], now: now, limit: 3)
        #expect(ranked.first?.title.id == "b")
        #expect(ranked.first?.peopleScore == 0.5)
        #expect(ranked.first?.seeds.contains { $0.kind == .people } == true)
    }

    @Test func peopleAloneCountAsTasteEvidence() {
        let now = Self.scanned
        let history = [AppleViewingSignal(titleID: "seed", genres: ["Crime"], at: now, completed: true, people: ["Director"])]
        let ranked = AppleRecommendationRanker.rankWithProvenance(
            [Self.title("same-director", genres: ["Comedy"], people: ["Director"]), Self.title("stranger", genres: ["Comedy"])],
            history: history, ratings: [:], now: now, limit: 5, requiresAffinity: true)
        #expect(ranked.map(\.title.id) == ["same-director"])
    }

    @Test(arguments: [false, true])
    func aStartedTitleCannotRecommendItselfThroughItsOwnCast(isShow: Bool) {
        let history = [AppleViewingSignal(titleID: isShow ? "episode" : "self", genres: ["Drama"],
            at: Self.scanned, completed: false, showID: isShow ? "self" : nil, people: ["Director"])]
        let ranked = AppleRecommendationRanker.rankWithProvenance(
            [Self.title("self", people: ["Director"]), Self.title("other", people: ["Director"])],
            history: history, ratings: [:], now: Self.scanned, limit: 2, requiresAffinity: true)
        #expect(ranked.map(\.title.id) == ["other"])
    }

    @MainActor
    @Test func discoverSnapshotOver1400Titles() async throws {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let groups = AppleLibrarySeries.groups((0..<1500).map { index in
            Self.file(String(format: "Title %04d.2020.mkv", index), source: source.id,
                added: Self.scanned.addingTimeInterval(Double(index)))
        })
        let metadata = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.id, AppleCatalogItem(mediaID: "tt" + group.parsed.title.suffix(4), type: "movie",
                name: group.parsed.title, backgroundURL: URL(string: "https://fixture.example/backdrop.jpg")))
        })
        let input = AppleLocalLibraryStore.CatalogSnapshot(groups: groups, metadata: metadata, sources: [source], offlineIDs: [:])
        var milliseconds: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let result = try await AppleDiscoverView.libraryRecommendationItems(input)
            let duration = start.duration(to: .now).components
            milliseconds.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            #expect(result.ranked.count == AppleDiscoverView.rankedLibraryLimit)
            #expect(result.ranked.first?.item.name == "Title 1499")
            #expect(result.ranked.last?.item.name == "Title 0700")
            #expect(result.ranked.first?.progressKeys.count == 1)
        }
        print("Discover snapshot 1500 titles, 800 ranked (ms): \(milliseconds)")
    }

    @Test func freshnessAndQualityBreakTiesButNeverStandInForTaste() {
        let now = Self.scanned
        let history = [AppleViewingSignal(titleID: "seed", genres: ["Drama"], at: now, completed: true)]
        let titles = [
            Self.title("old"),
            Self.title("new", addedAt: now.addingTimeInterval(-Self.day)),
            Self.title("acclaimed", quality: 9),
            Self.title("fresh-but-unrelated", genres: ["Horror"], addedAt: now),
        ]
        let ranked = AppleRecommendationRanker.rankWithProvenance(titles, history: history, ratings: [:], now: now,
                                                                  limit: 5, requiresAffinity: true)
        #expect(ranked.map(\.title.id) == ["new", "acclaimed", "old"])
    }

    @Test func freshnessHalvesEveryTwoWeeksAndSkipsSeenTitles() {
        let now = Self.scanned
        #expect(AppleRecommendationRanker.freshness(addedAt: now, now: now) == 0.3)
        #expect(abs(AppleRecommendationRanker.freshness(addedAt: now.addingTimeInterval(-14 * Self.day), now: now) - 0.15) < 0.0001)
        #expect(AppleRecommendationRanker.freshness(addedAt: nil, now: now) == 0)
        #expect(AppleRecommendationRanker.quality(6) == 0)
        #expect(AppleRecommendationRanker.quality(10) == 0.3)
        #expect(AppleRecommendationRanker.quality(nil) == 0)
        let history = [AppleViewingSignal(titleID: "seed", genres: ["Drama"], at: now, completed: true)]
        let seen = AppleRecommendationRanker.rankWithProvenance([Self.title("seen", addedAt: now, completed: true)],
                                                                history: history, ratings: [:], now: now, limit: 1)
        #expect(seen.first?.freshnessScore == 0)
    }

    @Test func peopleNamesAreTheDirectorAndFiveLeads() {
        let item = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Fixture",
                                    cast: ["A", "B", "C", "D", "E", "F"], director: "Director")
        #expect(AppleRecommendationInputs.people(item) == ["director", "a", "b", "c", "d", "e"])
    }
}

private final class HomeOrderCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
