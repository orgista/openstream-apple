import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Discover chart publication")
struct AppleDiscoverTop10PublicationTests {
    private func chart(_ name: String) -> AppleTop10Store.Chart {
        .init(items: [.init(mediaID: name, type: "movie", name: name)], fetchedAt: .distantPast)
    }

    @Test func feedChartWinsWithoutWaitingForTMDBConfiguration() {
        let feed = chart("Feed"), tmdb = chart("TMDB")
        #expect(AppleDiscoverTop10Publication.candidate(feed: feed.items, fallback: tmdb,
            enabled: true, metadataAvailable: false)?.items == feed.items)
        #expect(AppleDiscoverTop10Publication.candidate(feed: [], fallback: tmdb,
            enabled: true, metadataAvailable: true) == tmdb)
        #expect(AppleDiscoverTop10Publication.candidate(feed: feed.items, fallback: tmdb,
            enabled: false, metadataAvailable: true) == nil)
    }

    @Test func aMissingVisiblePosterKeepsTheChartUnpublished() async throws {
        let requests = try ["ready", "missing"].map {
            AppleArtworkPrefetchPolicy.Request(url: try #require(URL(string: "https://fixture.example/\($0).jpg")), maximumPixelDimension: 512)
        }
        let value = chart("New chart")
        let failed = await AppleDiscoverTop10Publication.readyChart(value, requests: requests) { request in
            if request.url.lastPathComponent == "missing.jpg" { throw URLError(.fileDoesNotExist) }
        }
        #expect(failed == nil)
        let ready = await AppleDiscoverTop10Publication.readyChart(value, requests: requests) { _ in }
        #expect(ready == value)
    }
    @Test func preferredFeedSuppressesTheOldTMDBWhilePendingAndKeepsFeedIdentityAfterArtworkFailure() async throws {
        let tmdb = chart("TMDB"), feed = chart("Feed")
        #expect(AppleDiscoverTop10Publication.visible(tmdb, publishedSource: "viewer|tmdb", preferredSource: "viewer|feed:rill") == nil)
        let request = AppleArtworkPrefetchPolicy.Request(url: try #require(URL(string: "https://fixture.example/missing.jpg")), maximumPixelDimension: 512)
        let failedFeed = await AppleDiscoverTop10Publication.readyChart(feed, requests: [request], allowsArtworkFailure: true) { _ in
            throw URLError(.fileDoesNotExist)
        }
        #expect(AppleDiscoverTop10Publication.visible(failedFeed, publishedSource: "viewer|feed:rill", preferredSource: "viewer|feed:rill") == feed)
        #expect(AppleDiscoverTop10Publication.visible(failedFeed, publishedSource: "viewer|feed:rill", preferredSource: nil) == nil)
        #expect(AppleDiscoverTop10Publication.visible(failedFeed, publishedSource: "viewer|feed:rill", preferredSource: "new-viewer|feed:rill") == nil)
    }

    @Test func cancelledPosterWorkCannotPublishEvenAFeedFallback() async throws {
        let request = AppleArtworkPrefetchPolicy.Request(url: try #require(URL(string: "https://fixture.example/cancelled.jpg")), maximumPixelDimension: 512)
        let cancelled = await AppleDiscoverTop10Publication.readyChart(chart("Feed"), requests: [request], allowsArtworkFailure: true) { _ in
            throw CancellationError()
        }
        #expect(cancelled == nil)
    }

    @Test func sameIDMetadataAndRenderedPixelChangesInvalidatePendingPublication() throws {
        let url = try #require(URL(string: "https://fixture.example/poster.jpg"))
        let original = AppleCatalogItem(mediaID: "same-id", type: "movie", name: "Fixture", posterURL: url,
            releaseInfo: "2020", rating: 7)
        let refreshed = AppleCatalogItem(mediaID: "same-id", type: "movie", name: "Fixture", posterURL: url,
            releaseInfo: "2021", rating: 9)
        let request = AppleArtworkPrefetchPolicy.Request(url: url, maximumPixelDimension: 512)
        let pending = AppleDiscoverTop10Publication.Snapshot(items: [original], preferredSource: "viewer|tmdb", requests: [request])
        let metadataRefresh = AppleDiscoverTop10Publication.Snapshot(items: [refreshed], preferredSource: "viewer|tmdb", requests: [request])
        let resized = AppleDiscoverTop10Publication.Snapshot(items: [original], preferredSource: "viewer|tmdb",
            requests: [.init(url: url, maximumPixelDimension: 768)])
        #expect(pending != metadataRefresh)
        #expect(pending != resized)
    }


}
