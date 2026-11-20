import Foundation
import Testing
@testable import OpenStreamApple

/// Stores on the standard storage share one decoded copy of the playback maps
/// (a poster or shelf that makes a store per redraw no longer decodes them
/// again). Each store must still see every other store's writes at once.
@MainActor @Suite struct ApplePlaybackStoreSharedStateTests {
    private func withNamespace(_ body: (String) throws -> Void) rethrows {
        let namespace = "shared-state-\(UUID().uuidString)"
        defer {
            let storage = ApplePlaybackBlobStorage.storage(defaults: .standard)
            for base in ["progress", "watched", "unwatched", "continueWatchingRemoved", "terminals", "activity",
                         "availableEpisodes", "versionProgress", "preferredVersion"].map({ "openstream.playback.\($0).v1" })
                + ["openstream.identity.aliases.v1"] {
                let key = AppleTasteNamespace.key(base, namespace: namespace)
                UserDefaults.standard.removeObject(forKey: key)
                let file = storage.fileURL(forKey: key)
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: file.appendingPathExtension("backup"))
            }
        }
        try body(namespace)
    }

    @Test func standardStoresShareOneDecodedCopyPerNamespace() {
        withNamespace { namespace in
            #expect(ApplePlaybackStore.DecodedState.shared(namespace: namespace)
                === ApplePlaybackStore.DecodedState.shared(namespace: namespace))
            #expect(ApplePlaybackStore.DecodedState.shared(namespace: namespace)
                !== ApplePlaybackStore.DecodedState.shared(namespace: namespace + "-other"))
        }
    }

    @Test func eachStoreSeesTheOthersWritesAtOnce() {
        withNamespace { namespace in
            let first = ApplePlaybackStore(namespace: namespace)
            let second = ApplePlaybackStore(namespace: namespace)
            #expect(second.progress(for: "tt0000001") == nil)

            first.save(mediaID: "tt0000001", position: 120, duration: 5400)
            #expect(second.progress(for: "tt0000001")?.position == 120)

            second.save(mediaID: "tt0000001", position: 300, duration: 5400)
            #expect(first.progress(for: "tt0000001")?.position == 300)
            #expect(ApplePlaybackStore(namespace: namespace).progress(for: "tt0000001")?.position == 300)

            second.removeFromContinueWatching(mediaID: "tt0000001")
            #expect(first.isRemovedFromContinueWatching(mediaID: "tt0000001"))
        }
    }

    @Test func aliasesRecordedThroughOneStoreResolveInAnother() {
        withNamespace { namespace in
            let first = ApplePlaybackStore(namespace: namespace)
            let second = ApplePlaybackStore(namespace: namespace)
            first.save(mediaID: "library-old", position: 600, duration: 3600)
            #expect(second.progress(for: "library-new") == nil)
            first.recordIdentityAlias(classID: "c", mediaIDs: ["library-new", "library-old"])
            #expect(second.progress(for: "library-new")?.position == 600)
        }
    }
}
