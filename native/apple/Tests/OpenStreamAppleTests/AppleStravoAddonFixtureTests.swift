import Foundation
import Testing
@testable import OpenStreamApple

/// Stravo (`org.fayallc.stravo1` 2.1.2), recorded 2026-09-30 after a tester
/// reported that adding it crashed the app. Every URL in the fixtures is
/// rewritten to `fixture.example`; the shapes are the add-on's own: a
/// `resources` list mixing objects with the bare string "catalog", 25
/// catalogs, `mx:<number>:<slug>` ids, a meta answer whose id is a different
/// (IMDb) id, streams with a null `name`, link-only "Go Premium" entries and
/// `proxyHeaders`, and a subtitle whose `lang` is a language name.
@MainActor
@Suite struct AppleStravoAddonFixtureTests {
    private static let manifestURL = "https://fixture.example/stravo/local/manifest.json"

    private struct CredentialStore: AppleCredentialStoring {
        func string(for account: String) throws -> String? { nil }
        func set(_ value: String, for account: String) throws {}
        func remove(_ account: String) throws {}
    }

    nonisolated private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    nonisolated private static func response(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }

    private func addStravo() async throws -> AppleSource {
        let body = try Self.fixture("addon-stravo-manifest.json")
        let client = AppleManifestClient(loader: { url in (body, Self.response(for: url)) }, sleeper: { _ in })
        let store = AppleSourceStore(
            defaults: UserDefaults(suiteName: "stravo.fixtures.\(UUID().uuidString)")!,
            storageKey: "stravo.fixtures",
            keychain: CredentialStore(),
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        return try await store.addStremio(manifestValue: Self.manifestURL, client: client)
    }

    private func loadItems(fixture name: String, source: AppleSource) async throws -> [AppleCatalogItem] {
        let body = try Self.fixture(name)
        let catalog = try #require(source.catalogs.first { $0.id == "homepage_7219449993227633120" })
        let client = AppleStremioCatalogClient(loader: { request in (body, Self.response(for: request.url!)) })
        return try await client.load(source: source, catalog: catalog)
    }

    @Test func manifestWithMixedResourcesAndTwentyFiveCatalogsAdds() async throws {
        let source = try await addStravo()
        #expect(source.manifestID == "org.fayallc.stravo1")
        #expect(source.version == "2.1.2")
        #expect(Set(source.resources) == ["meta", "subtitles", "stream", "catalog"])
        #expect(source.catalogs.count == 25)
        #expect(source.catalogs.first?.id == "homepage_1232643093049001320")
        // `extraSupported: ["skip"]` is paging, not a required input.
        #expect(source.catalogs.allSatisfy { !$0.requiresInput && !$0.supportsSearch })
    }

    @Test func catalogOfMxIdsLoadsEveryTitleOnce() async throws {
        let source = try await addStravo()
        let items = try await loadItems(fixture: "addon-stravo-series-epic-fantasy.json", source: source)
        #expect(items.count == 20)
        #expect(items.allSatisfy { $0.mediaID.hasPrefix("mx:") })
        #expect(Set(items.map(\.mediaID)).count == items.count)
        // A movie listed inside a series catalog is kept, not dropped or trapped on.
        #expect(items.contains { $0.name == "Willow" })
    }

    @Test func mxIdsNeverReadAsSeasonAndEpisode() {
        let id = "mx:5952233915611055472:blood-legacy-Aau1lZfiH57"
        #expect(AppleStremioSeriesInfo(mediaID: id) == nil)
        #expect(AppleStremioMetadataClient.canonicalMediaID(id) == nil)
        #expect(AppleStremioMetadataClient.episodeIdentity(id) == nil)
        #expect(AppleContinueWatchingCaption.episode(partID: id) == nil)
    }

    @Test func metaAnsweringWithAnotherIdFailsInsteadOfTrapping() async throws {
        let source = try await addStravo()
        let body = try Self.fixture("addon-stravo-meta-series.json")
        let client = AppleStremioMetadataClient(loader: { request in (body, Self.response(for: request.url!)) })
        await #expect(throws: AppleStremioPlaybackError.invalidPayload) {
            _ = try await client.details(source: source, type: "series",
                                         mediaID: "mx:5952233915611055472:blood-legacy-Aau1lZfiH57")
        }
    }

    @Test func seriesMetaListsItsEpisodesForTheImdbId() async throws {
        let source = try await addStravo()
        let body = try Self.fixture("addon-stravo-meta-series.json")
        let client = AppleStremioMetadataClient(loader: { request in (body, Self.response(for: request.url!)) })
        let episodes = try await client.episodes(source: source, mediaID: "tt33344252")
        #expect(episodes.count == 21)
        #expect(episodes.first?.id == "tt33344252:1:1")
        #expect(Set(episodes.map(\.id)).count == episodes.count)
    }

    @Test func streamsKeepPlayableEntriesAndListPremiumLinksAsUnsupported() throws {
        let selection = try AppleStremioPlaybackClient.parseStreams(Self.fixture("addon-stravo-streams-movie.json"))
        #expect(selection.httpCandidates.count == 2)
        #expect(selection.unsupported.count == 3)
        let first = try #require(selection.httpCandidates.first)
        #expect(first.title == "🖥️ 480P • Original • 356.83 MB")
        #expect(first.sizeBytes == 356_828_473)
        #expect(Set(first.requestHeaders.keys) == ["Referer", "User-Agent"])
        // The "Go Premium" title carries a newline; it is cleaned, not kept raw.
        #expect(selection.unsupported.allSatisfy { !$0.title.contains("\n") })
    }

    @Test func proxyHeadersThatTrimToTheSameNameDoNotTrap() throws {
        let json = #"""
        {"streams":[{"url":"https://fixture.example/v.mp4",
          "behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://a.example/"," Referer ":"https://b.example/"}}}}]}
        """#
        let selection = try AppleStremioPlaybackClient.parseStreams(Data(json.utf8))
        let candidate = try #require(selection.httpCandidates.first)
        #expect(candidate.requestHeaders.count == 1)
        #expect(candidate.requestHeaders["Referer"] != nil)
    }

    @Test func subtitleWithALanguageNameIsKept() throws {
        let tracks = try AppleStremioPlaybackClient.parseSubtitles(Self.fixture("addon-stravo-subtitles-movie.json"))
        #expect(tracks.count == 7)
        #expect(tracks.contains { $0.language == "Indonesian" })
    }

    /// Stravo's "🔥Hot Short TV" shelf has one title with a backdrop in 20, so
    /// a hero rotation drawn from it holds one page where the last one held
    /// five — the shrink that met the carousel's stale cycle.
    @Test func shelfWithoutBackdropsShrinksTheHeroToOnePage() async throws {
        let source = try await addStravo()
        let items = try await loadItems(fixture: "addon-stravo-series-hot-short-tv.json", source: source)
        let heroes = AppleHeroRotation.candidates(items, id: \.mediaID, hasBackdrop: AppleHeroRotation.hasBackdrop)
        #expect(heroes.count == 1)
        let stale = AppleHeroRotation.Cycle(count: AppleHeroRotation.maximumCandidates, index: 0)
        let pages = try #require(stale.pages(available: heroes.count))
        #expect(pages.shown == 0)
        #expect(pages.next == nil)
    }

    @Test("A stale cycle never names a page past the ids on hand", arguments: [
        (count: 5, index: 0, available: 1, shown: 0 as Int?, next: nil as Int?),
        (count: 5, index: 2, available: 3, shown: 2, next: 0),
        (count: 5, index: 1, available: 3, shown: 1, next: 2),
        (count: 5, index: 4, available: 3, shown: nil, next: nil),
        (count: 3, index: 2, available: 5, shown: 2, next: 0),
        (count: 5, index: 4, available: 5, shown: 4, next: 0),
        (count: 1, index: 0, available: 1, shown: 0, next: nil),
        (count: 0, index: 0, available: 3, shown: nil, next: nil),
        (count: 2, index: 0, available: 0, shown: nil, next: nil),
    ])
    func stalePageIndices(count: Int, index: Int, available: Int, shown: Int?, next: Int?) {
        let pages = AppleHeroRotation.Cycle(count: count, index: index).pages(available: available)
        #expect(pages?.shown == shown)
        #expect(pages?.next == next)
        if let pages {
            #expect(pages.shown < available)
            #expect((pages.next ?? 0) < available)
        }
    }

    @Test func runtimeTooLargeForMinutesReadsAsUnknown() {
        #expect(AppleRuntimeMinutesParser.parse("99999999999999999h") == nil)
        #expect(AppleRuntimeMinutesParser.parse("9223372036854775807") == nil)
        #expect(AppleRuntimeMinutesParser.parse("1h 9223372036854775807m") == nil)
        #expect(AppleRuntimeMinutesParser.parse("2h 22m") == 142)
    }
}
