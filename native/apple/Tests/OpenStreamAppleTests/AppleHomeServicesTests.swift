import Foundation
import Testing
@testable import OpenStreamApple

struct AppleHomeServicesTests {
    private let source = AppleSource(kind: .mediaServer, name: "Fixture Server", url: URL(string: "https://fixture.example")!)

    private func items(_ count: Int, sourceID: UUID, type: String = "movie", offset: Int = 0) -> [AppleCatalogItem] {
        (offset..<(offset + count)).map {
            AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: sourceID, itemID: "\(type)-\($0)").mediaID,
                type: type, name: "Title \($0)", posterURL: URL(string: "https://fixture.example/poster.jpg"), year: 2024)
        }
    }

    private func shelf(_ name: String, count: Int = 12, sourceID: UUID? = nil,
                       type: String = "movie", offset: Int = 0, total: Int? = nil) -> AppleMediaServerLibraryStore.Shelf {
        let id = sourceID ?? source.id
        return .init(id: "\(id):\(name):\(type)", title: name, sourceID: id,
            items: items(count, sourceID: id, type: type, offset: offset),
            collectionType: type == "movie" ? .movies : .tvshows,
            libraryName: name, totalItemCount: total ?? count)
    }

    @Test(arguments: [("Disney Plus Movies", AppleStreamingService.disneyPlus), ("NETFLIX-Series", .netflix),
                      ("Popular on Netflix · Library", .netflix), ("Amazon Prime Video", .primeVideo),
                      ("Prime  Video (Library)", .primeVideo), ("Amazon Prime", .primeVideo),
                      ("Max", .hboMax), ("HBO Max Shows", .hboMax), ("Apple TV+", .appleTV),
                      ("Apple TV Plus Movies", .appleTV), ("Paramount Plus", .paramountPlus),
                      ("Peacock Premium", .peacock), ("Crunchyroll", .crunchyroll), ("Tubi", .tubi), ("Pluto TV", .plutoTV)])
    func aliasesMatchCleanedWholeWords(name: String, service: AppleStreamingService) {
        #expect(AppleHomeServices.service(in: name) == service)
    }

    @Test(arguments: ["Mad Max Collection", "Max Movies", "Apple TV", "Plus", "Discovery+", "Netflixes", "MyNetflix"])
    func ambiguousAndUnknownNamesDoNotMatch(name: String) {
        #expect(AppleHomeServices.service(in: name) == nil)
    }

    @Test(arguments: AppleStreamingService.allCases)
    func onePlayableTitleWithoutArtworkSuppliesAService(service: AppleStreamingService) throws {
        let item = AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: source.id, itemID: "one").mediaID,
            type: "movie", name: "One")
        let library = AppleMediaServerLibraryStore.Shelf(id: "small", title: service.displayName, sourceID: source.id,
            items: [item], libraryName: service.libraryAliases.first)
        let detected = try #require(AppleHomeServices.detect(libraries: [library], sources: [source]).first)
        #expect(detected.service == service)
        #expect(AppleHomeServices.items(in: detected.libraries, type: .movies) == [item])
    }

    @Test func emptyAndUnplayableLibrariesDoNotSupplyServices() {
        let invalid = [
            AppleCatalogItem(mediaID: "metadata-only", type: "movie", name: "Metadata"),
            AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: UUID(), itemID: "foreign").mediaID,
                type: "movie", name: "Foreign"),
            AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: source.id, itemID: "episode").mediaID,
                type: "episode", name: "Episode"),
            AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: source.id, itemID: "blank").mediaID,
                type: "movie", name: "")
        ]
        let library = AppleMediaServerLibraryStore.Shelf(id: "invalid", title: "Peacock", sourceID: source.id,
            items: invalid, libraryName: "Peacock", totalItemCount: 200)
        #expect(AppleHomeServices.detect(libraries: [shelf("Netflix", count: 0), library], sources: [source]).isEmpty)
    }

    @Test func librariesAcrossServersProduceOneServiceAndDeduplicateTitles() throws {
        let other = AppleSource(kind: .mediaServer, name: "Other", url: source.url)
        let detected = AppleHomeServices.detect(libraries: [shelf("Netflix Movies"),
            shelf("Netflix Series", count: 8, sourceID: other.id, type: "series"),
            shelf("Popular on Netflix", sourceID: other.id)], sources: [source, other])
        let service = try #require(detected.first)
        #expect(detected.count == 1)
        #expect(service.service == .netflix)
        #expect(service.libraries.count == 3)
        #expect(AppleHomeServices.items(in: service.libraries).count == 20)
        #expect(service.mediaTypes == [.movies, .shows])
    }

    @Test func orderUsesLibraryCountsThenNameAndIncludesEveryService() {
        let libraries = AppleStreamingService.allCases.map { shelf($0 == .appleTV ? "Apple TV+" : $0.displayName) }
            + [shelf("Netflix Movies", total: 100)]
        let detected = AppleHomeServices.detect(libraries: libraries, sources: [source])
        #expect(detected.count == AppleStreamingService.allCases.count)
        #expect(detected.first?.service == .netflix)
        #expect(detected.dropFirst().map(\.service.displayName) == detected.dropFirst().map(\.service.displayName).sorted())
        let hidden = AppleHomeServices.detect(libraries: libraries, sources: [source], hidden: ["netflix"])
        #expect(hidden.count == AppleStreamingService.allCases.count - 1)
        #expect(hidden.contains { $0.service == .netflix } == false)
    }

    @Test func missingDisabledAndNonServerSourcesNeverSupplyButtons() {
        var disabled = source
        disabled.isEnabled = false
        #expect(AppleHomeServices.detect(libraries: [shelf("Netflix")], sources: []).isEmpty)
        #expect(AppleHomeServices.detect(libraries: [shelf("Netflix")], sources: [disabled]).isEmpty)
        var local = source
        local.kind = .library
        #expect(AppleHomeServices.detect(libraries: [shelf("Netflix")], sources: [local]).isEmpty)
    }

    @Test func servicePageKeepsServerOrderAndAppendsLibraries() {
        let libraries = [shelf("Netflix Movies", count: 3), shelf("Netflix Series", count: 2, type: "series"),
                         shelf("Netflix", count: 3, offset: 2)]
        let merged = AppleHomeServices.items(in: libraries)
        #expect(merged.map(\.name) == ["Title 0", "Title 1", "Title 2", "Title 0", "Title 1", "Title 3", "Title 4"])
        #expect(AppleHomeServices.items(in: libraries, type: .movies).map(\.name) == ["Title 0", "Title 1", "Title 2", "Title 3", "Title 4"])
        #expect(AppleHomeServices.items(in: libraries, type: .shows).count == 2)
    }

    @MainActor
    @Test func pagingLibrariesAtDifferentTimesKeepsEveryExistingPosition() {
        let cache = AppleHomeServices.ItemCache()
        let first = shelf("Netflix Movies", count: 2)
        let second = shelf("Netflix", count: 2, offset: 100)
        let initial = cache.items(revision: 1, libraries: [first, second], type: .movies)
        let pagedFirst = shelf("Netflix Movies", count: 4)
        let partial = cache.items(revision: 2, libraries: [pagedFirst, second], type: .movies)
        #expect(Array(partial.prefix(initial.count)) == initial)
        #expect(partial.map(\.name) == ["Title 0", "Title 1", "Title 100", "Title 101", "Title 2", "Title 3"])
        let pagedSecond = shelf("Netflix", count: 4, offset: 100)
        let complete = cache.items(revision: 3, libraries: [pagedFirst, pagedSecond], type: .movies)
        #expect(Array(complete.prefix(partial.count)) == partial)
        #expect(complete.suffix(2).map(\.name) == ["Title 102", "Title 103"])
        #expect(cache.items(revision: 4, libraries: [pagedSecond, pagedFirst], type: .movies) == complete)
        #expect(cache.items(revision: 5, libraries: [pagedFirst], type: .movies).map(\.name) == ["Title 0", "Title 1", "Title 2", "Title 3"])
    }

    @MainActor
    @Test func duplicateTitlesKeepTheirExistingServerIdentityWhenLibrariesReorder() {
        let cache = AppleHomeServices.ItemCache()
        let first = shelf("Netflix Movies", count: 2)
        let duplicate = shelf("Netflix", count: 2, sourceID: UUID())
        let initial = cache.items(revision: 1, libraries: [first, duplicate], type: .movies)
        #expect(initial.map(\.id) == first.items.map(\.id))
        let reordered = cache.items(revision: 2, libraries: [duplicate, first], type: .movies)
        #expect(reordered.map(\.id) == initial.map(\.id))
        let removed = cache.items(revision: 3, libraries: [duplicate], type: .movies)
        #expect(removed.map(\.id) == duplicate.items.map(\.id))
    }

    @MainActor
    @Test func detectionCacheInvalidatesOnlyForContentSourcesOrHiddenServices() {
        let cache = AppleHomeServices.Cache()
        #expect(cache.services(revision: 1, libraries: [shelf("Netflix")], sources: [source], hidden: []).count == 1)
        #expect(cache.services(revision: 1, libraries: [], sources: [source], hidden: []).count == 1)
        #expect(cache.services(revision: 2, libraries: [], sources: [source], hidden: []).isEmpty)
        #expect(cache.services(revision: 2, libraries: [shelf("Netflix")], sources: [], hidden: []).isEmpty)
        #expect(cache.services(revision: 2, libraries: [shelf("Netflix")], sources: [source], hidden: []).count == 1)
        #expect(cache.services(revision: 2, libraries: [shelf("Netflix")], sources: [source], hidden: ["netflix"]).isEmpty)
    }

    @Test func pickerUsesLibraryTypesBeforeItemsArriveAndNamesCanUseTheCleanedLibraryName() throws {
        let emptyShows = AppleMediaServerLibraryStore.Shelf(id: "empty-shows", title: "Netflix Series", sourceID: source.id,
            items: [], collectionType: .tvshows, libraryName: "Netflix Series", totalItemCount: 0)
        let service = try #require(AppleHomeServices.detect(libraries: [shelf("Netflix Movies (Library)"), emptyShows], sources: [source]).first)
        #expect(service.mediaTypes == [.movies, .shows])
        #expect(AppleHomeServices.Service(service: .netflix, libraries: [emptyShows]).mediaTypes == [.shows])
        #expect(service.title(customNames: [:]) == "Netflix")
        #expect(service.title(customNames: ["netflix": "Netflix Movies"]) == "Netflix Movies")
        #expect(service.title(customNames: ["netflix": "  "]) == "Netflix")
    }
}
