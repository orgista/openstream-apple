import Foundation
import Testing
import Synchronization
@testable import OpenStreamApple

@MainActor @Suite struct AppleIdentityAliasStoreTests {
    private func withStorage(_ directoryBacked: Bool, _ body: (UserDefaults, URL?, ApplePlaybackBlobStorage, String) throws -> Void) throws {
        let suite = "alias-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let directory = directoryBacked ? root : nil
        try body(defaults, directory, ApplePlaybackBlobStorage.storage(defaults: defaults, directory: directory), "fixture-viewer")
    }
    private let first = "sha256:" + String(repeating: "a", count: 64)
    private let second = "sha256:" + String(repeating: "b", count: 64)

    @Test(arguments: [false, true]) func blobKeyIsNamespacedAndStoredThroughBlobStorage(directoryBacked: Bool) throws {
        try withStorage(directoryBacked) { defaults, directory, _, namespace in
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            #expect(store.blobData == nil)
            store.record(classID: "c", members: [second, first])
            let storage = ApplePlaybackBlobStorage.storage(defaults: defaults, directory: directory)
            let key = AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace)
            let bytes = try #require(storage.data(forKey: key))
            #expect(try JSONDecoder().decode(AppleIdentityAliasTable.self, from: bytes).classes == ["c": [first, second]])
            #expect(defaults.data(forKey: "openstream.identity.aliases.v1") == nil)
        }
    }
    @Test(arguments: [false, true]) func malformedBlobReadsEmptyAndIsNotRewritten(directoryBacked: Bool) throws {
        try withStorage(directoryBacked) { defaults, directory, storage, namespace in
            let key = AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace)
            let malformed = Data("\"nope\"".utf8)
            storage.set(malformed, forKey: key)
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            for _ in 0..<10 { #expect(store.members(of: first) == [first]) }
            #expect(store.blobData == malformed)
            #expect(ApplePlaybackBlobStorage.storage(defaults: defaults, directory: directory).data(forKey: key) == malformed)
            store.record(classID: "c", members: [first, second])
            #expect(store.members(of: first) == [first, second])
        }
    }
    @Test(arguments: [false, true]) func recordRejectsNonStorageKeys(directoryBacked: Bool) throws {
        try withStorage(directoryBacked) { defaults, directory, _, namespace in
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            store.record(classID: "c", members: ["tt0903747", first])
            let table = try JSONDecoder().decode(AppleIdentityAliasTable.self, from: #require(store.blobData))
            #expect(table.classes == ["c": [first]])
            store.record(classID: "invalid", members: ["li:movie:tt1"])
            #expect(try JSONDecoder().decode(AppleIdentityAliasTable.self, from: #require(store.blobData)) == table)
        }
    }
    @Test func decodedInvalidMembersPreserveValidClassesWithoutRewriting() throws {
        try withStorage(false) { defaults, directory, storage, namespace in
            let key = AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace)
            let bytes = try JSONEncoder().encode(AppleIdentityAliasTable(classes: ["c": [first, second, "tt1"], "invalid": ["tt2"]]))
            storage.set(bytes, forKey: key)
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            #expect(store.members(of: first) == [first, second])
            #expect(store.blobData == bytes)
            store.record(classID: "new", members: [first])
            let repaired = try JSONDecoder().decode(AppleIdentityAliasTable.self, from: #require(store.blobData))
            #expect(repaired.classes == ["c": [first, second], "new": [first]])
        }
    }
    @Test(arguments: [false, true]) func disabledFlagAnswersRaw(directoryBacked: Bool) throws {
        try withStorage(directoryBacked) { defaults, directory, _, namespace in
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            #expect(store.isEnabled)
            store.record(classID: "c", members: [first, second])
            let bytes = store.blobData
            defaults.set(false, forKey: AppleIdentityAliasStore.enabledKey)
            #expect(store.isEnabled == false)
            #expect(store.members(of: first) == [first])
            #expect(store.blobData == bytes)
            defaults.removeObject(forKey: AppleIdentityAliasStore.enabledKey)
            #expect(store.members(of: first) == [first, second])
        }
    }
    @Test(arguments: [false, true]) func recordPersistsOnlyOnChange(directoryBacked: Bool) throws {
        try withStorage(directoryBacked) { defaults, directory, storage, namespace in
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            store.record(classID: "c", members: [first, second])
            let bytes = store.blobData
            let key = AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace)
            let url = storage.fileURL(forKey: key)
            let sentinel = Date(timeIntervalSince1970: 1234)
            if directoryBacked { try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path) }
            store.record(classID: "c", members: [second, first, first])
            #expect(store.blobData == bytes)
            if directoryBacked {
                #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == sentinel)
            }
        }
    }
    @Test func distinctBlobBytesInvalidateDecodedTable() throws {
        try withStorage(false) { defaults, directory, storage, namespace in
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            store.record(classID: "c", members: [first])
            #expect(store.members(of: first) == [first])
            storage.set(try JSONEncoder().encode(AppleIdentityAliasTable(classes: ["c": [first, second]])),
                forKey: AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace))
            #expect(store.members(of: first) == [first, second])
        }
    }
    @Test func fiveThousandClassesKeepHotReadsCachedAndBytesUnchanged() throws {
        try withStorage(false) { defaults, directory, storage, namespace in
            let pairs = (0..<5000).map { index in
                (ApplePlaybackIdentity.storageKey(for: "fixture-primary-\(index)")!,
                 ApplePlaybackIdentity.storageKey(for: "fixture-alias-\(index)")!)
            }
            let classes = Dictionary(uniqueKeysWithValues: pairs.enumerated().map { index, pair in
                ("fixture-class-\(index)", [pair.0, pair.1])
            })
            let bytes = try JSONEncoder().encode(AppleIdentityAliasTable(classes: classes))
            let key = AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace)
            storage.set(bytes, forKey: key)
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            let clock = ContinuousClock()
            let coldStart = clock.now
            #expect(store.members(of: pairs[0].0) == [pairs[0].0, pairs[0].1])
            let cold = coldStart.duration(to: clock.now)
            let hotStart = clock.now
            for _ in 0..<3 {
                for pair in pairs { #expect(store.members(of: pair.0) == [pair.0, pair.1]) }
            }
            let hot = hotStart.duration(to: clock.now)
            print("Identity alias 5000 classes: cold=\(cold), 15000 hot reads=\(hot)")
            #expect(store.blobData == bytes)
            #expect(storage.data(forKey: key) == bytes)
        }
    }

    @Test func batchPersistsOnceAndUnchangedBatchDoesNotWrite() throws {
        try withStorage(true) { defaults, directory, storage, namespace in
            let store = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            store.record(classID: "seed", members: [first])
            let writes = Mutex(0)
            let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                object: defaults, queue: nil) { _ in writes.withLock { $0 += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }
            store.record([(classID: "a", members: [first]), (classID: "b", members: [second])])
            #expect(writes.withLock { $0 } == 1)
            let key = AppleTasteNamespace.key("openstream.identity.aliases.v1", namespace: namespace)
            let url = storage.fileURL(forKey: key)
            #expect(try JSONDecoder().decode(AppleIdentityAliasTable.self, from: #require(store.blobData)).classes ==
                ["seed": [first], "a": [first], "b": [second]])
            let sentinel = Date(timeIntervalSince1970: 1234)
            try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
            store.record([(classID: "a", members: [first]), (classID: "b", members: [second])])
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == sentinel)
            #expect(writes.withLock { $0 } == 1)
        }
    }
    @Test(arguments: [false, true]) func episodeCopiesStaySeparateAfterRename(directoryBacked: Bool) throws {
        try withStorage(directoryBacked) { defaults, directory, _, namespace in
            let store = ApplePlaybackStore(defaults: defaults, namespace: namespace, blobDirectory: directory)
            let old = "local-file-copy-a"
            let renamed = "local-file-copy-a-renamed"
            let copy = "local-file-copy-b"
            let positional = "tt1:1:1"
            store.recordIdentityAliases([
                (classID: "li:series:tt1:1:1:1000", mediaIDs: [old]),
                (classID: "li:series:tt1:1:1:2000", mediaIDs: [copy]),
                (classID: "le:" + old, mediaIDs: [old, positional])])
            store.recordIdentityAliases([
                (classID: "li:series:tt1:1:1:1000", mediaIDs: [old, renamed]),
                (classID: "le:" + copy, mediaIDs: [copy, positional]),
                (classID: "le:" + renamed, mediaIDs: [renamed, positional])])
            store.save(mediaID: copy, position: 900, duration: 3600)
            #expect(store.progress(for: renamed) == nil)
            store.save(mediaID: old, position: 600, duration: 3600)
            #expect(store.progress(for: renamed)?.position == 600)
            #expect(store.progress(for: copy)?.position == 900)
            store.markWatched(mediaID: old)
            #expect(store.isWatched(mediaID: renamed))
            #expect(store.isWatched(mediaID: copy) == false)
            store.removeFromContinueWatching(mediaID: copy)
            #expect(store.isRemovedFromContinueWatching(mediaID: renamed) == false)
        }
    }

}
