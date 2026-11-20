import Foundation
import Testing
@testable import OpenStreamApple

struct AppleTasteNamespaceTests {
    @Test @MainActor func isolatedContextsKeepRatingsAndPlaybackSeparate() throws {
        let suite = "openstream-taste-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = AppleTitleRatingStore(defaults: defaults)
        let one = AppleTitleRatingStore(defaults: defaults, namespace: "one")
        let two = AppleTitleRatingStore(defaults: defaults, namespace: "two")
        local.set(.up, for: "title")
        one.set(.doubleUp, for: "title")
        two.set(.down, for: "title")
        #expect(local.rating(for: "title") == .up)
        #expect(one.rating(for: "title") == .doubleUp)
        #expect(two.rating(for: "title") == .down)
        one.restoreConfigurationRatings([:])
        #expect(one.allRatings.isEmpty)
        #expect(two.allRatings.count == 1)
        #expect(local.allRatings.count == 1)
        let playbackOne = ApplePlaybackStore(defaults: defaults, namespace: "one")
        let playbackTwo = ApplePlaybackStore(defaults: defaults, namespace: "two")
        playbackOne.save(mediaID: "title", position: 120, duration: 900)
        #expect(playbackTwo.progress(for: "title") == nil)
        playbackTwo.markWatched(mediaID: "title")
        #expect(playbackOne.isWatched(mediaID: "title") == false)
        #expect(playbackTwo.isWatched(mediaID: "title"))
        #expect(ApplePlaybackStore(defaults: defaults, namespace: "one").progress(for: "title")?.position == 120)
        #expect(ApplePlaybackStore(defaults: defaults).progress(for: "title") == nil)
    }

    @Test func localNamespacePreservesKeysAndOtherContextsAreOpaque() {
        #expect(AppleTasteNamespace.key("legacy", namespace: AppleTasteNamespace.local) == "legacy")
        let key = AppleTasteNamespace.key("legacy", namespace: "https://fixture.example/?token=private")
        #expect(key.contains("private") == false)
        #expect(key.contains("https") == false)
        #expect(key != AppleTasteNamespace.key("legacy", namespace: "other"))
    }
}
