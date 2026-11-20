import Foundation
import Testing
@testable import OpenStreamApple

/// tvOS may purge local files (Swiftfin's most-reported loss); a pasted
/// playlist cannot be fetched again, so a copy is kept in user defaults.
@Suite("Local playlist survives a storage purge")
struct AppleLocalPlaylistPurgeTests {
    private func makeStore() -> (AppleLocalPlaylistStore, String, URL) {
        let suite = "openstream.tests.playlist.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: "playlist-\(UUID().uuidString)")
        return (AppleLocalPlaylistStore(directory: directory, mirrorSuite: suite), suite, directory)
    }

    @Test func aPurgedPlaylistComesBackFromTheMirror() throws {
        let (store, suite, directory) = makeStore()
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try store.merge(text: "#EXTM3U\n#EXTINF:-1,One\nhttps://fixture.example/one.ts\n")
        try FileManager.default.removeItem(at: directory)
        let text = String(decoding: try store.read(AppleLocalPlaylistStore.pastedURL), as: UTF8.self)
        #expect(text.contains("https://fixture.example/one.ts"))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: AppleLocalPlaylistStore.pastedURL).path))
    }

    @Test func withoutAMirrorAPurgeIsAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "playlist-\(UUID().uuidString)")
        let store = AppleLocalPlaylistStore(directory: directory)
        try store.merge(text: "#EXTM3U\nhttps://fixture.example/one.ts\n")
        try FileManager.default.removeItem(at: directory)
        #expect(throws: (any Error).self) { try store.read(AppleLocalPlaylistStore.pastedURL) }
    }

    @Test func aPlaylistTooBigForTheMirrorIsNotKeptStale() throws {
        let (store, suite, directory) = makeStore()
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try store.merge(text: "#EXTM3U\nhttps://fixture.example/one.ts\n")
        #expect(store.mirrored(AppleLocalPlaylistStore.pastedURL) != nil)
        // Random-ish lines compress poorly, so this passes the limit.
        let big = (0 ..< 40_000).map { _ in "https://fixture.example/\(UUID().uuidString).ts" }.joined(separator: "\n")
        try store.merge(text: big)
        #expect(store.mirrored(AppleLocalPlaylistStore.pastedURL) == nil)
    }
}
