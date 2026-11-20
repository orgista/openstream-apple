import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleDiscoverServerRowsTests {
    private let server = AppleSource(kind: .mediaServer, name: "Fixture Server", url: URL(string: "https://fixture.example")!)

    private func items(_ range: Range<Int>, type: String = "movie", prefix: String = "fixture") -> [AppleCatalogItem] {
        range.map { AppleCatalogItem(mediaID: "\(prefix)-\(type)-\($0)", type: type, name: "Title \($0)",
            posterURL: URL(string: "https://fixture.example/poster.jpg"), releaseInfo: "2024") }
    }

    private func shelf(_ id: String, title: String = "Latest", items: [AppleCatalogItem],
                       sort: AppleMediaServerLibraryStore.Shelf.DiscoverySort? = nil) -> AppleMediaServerLibraryStore.Shelf {
        .init(id: id, title: title, sourceID: server.id, items: items, discoverySort: sort)
    }

    @Test(arguments: [AppleMediaServerLibrary.Kind.movies, .tvshows, .collections, .other])
    func anExplicitTop10KeepsBothMediaTypes(collectionType: AppleMediaServerLibrary.Kind) throws {
        let titles = items(0..<5) + items(0..<5, type: "series")
        let chart = AppleMediaServerLibraryStore.Shelf(id: "top10:feed", title: "Top 10", sourceID: server.id,
            items: titles, collectionType: collectionType, discoverySort: .top10)
        let row = try #require(AppleDiscoverServerRows.rows([chart], sources: [server]).first)
        #expect(row.id == AppleDiscoverRowOrder.top10)
        #expect(row.items.map(\.mediaID) == titles.map(\.mediaID))
    }

    @Test(arguments: ["movie", "series"])
    func featuredLibrariesMergeIntoTheirBuiltInRow(type: String) throws {
        let row = try #require(AppleDiscoverServerRows.rows([
            shelf("featured", title: "Featured · The Movie Database", items: items(0..<12, type: type)),
        ], sources: [server]).first)
        #expect(row.title == (type == "movie" ? "Featured Movies" : "Featured Shows"))
        #expect(row.id == (type == "movie" ? "featuredMovies" : "featuredShows"))
    }

    @Test func mixedLibrariesKeepTheirCleanedNameAndStableLibraryID() throws {
        let id = "ms:\(server.id.uuidString.lowercased()):family"
        let row = try #require(AppleDiscoverServerRows.rows([
            shelf(id, title: "Kids (Family)", items: items(0..<8) + items(0..<8, type: "series")),
        ], sources: [server]).first)
        #expect(row.title == "Kids")
        #expect(row.id == "server:\(server.id.uuidString.lowercased()):family")
    }

    @Test(arguments: ["Services", "Top 10 This Week", "Continue Watching", "Because You Watched"])
    func reservedTitlesKeepTheirServerLibraryRows(title: String) throws {
        let input = items(0..<4) + items(0..<4, type: "series")
        let row = try #require(AppleDiscoverServerRows.rows([
            shelf("library", title: title, items: input, sort: .other),
        ], sources: [server]).first)
        #expect(row.id == "server:\(server.id.uuidString.lowercased()):library")
        #expect(row.title == title)
        #expect(AppleDiscoverView.discoverRails(continueWatching: [], hasLibrary: false, recommendations: .init(),
            top10: nil, serverShelfIDs: [row.id]) == [.mediaServer(row.id)])
        #expect(AppleDiscoverRowOrder.rows([.init(id: row.id, keys: row.items.map(\.mediaID))]).count == 1)
    }

    @Test(arguments: [("Featured Movies", "movie", "featuredMovies"), ("Featured Shows", "series", "featuredShows"),
                      ("Popular Movies", "movie", "popularMovies"), ("Popular Shows", "series", "popularShows"),
                      ("Recently Added", "mixed", "recentlyAdded")])
    func matchingTitlesOnlyMergeIntoRowsThatAcceptServerItems(title: String, type: String, id: String) throws {
        let input = type == "mixed" ? items(0..<4) + items(0..<4, type: "series") : items(0..<8, type: type)
        let row = try #require(AppleDiscoverServerRows.rows([
            shelf("library", title: title, items: input, sort: .other),
        ], sources: [server]).first)
        #expect(row.id == id)
        #expect(row.items.count == input.count)
    }

    @Test func twoServersWithPopularMergeByMediaTypeWithoutSourceNames() {
        let other = AppleSource(kind: .mediaServer, name: "Other Server", url: server.url)
        let rows = AppleDiscoverServerRows.rows([
            shelf("popular-a", title: "Popular - Fixture Server", items: items(0..<12)),
            .init(id: "popular-b", title: "Popular | Other Server", sourceID: other.id,
                  items: items(6..<18, prefix: "other")),
            .init(id: "popular-shows", title: "Popular", sourceID: other.id, items: items(0..<8, type: "series")),
        ], sources: [server, other])
        #expect(rows.map(\.id) == ["popularMovies", "popularShows"])
        #expect(rows.map(\.title) == ["Popular Movies", "Popular Shows"])
        #expect(rows.map { $0.items.count } == [18, 8])
        #expect(rows.allSatisfy { $0.title.contains(server.name) == false && $0.title.contains(other.name) == false })
        #expect(rows.first?.shelfIDs == ["popular-a", "popular-b"])
    }

    @Test func latestShelvesFeedOneRecentlyAddedInputAndTopShelvesFeedPopular() {
        let rows = AppleDiscoverServerRows.rows([
            shelf("latest", items: items(0..<12) + items(0..<8, type: "series")),
            shelf("top", title: "Top", items: items(6..<18)),
        ], sources: [server])
        #expect(rows.map(\.id) == ["recentlyAdded", "popularMovies"])
        #expect(rows.map { $0.items.count } == [20, 12])
        #expect(rows.first?.items.contains { $0.mediaID == rows.last?.items.first?.mediaID } == true)
    }

    @Test func equalCleanedLibraryNamesMergeIntoTheFirstLibrary() {
        let rows = AppleDiscoverServerRows.rows([
            shelf("one", title: "Staff Picks - First", items: items(0..<8)),
            shelf("two", title: "Staff Picks | Second", items: items(4..<12)),
        ], sources: [server])
        #expect(rows.map(\.title) == ["Staff Picks Movies"])
        #expect(rows.first?.id == "server:\(server.id.uuidString.lowercased()):one")
        #expect(rows.first?.items.count == 12)
        #expect(rows.first?.shelfIDs == ["one", "two"])
    }

    @Test(arguments: ["Netflix Movies", "Disney Plus Shows", "Popular on Netflix", "Hulu", "Amazon Prime Video",
                      "Max", "HBO Max", "Apple TV+", "Apple TV Plus", "Paramount Plus", "Peacock", "Crunchyroll", "Tubi", "Pluto TV"])
    func serviceLibrariesNeverBecomeHomeRows(name: String) {
        #expect(AppleDiscoverServerRows.rows([
            shelf("service", title: name, items: items(0..<12), sort: .other),
        ], sources: [server]).isEmpty)
    }

    @Test func serviceLatestAndTopShelvesOnlyFeedTheMergedInputs() {
        let rows = AppleDiscoverServerRows.rows([
            shelf("service:latest", title: "Latest in Netflix", items: items(0..<12), sort: .latest),
            shelf("service:top", title: "Popular on Netflix", items: items(6..<18), sort: .top),
        ], sources: [server])
        #expect(rows.map(\.id) == ["recentlyAdded", "popularMovies"])
    }

    @Test(arguments: ["Mad Max Collection", "Apple TV", "Nonstop Action"])
    func nonServiceNamesStayLibraryRows(name: String) {
        let rows = AppleDiscoverServerRows.rows([shelf("library", title: name, items: items(0..<12), sort: .other)], sources: [server])
        #expect(rows.count == 1)
        #expect(rows.first?.id.hasPrefix("server:") == true)
    }

    @Test func genreAndNextUpShelvesNeverReachHome() {
        #expect(AppleDiscoverServerRows.rows([
            shelf("genre:drama", title: "Drama", items: items(0..<12), sort: .other),
            shelf("nextup", title: "Next up in Shows", items: items(0..<12, type: "series"), sort: .other),
        ], sources: [server]).isEmpty)
    }

    @Test func metadataOverridesTitlesAndKeepsMediaTypesSeparate() {
        let rows = AppleDiscoverServerRows.rows([
            .init(id: "movies", title: "Nouveautés", sourceID: server.id, items: items(0..<12),
                  collectionType: .movies, discoverySort: .latest),
            .init(id: "shows", title: "Latest", sourceID: server.id, items: items(20..<32, type: "series") + items(40..<52),
                  collectionType: .tvshows, discoverySort: .top),
        ], sources: [server])
        #expect(rows.map(\.id) == ["recentlyAdded", "popularShows"])
        #expect(rows.last?.items.allSatisfy { $0.type == "series" } == true)
    }

    @Test func serverAdditionDatesSurviveDecodingAndCacheEncoding() throws {
        let jellyfin = try JSONDecoder().decode(AppleMediaServerItem.self,
            from: Data(#"{"Id":"movie","Name":"Movie","Type":"Movie","DateCreated":"2026-11-04T12:00:00.000Z"}"#.utf8))
        let plex = try JSONDecoder().decode(ApplePlexItem.self,
            from: Data(#"{"ratingKey":"movie","key":"/library/metadata/movie","type":"movie","title":"Movie","addedAt":1793793600}"#.utf8))
        #expect(jellyfin.addedAt == Date(timeIntervalSince1970: 1_793_793_600))
        #expect(plex.addedAt == jellyfin.addedAt)
        #expect(try JSONDecoder().decode(AppleMediaServerItem.self, from: JSONEncoder().encode(jellyfin)).addedAt == jellyfin.addedAt)
        #expect(try JSONDecoder().decode(ApplePlexItem.self, from: JSONEncoder().encode(plex)).addedAt == plex.addedAt)
    }

    @Test func jellyfinFixtureWithSevenFractionalDigitsKeepsItsCreationDate() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jellyfin-local-trailers.json")
        let items = try JSONDecoder().decode([AppleMediaServerItem].self, from: Data(contentsOf: url))
        let item = try #require(items.first)
        let expected = try Date.ISO8601FormatStyle().parse("2026-10-17T07:07:00Z")
        #expect(item.addedAt == expected)
        #expect(try JSONDecoder().decode(AppleMediaServerItem.self, from: JSONEncoder().encode(item)).addedAt == expected)
    }

    @Test(arguments: ["2026-11-04T12:00:00.1234567Z", "2026-11-04T12:00:00.123Z", "2026-11-04T12:00:00Z"])
    func jellyfinCreationDateSupportsNonzeroFractionsAndWholeSeconds(value: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["Id": "movie", "Name": "Movie", "Type": "Movie", "DateCreated": value])
        let item = try JSONDecoder().decode(AppleMediaServerItem.self, from: data)
        let date = try #require(item.addedAt)
        let fraction = value.contains(".") ? 0.123 : 0
        #expect(abs(date.timeIntervalSince1970 - (1_793_793_600 + fraction)) < 0.000_001)
        #expect(try JSONDecoder().decode(AppleMediaServerItem.self, from: JSONEncoder().encode(item)).addedAt == date)
    }

    @Test(arguments: [0, 3])
    func pendingLibraryRowsKeepTheirLoadingSlot(count: Int) throws {
        let shelf = AppleMediaServerLibraryStore.Shelf(id: "slow", title: "Staff Picks", sourceID: server.id,
            items: items(0..<count), collectionType: .movies, discoverySort: .other)
        let input = try #require(AppleDiscoverServerRows.rows([shelf], sources: [server], pendingShelfIDs: [shelf.id]).first)
        #expect(input.shelfIDs == [shelf.id])
        let row = AppleDiscoverRowOrder.Row(id: input.id, keys: input.items.map(\.mediaID), isLoading: input.isLoading)
        let displayed = AppleDiscoverRowOrder.rows([row])
        #expect(displayed.map(\.id) == [input.id])
        #expect(displayed.first?.keys == row.keys)
        #expect(AppleDiscoverRowOrder.rows([.init(id: input.id, keys: row.keys)]).isEmpty)
    }

    @Test func preparationCacheTracksContentSourcesAndPendingState() {
        let cache = AppleDiscoverServerRows.Cache()
        let original = shelf("latest", items: items(0..<12))
        let changed = shelf("latest", items: items(20..<32))
        let first = cache.rows(revision: 1, shelves: [original], sources: [server], pendingShelfIDs: [])
        let reused = cache.rows(revision: 1, shelves: [changed], sources: [server], pendingShelfIDs: [])
        #expect(reused.first?.items == first.first?.items)
        let updated = cache.rows(revision: 2, shelves: [changed], sources: [server], pendingShelfIDs: [])
        #expect(updated.first?.items == changed.items)
        #expect(cache.rows(revision: 2, shelves: [changed], sources: [server], pendingShelfIDs: [changed.id]).first?.isLoading == true)
        var disabled = server
        disabled.isEnabled = false
        #expect(cache.rows(revision: 2, shelves: [changed], sources: [disabled], pendingShelfIDs: []).isEmpty)
    }
}
