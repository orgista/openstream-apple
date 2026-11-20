import Foundation
import Testing
import SwiftUI
@testable import OpenStreamApple

/// Owner 2026-09-29: on a fresh install Discover's hero drew "JEOPARDY!" as
/// plain text all session while its title page had the logo. A mark found
/// late draws the next time the page comes round.
@Suite("Hero wordmark fetch")
struct AppleHeroWordmarkFetchTests {
    private let mark = URL(string: "https://fixture.example/logo.png")!

    @Test func localIdentityCanUpgradeThroughItsExplicitIMDbID() {
        let item = AppleCatalogItem(mediaID: "local-fixture", type: "movie", name: "Fixture", imdbID: "tt1234567")
        #expect(AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item) == "tt1234567")
    }

    @Test func localIdentityFindsTheLibraryMetadataWordmark() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/3/search/movie":
                body = #"{"results":[{"id":72,"title":"72 Hours","release_date":"2024-11-01"}]}"#
            case "/3/movie/72":
                body = #"{"id":72,"title":"72 Hours","release_date":"2024-11-01","imdb_id":"tt0000072","images":{"logos":[{"file_path":"/wordmark.png","iso_639_1":"en","vote_average":8}]}}"#
            default:
                Issue.record("Unexpected metadata path: \(url.path)")
                body = "{}"
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let upgrade = AppleHeroArtworkUpgrade(client: client, cache: AppleMetadataDiskCache(directory: directory))
        let item = AppleCatalogItem(mediaID: "local-fixture", type: "movie", name: "72 Hours", releaseInfo: "2024")
        let artwork = await upgrade.artwork(for: item, hasLibraryMetadataMatch: true, configuration: try AppleTMDBConfiguration(credential: "fixture-key"))
        #expect(artwork.logoURL == URL(string: "https://image.tmdb.org/t/p/w500/wordmark.png"))
        #expect(await upgrade.cachedArtwork(for: item, hasLibraryMetadataMatch: true) == artwork)
    }

    @Test func serverWordmarkSurvivesAProcessWithoutExternalIdentifiers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMetadataDiskCache(directory: directory)
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: mark.deletingLastPathComponent())
        let item = AppleCatalogItem(mediaID: "ms:\(source.id.uuidString):fixture-series", type: "series", name: "Fixture Series",
            backgroundURL: mark.deletingLastPathComponent().appendingPathComponent("backdrop.jpg"))
        let first = AppleHeroArtworkUpgrade(cache: cache)
        #expect(await first.cachedArtwork(for: item, source: source, namespace: "viewer") == nil)
        await first.rememberServerWordmark(mark, for: item, source: source, namespace: "viewer")
        let relaunched = AppleHeroArtworkUpgrade(cache: cache)
        let restored = try #require(await relaunched.cachedArtwork(for: item, source: source, namespace: "viewer"))
        #expect(restored.logoURL == mark)
        #expect(restored.backdropURL == item.backgroundURL)
    }

    @Test func serverWordmarkDoesNotCrossViewerOrConnectionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upgrade = AppleHeroArtworkUpgrade(cache: AppleMetadataDiskCache(directory: directory))
        var source = AppleSource(kind: .mediaServer, name: "Fixture", url: mark.deletingLastPathComponent())
        let item = AppleCatalogItem(mediaID: "ms:\(source.id.uuidString):fixture-series", type: "series", name: "Fixture Series")
        await upgrade.rememberServerWordmark(mark, for: item, source: source, namespace: "viewer-a")
        #expect(await upgrade.cachedArtwork(for: item, source: source, namespace: "viewer-b") == nil)
        source.configurationRevision += 1
        #expect(await upgrade.cachedArtwork(for: item, source: source, namespace: "viewer-a") == nil)
    }

    @Test func anExplicitEpisodeIMDbIDIsNotUsedForATitleLookup() {
        let identifier = "tt1234567:1:2"
        let item = AppleCatalogItem(mediaID: "local-fixture", type: "movie", name: "Fixture", imdbID: identifier)
        #expect(AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item) == nil)
        let identified = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", imdbID: identifier)
        #expect(AppleHeroArtworkUpgrade.upgradeableIMDBID(for: identified) == "tt1234567")
    }

    @Test func unmatchedFilenamesNeverTriggerMetadataSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        await confirmation(expectedCount: 0) { requested in
            let client = AppleTMDBClient { _ in
                requested()
                throw AppleTMDBError.titleNotFound
            }
            let upgrade = AppleHeroArtworkUpgrade(client: client, cache: AppleMetadataDiskCache(directory: directory))
            let item = AppleCatalogItem(mediaID: "local-fixture", type: "movie", name: "72 HOURS")
            let artwork = await upgrade.artwork(for: item,
                configuration: configuration)
            #expect(artwork.logoURL == nil)
            #expect(await upgrade.cachedArtwork(for: item) == nil)
        }
    }

    @MainActor @Test(arguments: ["72 Hours", "John Wick", "WALL·E", "NASA"])
    func phoneTextFallbackPreservesTheSuppliedTitle(title: String) {
        let hero = ApplePhoneHeroTitle(name: title, presentation: .text)
        #expect(hero.textFallback == Text(title))
    }

    @MainActor @Test func wordmarkCompletionIsPublishedAfterLookupAndNeverAfterCancellation() async {
        var resolved = Set<String>()
        var artwork: AppleHeroArtworkUpgrade.Artwork?
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let pending = Task { @MainActor in
            await AppleHeroTitlePolicy.resolveWordmark {
                signalStarted.yield()
                signalStarted.finish()
                for await _ in gate { break }
                return .init(backdropURL: nil, logoURL: mark)
            } apply: { artwork = $0 } didResolve: { resolved.insert("fixture") }
        }
        for await _ in started { break }
        #expect(AppleHeroTitlePolicy.wordmarkLookupPending(mediaID: "fixture", resolved: resolved, wordmarkFailed: false))
        #expect(artwork == nil)
        release.yield()
        release.finish()
        await pending.value
        #expect(artwork?.logoURL == mark)
        #expect(!AppleHeroTitlePolicy.wordmarkLookupPending(mediaID: "fixture", resolved: resolved, wordmarkFailed: false))
        let cancelled = Task { @MainActor in
            await AppleHeroTitlePolicy.resolveWordmark {
                .init(backdropURL: nil, logoURL: nil)
            } apply: { _ in Issue.record("Cancelled lookup published artwork") }
              didResolve: { Issue.record("Cancelled lookup marked resolved") }
        }
        cancelled.cancel()
        await cancelled.value
    }

    @Test func phoneValidationLatchTracksTheCurrentCandidates() {
        #expect(AppleHeroTitlePolicy.phoneWordmarkLookupPending(metadataLoaded: true, lookupPending: false,
            validatedTaskID: nil, taskID: "logo"))
        #expect(AppleHeroTitlePolicy.phoneWordmarkLookupPending(metadataLoaded: true, lookupPending: false,
            validatedTaskID: "old", taskID: "logo"))
        #expect(!AppleHeroTitlePolicy.phoneWordmarkLookupPending(metadataLoaded: true, lookupPending: false,
            validatedTaskID: "logo", taskID: "logo"))
        #expect(AppleHeroTitlePolicy.phoneWordmarkLookupPending(metadataLoaded: true, lookupPending: true,
            validatedTaskID: "logo", taskID: "logo"))
        #expect(AppleHeroTitlePolicy.phoneWordmarkLookupPending(metadataLoaded: false, lookupPending: false,
            validatedTaskID: "", taskID: ""))
    }

    /// The name keeps the slot for the rest of that showing, and lets go
    /// when the hero moves to another page, so the mark draws next time.
    @Test func theNameLatchLastsOneShowingOfOnePage() {
        #expect(AppleHeroTitlePolicy.nameLatch("a", from: "a", to: "a") == "a")
        #expect(AppleHeroTitlePolicy.nameLatch("a", from: "a", to: "b") == nil)
        #expect(AppleHeroTitlePolicy.nameLatch("a", from: "b", to: "a") == nil)
        #expect(AppleHeroTitlePolicy.nameLatch(nil, from: "a", to: "b") == nil)
    }

    /// Back on the page with a mark known and no latch, the mark draws.
    @Test func aPageComingRoundAgainDrawsTheMarkFoundMeanwhile() {
        let latch = AppleHeroTitlePolicy.nameLatch("a", from: "b", to: "a")
        let presentation = AppleHeroTitlePolicy.presentation(
            wordmark: mark, loaded: nil, failed: nil, graceExpired: false,
            lookupPending: false, nameShown: latch == "a"
        )
        #expect(presentation == .wordmark(mark))
    }
}
