import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Library Unmatched shelf", .serialized)
struct AppleLibraryUnmatchedTests {
    private func file(_ path: String, source: UUID = UUID()) -> AppleLibraryItem {
        .init(sourceID: source, name: (path as NSString).lastPathComponent,
              url: URL(string: "https://fixture.example/movie")!, relativePath: path, sizeBytes: 1)
    }

    private func group(_ item: AppleLibraryItem) throws -> AppleLibrarySeries {
        try #require(AppleLibrarySeries.groups([item]).first)
    }

    @Test func membershipNeedsANoMatchAndNoPublishedMetadata() throws {
        let zebra = try group(file("Zebra.2020.mkv"))
        let apple = try group(file("apple.2021.mkv"))
        let matched = try group(file("Matched.2022.mkv"))
        let unknown = try group(file("Unknown.2023.mkv"))
        let members = AppleLibraryUnmatchedPolicy.members([zebra, matched, unknown, apple],
            metadata: [matched.id: AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Matched")],
            noMatchIDs: [zebra.id, apple.id, matched.id])
        #expect(members.map(\.id) == [apple.id, zebra.id])
    }

    @Test func onlyACachedNoMatchCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = file("Missing.2024.mkv")
        let offline = file("Offline.2024.mkv")
        let found = file("Found.2024.mkv")
        let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _ in
            switch title.title {
            case "Offline": throw URLError(.notConnectedToInternet)
            case "Found": return AppleCatalogItem(mediaID: "tt0000002", type: "movie", name: "Found", releaseInfo: "2024")
            default: return nil
            }
        }
        for item in [missing, offline, found] {
            _ = try await resolver.resolve(item, tmdbKey: "", omdbKey: "")
        }
        let groups = try [missing, offline, found].map(group)
        let lookups = await resolver.cachedLookups(for: groups)
        #expect(lookups.noMatch == [groups[0].id])
        #expect(Set(lookups.metadata.keys) == [groups[2].id])

        try await resolver.correctMatch(for: missing,
            candidate: AppleCatalogItem(mediaID: "tt0000003", type: "movie", name: "Picked"), provider: "manualSearch")
        #expect(await resolver.cachedLookups(for: groups).noMatch.isEmpty)
    }

    @MainActor
    @Test func useAutomaticMatchRestoresTheCachedAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = file("Known.2024.mkv")
        let automatic = AppleCatalogItem(mediaID: "tt0000004", type: "movie", name: "Known", releaseInfo: "2024")
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in automatic }
        #expect(try await resolver.resolve(item, tmdbKey: "", omdbKey: "") == automatic)
        let title = try group(item)
        let store = AppleLocalLibraryStore(resolver: resolver, groups: [title])
        let manual = AppleCatalogItem(mediaID: "tt0000005", type: "movie", name: "Owner Pick")
        try await store.correctMatch(title, candidate: manual, provider: "manualSearch", resolver: resolver)
        let logicalID = try #require(AppleLogicalItemKey.title(kind: .movie, imdb: manual.mediaID, tmdb: nil))
        #expect(await store.hasManualMatch(title))
        #expect(await resolver.matchRecord(logicalID: logicalID)?.isManual == true)
        #expect(store.catalogItem(for: title) == manual)

        try await store.useAutomaticMatch(title)
        #expect(await store.hasManualMatch(title) == false)
        #expect(store.catalogItem(for: title) == automatic)
        #expect(await resolver.matchRecord(logicalID: logicalID) == nil)
        #expect(try await resolver.resolve(item, tmdbKey: "", omdbKey: "") == automatic)
        #expect(store.unmatched.isEmpty)
    }

    @MainActor
    @Test func revertingAMatchedNoMatchPutsItBackOnTheShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = file("Home.Video.2019.mkv")
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in nil }
        #expect(try await resolver.resolve(item, tmdbKey: "", omdbKey: "") == nil)
        let title = try group(item)
        let store = AppleLocalLibraryStore(resolver: resolver, groups: [title])
        try await store.correctMatch(title,
            candidate: AppleCatalogItem(mediaID: "tt0000006", type: "movie", name: "Picked"), provider: "manualSearch", resolver: resolver)
        #expect(store.unmatched.isEmpty)

        try await store.useAutomaticMatch(title)
        #expect(store.metadata[title.id] == nil)
        #expect(store.unmatched.map(\.id) == [title.id])
    }

    /// The E2E Unmatched fixture must cache as a no-match, not an outage:
    /// the E2E simulators keep a TMDB key, so TMDB search needs an answer.
    @Test func e2eUnmatchedFixtureCachesNoMatch() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let stubs = project.appendingPathComponent("Apps/TestPlans/Stubs")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stubs.appendingPathComponent("api.themoviedb.org"),
                                         to: root.appendingPathComponent("api.themoviedb.org"))
        let source = AppleSource(kind: .library, name: "Fixture Library", url: stubs.appendingPathComponent("library-unmatched"))
        let groups = AppleLibrarySeries.groups(try await AppleLibraryScanner().scan(source: source))
        let resolver = AppleLibraryMetadataResolver(directory: root.appendingPathComponent("cache"))
        try await AppleNetworkStub.$testRoot.withValue(root) {
            for group in groups {
                let item = try #require(group.items.first)
                #expect(try await resolver.resolve(item, tmdbKey: "fixture", omdbKey: "") == nil)
            }
        }
        #expect(groups.count == 2)
        #expect(await resolver.cachedLookups(for: groups).noMatch == Set(groups.map(\.id)))
    }
}
