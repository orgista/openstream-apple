import Foundation
import Testing
@testable import OpenStreamApple

@MainActor struct ApplePlaybackAliasFixture {
    let defaults: UserDefaults
    let store: ApplePlaybackStore
    let oldID = "library-old"
    let newID = "library-new"
    var oldKey: String { ApplePlaybackIdentity.storageKey(for: oldID)! }
    var newKey: String { ApplePlaybackIdentity.storageKey(for: newID)! }

    func alias(_ present: Bool) {
        if present { store.recordIdentityAlias(classID: "c", mediaIDs: [newID, oldID]) }
    }

    static func run(_ body: (Self) throws -> Void) throws {
        let suite = "playback-alias-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(Self(defaults: defaults, store: ApplePlaybackStore(defaults: defaults)))
    }

    func rawBlobs() -> [String: Data] {
        defaults.dictionaryRepresentation().compactMapValues { $0 as? Data }
            .filter { $0.key != "openstream.identity.aliases.v1" }
    }

    func copyWithoutAliases() throws -> (defaults: UserDefaults, suite: String, store: ApplePlaybackStore) {
        let suite = "playback-alias-copy-\(UUID())"
        let copy = try #require(UserDefaults(suiteName: suite))
        for (key, value) in rawBlobs() { copy.set(value, forKey: key) }
        return (copy, suite, ApplePlaybackStore(defaults: copy))
    }

    func populate() {
        store.restoreConfigurationProgress([
            oldKey: .init(position: 600, duration: 3600, updatedAt: Date(timeIntervalSince1970: 100)),
            newKey: .init(position: 900, duration: 3600, updatedAt: Date(timeIntervalSince1970: 200))])
        store.markWatched(mediaID: oldID, at: Date(timeIntervalSince1970: 300))
        store.markUnwatched(mediaID: newID, at: Date(timeIntervalSince1970: 400))
        store.removeFromContinueWatching(mediaID: oldID, at: Date(timeIntervalSince1970: 500))
    }

    func expectRawAccessorsEqual(_ other: ApplePlaybackStore, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(store.configurationProgress() == other.configurationProgress(), sourceLocation: sourceLocation)
        #expect(store.configurationWatchedHistory() == other.configurationWatchedHistory(), sourceLocation: sourceLocation)
        #expect(store.configurationWatchedTombstones() == other.configurationWatchedTombstones(), sourceLocation: sourceLocation)
        #expect(store.configurationContinueWatchingRemovals() == other.configurationContinueWatchingRemovals(), sourceLocation: sourceLocation)
        #expect(store.configurationPlaybackTerminals() == other.configurationPlaybackTerminals(), sourceLocation: sourceLocation)
        #expect(store.configurationPlaybackActivity() == other.configurationPlaybackActivity(), sourceLocation: sourceLocation)
        #expect(store.savedProgress() == other.savedProgress(), sourceLocation: sourceLocation)
        #expect(store.completionProgress() == other.completionProgress(), sourceLocation: sourceLocation)
        #expect(store.activities() == other.activities(), sourceLocation: sourceLocation)
    }
}

@MainActor @Suite struct ApplePlaybackStoreAliasTests {
    @Test(arguments: [false, true]) func renamedFileResumesFromOldKey(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.save(mediaID: f.oldID, position: 600, duration: 3600)
            f.alias(aliasBlobPresent)
            let before = f.rawBlobs()
            #expect(f.store.progress(for: f.newID)?.position == (aliasBlobPresent ? 600 : nil))
            #expect(f.rawBlobs() == before)
        }
    }
    @Test(arguments: [false, true]) func saveWritesOnlyTheAskedKey(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.save(mediaID: f.oldID, position: 600, duration: 3600)
            let old = try #require(f.store.configurationProgress()[f.oldKey])
            let bytes = try AppleConfigurationSnapshot.encoder.encode(old)
            f.alias(aliasBlobPresent)
            f.store.save(mediaID: f.newID, position: 900, duration: 3600)
            #expect(f.store.configurationProgress()[f.newKey]?.position == 900)
            #expect(f.store.configurationProgress()[f.oldKey] == old)
            let unchanged = try #require(f.store.configurationProgress()[f.oldKey])
            #expect(try AppleConfigurationSnapshot.encoder.encode(unchanged) == bytes)
            #expect(f.store.progress(for: f.oldID)?.position == (aliasBlobPresent ? 900 : 600))
            #expect(Set(f.store.configurationProgress().keys) == [f.oldKey, f.newKey])
        }
    }
    @Test(arguments: [false, true]) func unwatchHidesTheOldKeysTick(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.markWatched(mediaID: f.oldID)
            f.alias(aliasBlobPresent)
            #expect(f.store.isWatched(mediaID: f.newID) == aliasBlobPresent)
            f.store.markUnwatched(mediaID: f.newID)
            #expect(f.store.isWatched(mediaID: f.newID) == false)
            #expect(f.store.isWatched(mediaID: f.oldID) == (aliasBlobPresent == false))
            let reset = try #require(f.store.configurationWatchedTombstones()[f.newKey])
            #expect(reset > f.store.configurationWatchedHistory()[f.oldKey]!)
        }
    }
    @Test(arguments: [false, true]) func unwatchClockBeatsAFutureOldWatchedDate(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            let future = Date.now.addingTimeInterval(3600)
            f.store.markWatched(mediaID: f.oldID, at: future)
            f.alias(aliasBlobPresent)
            f.store.markUnwatched(mediaID: f.newID)
            #expect(f.store.isWatched(mediaID: f.newID) == false)
            #expect(f.store.isWatched(mediaID: f.oldID) == (aliasBlobPresent == false))
            let reset = try #require(f.store.configurationWatchedTombstones()[f.newKey])
            #expect((reset > future) == aliasBlobPresent)
        }
    }
    @Test(arguments: [false, true]) func saveClockBeatsFutureOldPlayedAndRemovalDates(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            let future = Date.now.addingTimeInterval(3600)
            f.store.restoreConfigurationPlaybackTerminals([f.oldKey: .init(removedAt: future, playedAt: future.addingTimeInterval(-1))])
            f.alias(aliasBlobPresent)
            f.store.save(mediaID: f.newID, position: 900, duration: 3600)
            let saved = try #require(f.store.configurationProgress()[f.newKey])
            #expect((saved.updatedAt > future) == aliasBlobPresent)
            #expect(f.store.isRemovedFromContinueWatching(mediaID: f.newID) == false)
        }
    }
    @Test(arguments: [false, true]) func removalHonoursTheOldKeyAndALaterSaveLiftsIt(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.removeFromContinueWatching(mediaID: f.oldID)
            f.alias(aliasBlobPresent)
            #expect(f.store.isRemovedFromContinueWatching(mediaID: f.newID) == aliasBlobPresent)
            f.store.save(mediaID: f.newID, position: 900, duration: 3600)
            #expect(f.store.isRemovedFromContinueWatching(mediaID: f.newID) == false)
            let data = try #require(f.defaults.data(forKey: "openstream.playback.continueWatchingRemoved.v1"))
            let raw = try JSONDecoder().decode([String: Date].self, from: data)
            #expect(raw[f.oldKey] != nil)
            #expect(raw[f.newKey] == nil)
        }
    }
    @Test(arguments: [false, true]) func lastActivityAndHasStateSeeTheClass(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.save(mediaID: f.oldID, position: 600, duration: 3600)
            f.alias(aliasBlobPresent)
            #expect(f.store.lastActivity(for: f.newID)?.position == (aliasBlobPresent ? 600 : nil))
            #expect(f.store.hasLocalPlaybackState(mediaID: f.newID) == aliasBlobPresent)
            #expect(f.store.localPlaybackUpdatedAt(mediaID: f.newID) == (aliasBlobPresent ? f.store.localPlaybackUpdatedAt(mediaID: f.oldID) : nil))
        }
    }
    @Test(arguments: [false, true]) func completedMediaIDsAgreesWithLegacyEpisodeLookup(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            let source = UUID()
            let files = ["Show.S01E01.mkv", "Bonus.mkv"].map {
                AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0), relativePath: "Shows/Show/Season 1/" + $0, sizeBytes: 1)
            }
            var group = AppleLibrarySeries.groups(files)[0]
            group.items = files
            let rows = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt1", enriched: [])
            let current = AppleLocalLibraryStore.fileEpisodeID(files[1])
            let legacy = "tt1:1:2"
            f.store.markWatched(mediaID: legacy)
            let expected = AppleLocalLibraryStore.completedEpisodeIDs(rows, group: group, mediaID: "tt1", store: f.store)
            if aliasBlobPresent {
                f.store.recordIdentityAlias(classID: AppleLogicalItemKey.legacyEpisodeClass(fileEpisodeID: current), mediaIDs: [current, legacy])
            } else {
                ApplePlaybackBlobStorage.storage(defaults: f.defaults).removeObject(forKey: "openstream.identity.aliases.v1")
            }
            let actual = f.store.completedMediaIDs(among: rows.map(\.id))
            #expect(actual == (aliasBlobPresent ? expected : []))
            #expect(expected == [current])
        }
    }
    @Test(arguments: [false, true]) func partIDResolvesThroughTheClass(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.save(mediaID: "show", position: 3600, duration: 3600, partID: "tt1:1:2")
            if aliasBlobPresent { f.store.recordIdentityAlias(classID: "part", mediaIDs: ["tt1:1:2", f.newID]) }
            #expect(f.store.completedMediaIDs(among: [f.newID]) == (aliasBlobPresent ? [f.newID] : []))
        }
    }
    @Test(arguments: [false, true]) func rawAccessorsNeverMerge(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.populate()
            f.alias(aliasBlobPresent)
            let before = f.rawBlobs()
            let other = try f.copyWithoutAliases()
            defer { other.defaults.removePersistentDomain(forName: other.suite) }
            f.expectRawAccessorsEqual(other.store)
            #expect(f.rawBlobs() == before)
            #expect(other.defaults.dictionaryRepresentation().compactMapValues { $0 as? Data } == before)
        }
    }
    @Test(arguments: [false, true]) func fingerprintIncludesTheAliasBlob(aliasBlobPresent: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.removeFromContinueWatching(mediaID: f.oldID)
            _ = f.store.configurationPlaybackTerminals()
            #expect(f.store.isRemovedFromContinueWatching(mediaID: f.newID) == false)
            f.alias(aliasBlobPresent)
            #expect(f.store.isRemovedFromContinueWatching(mediaID: f.newID) == aliasBlobPresent)
        }
    }
    @Test func singletonLegacyTombstoneWinsOverNewerRawWatchedDate() throws {
        try ApplePlaybackAliasFixture.run { f in
            let watched = [f.oldKey: Date(timeIntervalSince1970: 200)]
            let unwatched = [f.oldKey: Date(timeIntervalSince1970: 100)]
            f.defaults.set(try JSONEncoder().encode(watched), forKey: "openstream.playback.watched.v1")
            f.defaults.set(try JSONEncoder().encode(unwatched), forKey: "openstream.playback.unwatched.v1")
            #expect(f.store.completedMediaIDs(among: [f.oldID]).isEmpty)
            f.store.recordIdentityAlias(classID: "singleton", mediaIDs: [f.oldID])
            #expect(f.store.completedMediaIDs(among: [f.oldID]).isEmpty)
        }
    }

}

/// The Top Shelf reads every title from a copy of the maps, off the main
/// actor: it must answer exactly as the store does.
@MainActor @Suite struct ApplePlaybackReadStateTests {
    @Test(arguments: [false, true]) func readStateAnswersAsTheStore(aliased: Bool) throws {
        try ApplePlaybackAliasFixture.run { f in
            f.populate()
            f.alias(aliased)
            f.store.save(mediaID: "library-other", position: 120, duration: 3600)
            let state = f.store.readState()
            for id in [f.oldID, f.newID, "library-other", "library-never"] {
                #expect(state.progress(for: id) == f.store.progress(for: id), "\(id)")
                #expect(state.lastActivity(for: id) == f.store.lastActivity(for: id), "\(id)")
                #expect(state.isRemovedFromContinueWatching(mediaID: id)
                        == f.store.isRemovedFromContinueWatching(mediaID: id), "\(id)")
            }
            #expect(state.progress(for: "library-other")?.position == 120)
            #expect(state.isRemovedFromContinueWatching(mediaID: f.oldID))
        }
    }
}
