import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Discover Continue Watching publication")
struct AppleDiscoverContinueWatchingPublicationTests {
    private func value(_ id: String, source: AppleSource) -> AppleDiscoverView.IndexedCatalogItem {
        let item = AppleCatalogItem(mediaID: id, type: "series", name: id)
        return .init(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
    }

    @Test func pendingRefreshImmediatelyHidesRemovedMembershipAndPreviousSourceContext() throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let first = value("first", source: source), removed = value("removed", source: source)
        let saved = AppleDiscoverContinueWatchingPublication.Snapshot(values: [first, removed], sourceContext: "viewer-1", requests: [], viewportReady: true)
        #expect(AppleDiscoverContinueWatchingPublication.visible(saved, current: [first], sourceContext: "viewer-1").map(\.id) == [first.id])
        #expect(AppleDiscoverContinueWatchingPublication.visible(saved, current: [first], sourceContext: "viewer-2").isEmpty)
        #expect(AppleDiscoverContinueWatchingPublication.visible(saved, current: [], sourceContext: "viewer-1").isEmpty)
    }

    @Test func episodeAndPixelVariantChangesInvalidatePendingWork() throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let first = value("series", source: source)
        var next = first
        next.continueWatchingInfo = .init(progress: 0.3, subtitle: "S1 E2")
        let url = try #require(URL(string: "https://fixture.example/episode.jpg"))
        let old = AppleDiscoverContinueWatchingPublication.Snapshot(values: [first], sourceContext: "viewer", requests: [.init(url: url, maximumPixelDimension: 512)], viewportReady: true)
        let episode = AppleDiscoverContinueWatchingPublication.Snapshot(values: [next], sourceContext: "viewer", requests: old.requests, viewportReady: true)
        let resized = AppleDiscoverContinueWatchingPublication.Snapshot(values: [first], sourceContext: "viewer", requests: [.init(url: url, maximumPixelDimension: 768)], viewportReady: true)
        #expect(old != episode)
        #expect(old != resized)
    }

    @Test func artworkFailureSettlesAndCancellationRemainsDistinct() async throws {
        let request = AppleArtworkPrefetchPolicy.Request(url: try #require(URL(string: "https://fixture.example/episode.jpg")), maximumPixelDimension: 512)
        #expect(await AppleDiscoverArtworkPublication.warm([request]) { _ in throw URLError(.fileDoesNotExist) } == .failed)
        #expect(await AppleDiscoverArtworkPublication.warm([request]) { _ in throw CancellationError() } == .cancelled)
    }
}
