import Foundation
import Testing
@testable import OpenStreamApple

/// The hero draws the wordmark itself, so it wants the frame without one
/// painted on. These pin the choice down without a network (owner 2026-09-20:
/// "look for movie art without the wordmark since we render the work mark
/// separately").
@Suite struct AppleTextlessBackdropPolicyTests {
    private func backdrop(_ path: String, _ language: String?, _ vote: Double?) -> AppleArtworkImage {
        AppleArtworkImage(filePath: path, languageCode: language, voteAverage: vote)
    }

    @Test func textlessBackdropBeatsAHigherRatedEnglishOne() {
        let choice = AppleTextlessBackdropPolicy.choose(
            backdrops: [
                backdrop("/english-title-art.jpg", "en", 9.8),
                backdrop("/clean.jpg", nil, 3.1),
            ],
            backdropPath: "/primary.jpg",
            posterPath: "/poster.jpg"
        )
        #expect(choice == .textlessBackdrop("/clean.jpg"))
        #expect(choice?.isBackdrop == true)
    }

    @Test func highestVoteAverageWinsAmongTextlessBackdrops() {
        let choice = AppleTextlessBackdropPolicy.choose(
            backdrops: [
                backdrop("/quiet.jpg", nil, 5.0),
                backdrop("/best.jpg", nil, 7.4),
                backdrop("/middling.jpg", nil, 6.2),
            ],
            backdropPath: "/primary.jpg",
            posterPath: nil
        )
        #expect(choice == .textlessBackdrop("/best.jpg"))
    }

    @Test func tiedVotesKeepTheOrderTMDBReturned() {
        let choice = AppleTextlessBackdropPolicy.choose(
            backdrops: [
                backdrop("/first.jpg", nil, 6.0),
                backdrop("/second.jpg", nil, 6.0),
            ],
            backdropPath: nil,
            posterPath: nil
        )
        #expect(choice == .textlessBackdrop("/first.jpg"))
    }

    /// TMDB writes `null`; some mirrors write `""`. Both mean "no words".
    @Test func anEmptyLanguageCountsAsTextless() {
        #expect(backdrop("/clean.jpg", "", 1.0).isTextless)
        #expect(backdrop("/clean.jpg", "  ", 1.0).isTextless)
        #expect(backdrop("/titled.jpg", "en", 1.0).isTextless == false)
    }

    /// A missing `vote_average` scores zero rather than dropping the entry:
    /// an unrated textless backdrop is still better than a titled one.
    @Test func anUnratedTextlessBackdropIsStillChosen() {
        let choice = AppleTextlessBackdropPolicy.choose(
            backdrops: [backdrop("/clean.jpg", nil, nil)],
            backdropPath: "/primary.jpg",
            posterPath: nil
        )
        #expect(choice == .textlessBackdrop("/clean.jpg"))
    }

    @Test func fallsBackToThePrimaryBackdropWhenEveryImageHasTitleArt() {
        let choice = AppleTextlessBackdropPolicy.choose(
            backdrops: [
                backdrop("/english.jpg", "en", 9.0),
                backdrop("/french.jpg", "fr", 8.0),
            ],
            backdropPath: "/primary.jpg",
            posterPath: "/poster.jpg"
        )
        #expect(choice == .backdrop("/primary.jpg"))
        #expect(choice?.isBackdrop == true)
    }

    @Test func fallsBackToThePosterWhenThereIsNoBackdropAtAll() {
        let choice = AppleTextlessBackdropPolicy.choose(
            backdrops: [],
            backdropPath: nil,
            posterPath: "/poster.jpg"
        )
        #expect(choice == .poster("/poster.jpg"))
        // A poster carries its own title treatment, so the hero must not draw
        // a second copy of the name over it.
        #expect(choice?.isBackdrop == false)
    }

    @Test func nothingUsableIsNoChoiceRatherThanABadURL() {
        #expect(AppleTextlessBackdropPolicy.choose(backdrops: [], backdropPath: nil, posterPath: nil) == nil)
    }

    /// Only TMDB-shaped relative paths become URLs. A bare filename, an
    /// absolute URL smuggled into `file_path`, `/` on its own and an
    /// over-long path are all refused at every step.
    @Test(arguments: ["", " ", "/", "poster.jpg", "https://evil.example/x.jpg"])
    func malformedPathsAreRefused(_ path: String) {
        #expect(AppleTextlessBackdropPolicy.choose(
            backdrops: [backdrop(path, nil, 9.9)],
            backdropPath: path,
            posterPath: path
        ) == nil)
    }

    @Test func anOverlongPathIsRefused() {
        let path = "/" + String(repeating: "a", count: 400)
        #expect(AppleTextlessBackdropPolicy.choose(
            backdrops: [backdrop(path, nil, 9.9)],
            backdropPath: path,
            posterPath: "/poster.jpg"
        ) == .poster("/poster.jpg"))
    }

    @Test func pathsAreTrimmedBeforeUse() {
        #expect(AppleTextlessBackdropPolicy.choose(
            backdrops: [backdrop("  /clean.jpg\n", nil, 1.0)],
            backdropPath: nil,
            posterPath: nil
        ) == .textlessBackdrop("/clean.jpg"))
    }

    @Test func pathReadsBackFromEveryCase() {
        #expect(AppleHeroArtworkChoice.textlessBackdrop("/a.jpg").path == "/a.jpg")
        #expect(AppleHeroArtworkChoice.backdrop("/b.jpg").path == "/b.jpg")
        #expect(AppleHeroArtworkChoice.poster("/c.jpg").path == "/c.jpg")
    }
}

/// Only a plain IMDB id resolves on TMDB; everything else the app carries as a
/// media id is left alone rather than turned into a doomed request.
@Suite struct AppleHeroArtworkUpgradeTargetTests {
    private func item(_ mediaID: String) -> AppleCatalogItem {
        AppleCatalogItem(mediaID: mediaID, type: "movie", name: "Test")
    }

    @Test func aPlainIMDBIDIsUpgradeable() {
        #expect(AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item("tt0119698")) == "tt0119698")
    }

    @Test func anEpisodeIDUpgradesThroughItsSeriesRoot() {
        #expect(AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item("tt0944947:1:2")) == "tt0944947")
    }

    @Test(arguments: ["tmdb:12345", "local-abc123", "", "kitsu:42"])
    func nonIMDBIdentifiersAreLeftAlone(_ mediaID: String) {
        #expect(AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item(mediaID)) == nil)
    }
}

/// The textless choice rides on the `images` block the details request
/// already appends, so it costs no extra round trip.
@Suite struct AppleTMDBTextlessBackdropTests {
    private func client(detailsBody: String) -> AppleTMDBClient {
        AppleTMDBClient { request in
            let body: Data
            if request.url?.path == "/3/find/tt1234567" {
                body = Data(#"{"movie_results":[{"id":42}],"tv_results":[]}"#.utf8)
            } else {
                #expect(request.url?.path == "/3/movie/42")
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                #expect(queryItems?.contains(URLQueryItem(name: "include_image_language", value: "en,null")) == true)
                #expect(queryItems?.contains(URLQueryItem(name: "append_to_response", value: "credits,videos,images,recommendations,similar")) == true)
                body = Data(detailsBody.utf8)
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func details(_ body: String) async throws -> AppleTMDBDetails {
        try await client(detailsBody: body).details(
            imdbID: "tt1234567",
            kind: .movie,
            configuration: try AppleTMDBConfiguration(credential: "eyJheader.payload.signature")
        )
    }

    @Test func theBackdropWithNoTitleBurnedInWins() async throws {
        let value = try await details(#"""
        {
          "poster_path":"/poster.jpg",
          "backdrop_path":"/titled-primary.jpg",
          "genres":[],
          "images":{"backdrops":[
            {"file_path":"/titled.jpg","iso_639_1":"en","vote_average":9.9},
            {"file_path":"/clean-low.jpg","iso_639_1":null,"vote_average":4.0},
            {"file_path":"/clean-high.jpg","iso_639_1":null,"vote_average":6.5}
          ]}
        }
        """#)
        #expect(value.backdropURL == URL(string: "https://image.tmdb.org/t/p/w1280/clean-high.jpg"))
        #expect(value.textlessBackdropURL == URL(string: "https://image.tmdb.org/t/p/w1280/clean-high.jpg"))
    }

    @Test func thePrimaryBackdropStandsWhenEveryImageHasTitleArt() async throws {
        let value = try await details(#"""
        {
          "poster_path":"/poster.jpg",
          "backdrop_path":"/titled-primary.jpg",
          "genres":[],
          "images":{"backdrops":[{"file_path":"/titled.jpg","iso_639_1":"en","vote_average":9.9}]}
        }
        """#)
        #expect(value.backdropURL == URL(string: "https://image.tmdb.org/t/p/w1280/titled-primary.jpg"))
        // Nothing better exists, so a hero with art already on screen is told
        // there is nothing to upgrade to.
        #expect(value.textlessBackdropURL == nil)
    }

    /// A poster is not a backdrop: `posterURL` already carries it, and a hero
    /// falling back to one must not draw the name over art that says it.
    @Test func aPosterOnlyRecordLeavesTheBackdropEmpty() async throws {
        let value = try await details(#"{"poster_path":"/poster.jpg","genres":[],"images":{"backdrops":[]}}"#)
        #expect(value.posterURL == URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
        #expect(value.backdropURL == nil)
        #expect(value.textlessBackdropURL == nil)
    }

    /// `images` used to require both lists, so a record carrying logos and no
    /// backdrops decoded to nothing and lost its wordmark with it.
    @Test func logosSurviveARecordWithNoBackdropList() async throws {
        let value = try await details(#"""
        {
          "backdrop_path":"/primary.jpg",
          "genres":[],
          "images":{"logos":[{"file_path":"/wordmark.png","iso_639_1":"en","vote_average":8.0}]}
        }
        """#)
        #expect(value.logoURL == URL(string: "https://image.tmdb.org/t/p/w500/wordmark.png"))
        #expect(value.backdropURL == URL(string: "https://image.tmdb.org/t/p/w1280/primary.jpg"))
    }
}

/// Part B of the owner's 2026-09-20 report: the Library hero drew a plain text
/// title because the wordmark never reached it. The meta response that fills a
/// Library card carries one; `AppleCatalogItem` had nowhere to put it.
@Suite struct AppleLibraryWordmarkTests {
    private func libraryItem(_ path: String, source: UUID = UUID()) -> AppleLibraryItem {
        .init(sourceID: source, name: (path as NSString).lastPathComponent,
              url: URL(fileURLWithPath: "/fixture/" + path), relativePath: path, sizeBytes: 1)
    }

    @Test func aResolvedLibraryTitleKeepsItsWordmarkThroughTheDiskCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wordmark = URL(string: "https://fixture.example/wordmark.png")!
        let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _ in
            AppleCatalogItem(
                mediaID: "tt5657846", type: "movie", name: title.title,
                backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"),
                logoURL: wordmark
            )
        }
        let item = libraryItem("A.Bad.Moms.Christmas.2017.mkv")
        let resolved = try await resolver.resolve(item, tmdbKey: "", omdbKey: "")
        #expect(resolved?.logoURL == wordmark)

        // Reopening reads the cached JSON, which is where a missing Codable
        // field would quietly drop the wordmark again.
        let reopened = AppleLibraryMetadataResolver(directory: root) { _, _, _ in nil }
        #expect(try await reopened.resolve(item, tmdbKey: "", omdbKey: "")?.logoURL == wordmark)
    }

    /// A viewer who already has a Library holds week-old cache entries that
    /// were written before `logoURL` existed. Without a schema bump the fix
    /// looks like it never shipped: the hero keeps reading a JSON file that
    /// has no wordmark in it.
    @Test func aCacheEntryFromBeforeTheWordmarkFieldIsResolvedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UUID()
        let item = libraryItem("A.Bad.Moms.Christmas.2017.mkv", source: source)

        // Exactly what the old build wrote: no `schema`, no `logoURL`.
        let legacy = """
        {"value":{"id":"movie:tt5657846","mediaID":"tt5657846","type":"movie",
        "name":"A Bad Moms Christmas"},
        "checkedAt":\(Date().timeIntervalSinceReferenceDate),
        "addedAt":\(Date(timeIntervalSinceReferenceDate: 0).timeIntervalSinceReferenceDate)}
        """
        let folder = root.appendingPathComponent(source.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: folder.appendingPathComponent(
            AppleLibraryMetadataResolver.cacheKey(item) + ".json"))

        let wordmark = URL(string: "https://fixture.example/wordmark.png")!
        let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _ in
            AppleCatalogItem(mediaID: "tt5657846", type: "movie", name: title.title, logoURL: wordmark)
        }
        // A fresh-but-old-shaped entry is refused, so the wordmark arrives now
        // rather than whenever the seven-day lifetime happens to run out.
        #expect(try await resolver.resolve(item, tmdbKey: "", omdbKey: "")?.logoURL == wordmark)

        // And the rewritten entry is now publishable: `cachedLookups` applies
        // the same gate, so the store no longer skips the group as "already
        // resolved" while holding the old shape.
        let group = AppleLibrarySeries(id: "g", parsed: AppleLibraryTitleParser.parse(item), items: [item])
        #expect(await resolver.cachedLookups(for: [group]).metadata["g"]?.logoURL == wordmark)
    }

    /// Cached items written before the field existed must still decode.
    @Test func aCachedPayloadWithoutTheFieldStillDecodes() throws {
        let legacy = Data(#"""
        {"id":"movie:tt5657846","mediaID":"tt5657846","type":"movie","name":"A Bad Moms Christmas"}
        """#.utf8)
        let item = try JSONDecoder().decode(AppleCatalogItem.self, from: legacy)
        #expect(item.logoURL == nil)
        #expect(item.mediaID == "tt5657846")
    }

    /// The hero swaps art without changing identity, so tvOS focus survives.
    @Test func upgradingHeroArtworkKeepsTheItemsIdentity() {
        let item = AppleCatalogItem(
            mediaID: "tt5657846", type: "movie", name: "A Bad Moms Christmas",
            posterURL: URL(string: "https://fixture.example/poster.jpg"),
            backgroundURL: URL(string: "https://fixture.example/titled.jpg")
        )
        let upgraded = item.withHeroArtwork(
            backgroundURL: URL(string: "https://fixture.example/clean.jpg"),
            logoURL: URL(string: "https://fixture.example/wordmark.png")
        )
        #expect(upgraded.id == item.id)
        #expect(upgraded.posterURL == item.posterURL)
        #expect(upgraded.backgroundURL?.lastPathComponent == "clean.jpg")
        #expect(upgraded.logoURL?.lastPathComponent == "wordmark.png")
    }

    /// Nothing to upgrade to leaves the art the hero is already showing.
    @Test func anEmptyUpgradeLeavesTheExistingArtAlone() {
        let item = AppleCatalogItem(
            mediaID: "tt5657846", type: "movie", name: "A Bad Moms Christmas",
            backgroundURL: URL(string: "https://fixture.example/titled.jpg"),
            logoURL: URL(string: "https://fixture.example/wordmark.png")
        )
        let upgraded = item.withHeroArtwork(backgroundURL: nil, logoURL: nil)
        #expect(upgraded.backgroundURL == item.backgroundURL)
        #expect(upgraded.logoURL == item.logoURL)
    }

    /// With a wordmark the tvOS billboard draws it; without one it still falls
    /// back to the text title rather than showing nothing.
    @Test func theBillboardDrawsTheWordmarkOnceTheLibraryHeroHasOne() throws {
        let wordmark = try #require(URL(string: "https://fixture.example/wordmark.png"))
        #expect(AppleHeroTitlePolicy.presentation(wordmark: wordmark, loaded: wordmark, failed: nil, graceExpired: false)
            == .wordmark(wordmark))
        #expect(AppleHeroTitlePolicy.presentation(wordmark: nil, loaded: nil, failed: nil, graceExpired: false) == .name)
    }
}
