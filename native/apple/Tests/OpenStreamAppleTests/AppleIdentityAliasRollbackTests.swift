import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Suite struct AppleIdentityAliasRollbackTests {
    private func expectPublicLookupsEqual(_ store: ApplePlaybackStore, _ raw: ApplePlaybackStore,
                                         ids: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for id in ids {
            #expect(store.progress(for: id) == raw.progress(for: id), sourceLocation: sourceLocation)
            #expect(store.lastActivity(for: id) == raw.lastActivity(for: id), sourceLocation: sourceLocation)
            #expect(store.isWatched(mediaID: id) == raw.isWatched(mediaID: id), sourceLocation: sourceLocation)
            #expect(store.isRemovedFromContinueWatching(mediaID: id) == raw.isRemovedFromContinueWatching(mediaID: id), sourceLocation: sourceLocation)
            #expect(store.hasLocalPlaybackState(mediaID: id) == raw.hasLocalPlaybackState(mediaID: id), sourceLocation: sourceLocation)
            #expect(store.localPlaybackUpdatedAt(mediaID: id) == raw.localPlaybackUpdatedAt(mediaID: id), sourceLocation: sourceLocation)
        }
        #expect(store.completedMediaIDs(among: ids) == raw.completedMediaIDs(among: ids), sourceLocation: sourceLocation)
        let url = URL(fileURLWithPath: "/fixture-file.mkv")
        #expect(store.progress(for: url) == raw.progress(for: url), sourceLocation: sourceLocation)
    }

    @Test func flagOffReadsAsToday() throws {
        try ApplePlaybackAliasFixture.run { f in
            f.populate()
            let url = URL(fileURLWithPath: "/fixture-file.mkv")
            f.store.save(url: url, position: 120, duration: 3600)
            let before = f.rawBlobs()
            let copy = try f.copyWithoutAliases()
            defer { copy.defaults.removePersistentDomain(forName: copy.suite) }
            f.alias(true)
            let aliasBytes = try #require(f.defaults.data(forKey: "openstream.identity.aliases.v1"))
            #expect(f.store.progress(for: f.oldID)?.position == 900)
            f.defaults.set(false, forKey: AppleIdentityAliasStore.enabledKey)
            expectPublicLookupsEqual(f.store, copy.store, ids: [f.oldID, f.newID, f.oldKey, f.newKey, "missing"])
            f.expectRawAccessorsEqual(copy.store)
            #expect(f.rawBlobs() == before)
            #expect(f.defaults.data(forKey: "openstream.identity.aliases.v1") == aliasBytes)
            #expect(copy.defaults.dictionaryRepresentation().compactMapValues { $0 as? Data } == before)
        }
    }

    @Test func deletedBlobReadsAsToday() throws {
        try ApplePlaybackAliasFixture.run { f in
            f.populate()
            let before = f.rawBlobs()
            let copy = try f.copyWithoutAliases()
            defer { copy.defaults.removePersistentDomain(forName: copy.suite) }
            f.alias(true)
            #expect(f.store.progress(for: f.oldID)?.position == 900)
            ApplePlaybackBlobStorage.storage(defaults: f.defaults).removeObject(forKey: "openstream.identity.aliases.v1")
            expectPublicLookupsEqual(f.store, copy.store, ids: [f.oldID, f.newID, f.oldKey, f.newKey, "missing"])
            f.expectRawAccessorsEqual(copy.store)
            #expect(f.rawBlobs() == before)
            #expect(f.defaults.data(forKey: "openstream.identity.aliases.v1") == nil)
        }
    }

    @Test func deletedDirectoryBlobReopensWithRawAnswersAndUnchangedPlaybackBytes() throws {
        let suite = "alias-directory-rollback-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
        store.restoreConfigurationProgress(["library-old": .init(position: 600, duration: 3600, updatedAt: Date(timeIntervalSince1970: 100))])
        store.markWatched(mediaID: "library-old", at: Date(timeIntervalSince1970: 50))
        store.removeFromContinueWatching(mediaID: "library-old", at: Date(timeIntervalSince1970: 300))
        let aliasKey = "openstream.identity.aliases.v1"
        let storage = ApplePlaybackBlobStorage.storage(defaults: defaults, directory: root)
        let blobKeys = ["progress", "activity", "watched", "unwatched", "continueWatchingRemoved", "terminals"]
            .map { "openstream.playback.\($0).v1" }
        var before: [String: Data] = [:]
        for key in blobKeys { before[key] = storage.data(forKey: key) }
        let raw = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
        #expect(raw.progress(for: "library-old")?.position == 600)
        #expect(raw.progress(for: "library-new") == nil)
        store.recordIdentityAlias(classID: "c", mediaIDs: ["library-old", "library-new"])
        #expect(store.progress(for: "library-new")?.position == 600)
        storage.removeObject(forKey: aliasKey)
        let reopened = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
        expectPublicLookupsEqual(reopened, raw, ids: ["library-old", "library-new", "missing"])
        let afterStorage = ApplePlaybackBlobStorage.storage(defaults: defaults, directory: root)
        for key in blobKeys { #expect(afterStorage.data(forKey: key) == before[key]) }
    }

    @Test func overlappingClassesResolveInTheStoreAndKeepEveryEvidenceClass() throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.save(mediaID: f.oldID, position: 600, duration: 3600)
            f.alias(true)
            f.store.recordIdentityAlias(classID: "legacy", mediaIDs: [f.newID, "positional"])
            f.store.recordIdentityAlias(classID: "third", mediaIDs: ["positional", "last"])
            #expect(f.store.progress(for: "last")?.position == 600)
            #expect(f.store.lastActivity(for: "last")?.position == 600)
            let data = try #require(f.defaults.data(forKey: "openstream.identity.aliases.v1"))
            let table = try JSONDecoder().decode(AppleIdentityAliasTable.self, from: data)
            #expect(Set(table.classes.keys) == ["c", "legacy", "third"])
            #expect(table.classes.values.allSatisfy { $0.count == 2 })
            f.defaults.set(false, forKey: AppleIdentityAliasStore.enabledKey)
            #expect(f.store.progress(for: "last") == nil)
            #expect(f.defaults.data(forKey: "openstream.identity.aliases.v1") == data)
        }
    }
}
