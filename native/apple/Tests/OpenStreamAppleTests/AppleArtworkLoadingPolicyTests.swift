import Foundation
import Testing
@testable import OpenStreamApple

struct AppleArtworkLoadingPolicyTests {
    @Test func loadedIdentitySurvivesMovementAndColdLoadsContinue() {
        #expect(!AppleArtworkLoadingPolicy.needsReload(loadedIdentity: "poster", requestedIdentity: "poster"))
        #expect(AppleArtworkLoadingPolicy.needsReload(loadedIdentity: "poster", requestedIdentity: "poster", hasImage: false))
        #expect(AppleArtworkLoadingPolicy.needsReload(loadedIdentity: "poster", requestedIdentity: "other"))
    }

    @Test func prefetchIsTwentyAheadAndBounded() {
        let items = (0..<40).map { AppleCatalogItem(mediaID: "\($0)", type: "movie", name: "\($0)",
            posterURL: URL(string: "https://fixture.example/\($0).jpg")) }
        #expect(AppleArtworkPrefetchPolicy.ahead(after: items[5].id, in: items).count == 20)
        #expect(AppleArtworkPrefetchPolicy.ahead(after: items[5].id, in: items).first?.lastPathComponent == "6.jpg")
        #expect(AppleArtworkPrefetchPolicy.ahead(after: items[38].id, in: items).count == 1)
        #expect(AppleArtworkPrefetchPolicy.ahead(after: "missing", in: items).isEmpty)
    }
}
