import Foundation
import Testing
@testable import OpenStreamApple

@Test func mediaIndexMergesCanonicalAvailabilityAndRemovesOneInstanceTransactionally() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "index.json")
    let repository = AppleMediaIndexRepository(fileURL: url)
    let first = UUID()
    let second = UUID()
    let one = AppleMediaRecord(
        canonicalID: "tt1234567",
        kind: .movie,
        title: "A Movie",
        availability: [.init(instanceID: first, capability: .resolvable, itemReference: "movie|tt1234567")]
    )
    let two = AppleMediaRecord(
        canonicalID: "TT1234567",
        kind: .movie,
        title: "A Movie Updated",
        availability: [.init(instanceID: second, capability: .direct, itemReference: "private locator")]
    )

    try await repository.replace(instanceID: first, with: [one])
    try await repository.replace(instanceID: second, with: [two])
    var records = await repository.records()
    #expect(records.count == 1)
    #expect(records[0].availability.map(\.instanceID) == [first, second].sorted { $0.uuidString < $1.uuidString })
    #expect(records[0].availability.allSatisfy { !$0.itemReference.contains("private locator") })

    try await repository.remove(instanceID: first)
    records = await repository.records()
    #expect(records.count == 1)
    #expect(records[0].availability.map(\.instanceID) == [second])

    try await repository.remove(instanceID: second)
    #expect(await repository.records().isEmpty)
}

@Test func mediaIndexSearchIsDeterministicAndPersistenceContainsNoLocalPath() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-search-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "index.json")
    let repository = AppleMediaIndexRepository(fileURL: url)
    let sourceID = UUID()
    let record = AppleMediaRecord(
        kind: .video,
        title: "Amélie Holiday Cut",
        aliases: ["Le Fabuleux Destin"],
        artworkURL: URL(fileURLWithPath: "/Volumes/Private/poster.jpg"),
        availability: [.init(
            instanceID: sourceID,
            capability: .direct,
            itemReference: "/Volumes/Private/Movies/Amelie.mp4"
        )],
        isPrivate: true
    )
    try await repository.replace(instanceID: sourceID, with: [record])

    #expect(await repository.search("amelie holiday").map(\.id) == [record.id])
    #expect(await repository.search("fabuleux").map(\.id) == [record.id])
    let persisted = try String(decoding: Data(contentsOf: url), as: UTF8.self)
    #expect(!persisted.contains("/Volumes/Private"))
}

@Test func mediaIndexSearchAppliesItsLimitInStableTitleOrderAcrossReloads() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-ordered-search-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "index.json")
    let sourceID = UUID()
    let records = (0 ..< 250).reversed().map { value in
        AppleMediaRecord(
            canonicalID: "search-\(value)",
            kind: .channel,
            title: "Search Channel \(String(format: "%03d", value))",
            availability: [.init(
                instanceID: sourceID,
                capability: .direct,
                itemReference: "channel-\(value)"
            )]
        )
    }
    let expected = (0 ..< 5).map { "Search Channel \(String(format: "%03d", $0))" }

    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.replace(instanceID: sourceID, with: records)
    #expect(await repository.search("search channel", limit: 5).map(\.title) == expected)

    let reloaded = AppleMediaIndexRepository(fileURL: url)
    #expect(await reloaded.search("search channel", limit: 5).map(\.title) == expected)
}

@Test func appRouterAcceptsOnlyOpaqueOpenStreamRoutes() throws {
    #expect(AppleAppRoute(url: URL(string: "openstream://search?query=Man%20of%20Steel")!) == .search("Man of Steel"))
    let opaqueID = String(repeating: "a", count: 64)
    #expect(AppleAppRoute(url: URL(string: "openstream://media/\(opaqueID)?action=play")!) ==
        .media(id: opaqueID, action: .play))
    #expect(AppleAppRoute(url: URL(string: "openstream://continue")!) == .continueWatching)
    #expect(AppleAppRoute(url: URL(string: "https://media/\(opaqueID)?action=play")!) == nil)
    #expect(AppleAppRoute(url: URL(string: "openstream://media/smb:%2F%2Fprivate/path?action=play")!) == nil)
    #expect(AppleAppRoute(url: URL(string: "openstream://search?query=")!) == nil)
}

@Test func mediaIndexPurgesDisabledAndRemovedInstanceAvailability() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-retain-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = AppleMediaIndexRepository(fileURL: root.appending(path: "index.json"))
    let enabled = UUID()
    let disabled = UUID()
    let record = AppleMediaRecord(
        canonicalID: "tt7654321",
        kind: .movie,
        title: "Retained Movie",
        availability: [
            .init(instanceID: enabled, capability: .resolvable, itemReference: "enabled"),
            .init(instanceID: disabled, capability: .direct, itemReference: "disabled"),
        ]
    )
    try await repository.replace(instanceID: enabled, with: [record])
    try await repository.replace(instanceID: disabled, with: [record])

    try await repository.retainAvailability(for: [enabled])
    let retained = try #require(await repository.records().first)
    #expect(retained.availability.map(\.instanceID) == [enabled])

    try await repository.retainAvailability(for: [])
    #expect(await repository.records().isEmpty)
}

@Test func mediaIndexPersistsLikesAndRecommendationsUseThoseSignals() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-favorites-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "index.json")
    let repository = AppleMediaIndexRepository(fileURL: url)
    let preferredSource = UUID()
    let otherSource = UUID()
    let availability: (UUID, String) -> AppleMediaAvailability = { source, reference in
        .init(instanceID: source, capability: .resolvable, itemReference: reference)
    }
    let liked = AppleMediaRecord(
        canonicalID: "tt0000001",
        kind: .movie,
        title: "Liked Movie",
        availability: [availability(preferredSource, "liked")]
    )
    let sameSource = AppleMediaRecord(
        canonicalID: "tt0000002",
        kind: .movie,
        title: "Same Source",
        year: 2026,
        availability: [availability(preferredSource, "same")]
    )
    let otherMovie = AppleMediaRecord(
        canonicalID: "tt0000003",
        kind: .movie,
        title: "Other Movie",
        year: 2027,
        availability: [availability(otherSource, "other")]
    )
    let wrongKind = AppleMediaRecord(
        canonicalID: "tt0000004",
        kind: .series,
        title: "Wrong Kind",
        availability: [availability(preferredSource, "series")]
    )

    try await repository.replace(instanceID: preferredSource, with: [liked, sameSource, wrongKind])
    try await repository.replace(instanceID: otherSource, with: [otherMovie])
    try await repository.setFavorite(true, recordID: liked.id)

    let persisted = try #require(await AppleMediaIndexRepository(fileURL: url).records().first { $0.id == liked.id })
    #expect(persisted.isFavorite)
    let recommendations = AppleMediaRecommendationPolicy.recommendations(from: await repository.records())
    #expect(recommendations.map(\.id) == [sameSource.id, otherMovie.id])
    #expect(!recommendations.contains(where: { $0.id == wrongKind.id || $0.id == liked.id }))
    let releases = AppleMediaRecommendationPolicy.newReleases(
        from: await repository.records(),
        currentYear: 2026
    )
    #expect(releases.map(\.id) == [otherMovie.id, sameSource.id])
    let popular = AppleMediaRecommendationPolicy.popular(from: await repository.records())
    #expect(popular.map(\.id) == [liked.id, otherMovie.id, sameSource.id, wrongKind.id])
}

@Test func mediaIndexRefreshPreservesSingleSourceUserState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = AppleMediaIndexRepository(fileURL: root.appending(path: "index.json"))
    let sourceID = UUID()
    let original = AppleMediaRecord(
        canonicalID: "tt1234567",
        kind: .movie,
        title: "Original",
        availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "old")]
    )
    try await repository.replace(instanceID: sourceID, with: [original])
    try await repository.setFavorite(true, recordID: original.id)
    try await repository.updateProgress([original.id: 0.42])

    let refreshed = AppleMediaRecord(
        canonicalID: "tt1234567",
        kind: .movie,
        title: "Refreshed",
        availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "new")]
    )
    try await repository.replace(instanceID: sourceID, with: [refreshed])

    let result = try #require(await repository.records().first)
    #expect(result.title == "Refreshed")
    #expect(result.isFavorite)
    #expect(result.progress == 0.42)
}

@Test func catalogRefreshKeepsOpenedSearchTitlesAndFavoritesUntilSourceRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = AppleMediaIndexRepository(fileURL: root.appendingPathComponent("index.json"))
    let source = UUID()
    let searched = AppleMediaRecord(canonicalID: "tt12345678", kind: .movie, title: "Search-only title",
        availability: [.init(instanceID: source, capability: .resolvable, itemReference: "movie|tt12345678")])
    try await repository.upsert(searched)
    try await repository.setFavorite(true, recordID: searched.id)
    try await repository.replaceCatalog(instanceID: source, with: [])
    let saved = try #require(await repository.records().first)
    #expect(saved.id == searched.id)
    #expect(saved.isFavorite)
    try await repository.retainAvailability(for: [])
    #expect(await repository.records().isEmpty)
}

@Test func mediaIndexQuarantinesCorruptDataBeforeWritingAgain() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-corrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "index.json")
    try Data("not-json".utf8).write(to: url)

    let repository = AppleMediaIndexRepository(fileURL: url)
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix("index.json.corrupt-") }
    #expect(quarantined.count == 1)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let sourceID = UUID()
    let replacement = AppleMediaRecord(
        kind: .movie,
        title: "Recovered",
        availability: [.init(instanceID: sourceID, capability: .direct, itemReference: "replacement")]
    )
    try await repository.replace(instanceID: sourceID, with: [replacement])
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func mediaIndexDoesNotOverwriteANewerVersion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-future-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "index.json")
    let future = Data(#"{"version":2,"records":[]}"#.utf8)
    try future.write(to: url)
    let repository = AppleMediaIndexRepository(fileURL: url)

    do {
        try await repository.replace(instanceID: UUID(), with: [])
        Issue.record("Expected a newer index version to block writes")
    } catch {
        #expect(error as? AppleMediaIndexError == .unsupportedVersion(2))
    }
    #expect(try Data(contentsOf: url) == future)
}

@Test func localMediaIdentityIncludesItsSourceRelativeIdentity() {
    let source = AppleSource(kind: .library, name: "Library", url: URL(fileURLWithPath: "/tmp"))
    let first = AppleLibraryItem(sourceID: source.id, name: "Episode 01.mkv", url: URL(fileURLWithPath: "/tmp/one.mkv"), relativePath: "Season 1/Episode 01.mkv", sizeBytes: 1)
    let second = AppleLibraryItem(sourceID: source.id, name: "Episode 01.mkv", url: URL(fileURLWithPath: "/tmp/two.mkv"), relativePath: "Season 2/Episode 01.mkv", sizeBytes: 1)
    #expect(AppleMediaIngestion.libraryRecord(source: source, item: first).id != AppleMediaIngestion.libraryRecord(source: source, item: second).id)

    let channelOne = AppleIPTVChannel(id: "one", sourceID: source.id, name: "News", group: "News", logoURL: nil, streamURL: URL(string: "https://example.com/one.m3u8")!)
    let channelTwo = AppleIPTVChannel(id: "two", sourceID: source.id, name: "News", group: "News", logoURL: nil, streamURL: URL(string: "https://example.com/two.m3u8")!)
    #expect(AppleMediaIngestion.channelRecord(source: source, channel: channelOne).id != AppleMediaIngestion.channelRecord(source: source, channel: channelTwo).id)
}

@Test func topShelfSnapshotIsBoundedAndUsesOnlyOpaqueDeepLinks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-topshelf-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let instanceID = UUID()
    let records = (0 ..< 30).map { index in
        AppleMediaRecord(
            canonicalID: "tt\(String(format: "%07d", index))",
            kind: .movie,
            title: "Movie \(index)",
            availability: [.init(
                instanceID: instanceID,
                capability: .resolvable,
                itemReference: "smb://private/Movies/Movie \(index).mkv"
            )],
            isFavorite: true,
            progress: 0.5,
            isPrivate: false
        )
    }
    let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
    try await writer.write(records: records, enabled: true)

    let data = try Data(contentsOf: root.appending(path: AppleTopShelfSnapshotWriter.filename))
    let snapshot = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: data)
    #expect(snapshot.continueWatching.count == 12)
    #expect(snapshot.recentlyAdded.count == 20)
    #expect(snapshot.favorites.count == 12)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("smb://"))
    #expect(snapshot.continueWatching.allSatisfy { item in
        item.displayURL.scheme == "openstream"
            && item.displayURL.host == "media"
            && item.id.count == 64
    })

    try await writer.write(records: records, enabled: false)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: AppleTopShelfSnapshotWriter.filename).path))
}

@Test func topShelfSnapshotRoundTripsTopPicks() throws {
    let item = AppleTopShelfSnapshot.Item(
        id: String(repeating: "a", count: 64),
        title: "Top Pick",
        kind: "movie",
        artworkURL: URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"),
        displayURL: URL(string: "openstream://media/\(String(repeating: "a", count: 64))?action=display")!,
        playURL: nil
    )
    let snapshot = AppleTopShelfSnapshot(
        version: 1,
        generatedAt: .now,
        continueWatching: [],
        recentlyAdded: [],
        favorites: [],
        topPicks: [item]
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: data)
    #expect(decoded.topPicks == [item])
}

@Test func topShelfSnapshotDecodesLegacyPayloadsMissingTopPicksAsEmpty() throws {
    let legacyJSON = """
    {"version":1,"generatedAt":0,"continueWatching":[],"recentlyAdded":[],"favorites":[]}
    """
    let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(legacyJSON.utf8))
    #expect(decoded.topPicks.isEmpty)
}

@Test func topShelfSnapshotWriterBuildsTopPicksFromTheFirstNonEmptyCatalogShelf() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-topshelf-picks-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = AppleSource(
        kind: .stremio,
        name: "Cinemeta",
        url: URL(string: "https://example.com/manifest.json")!
    )
    let emptyCatalog = AppleStremioCatalog(type: "movie", id: "empty")
    let popularCatalog = AppleStremioCatalog(type: "movie", id: "top")
    let items = (0 ..< 15).map { index in
        AppleCatalogItem(
            mediaID: "tt\(String(format: "%07d", index))",
            type: "movie",
            name: "Popular \(index)",
            posterURL: URL(string: "https://image.tmdb.org/t/p/w500/\(index).jpg")
        )
    }
    let sections = [
        AppleCatalogSection(source: source, catalog: emptyCatalog, items: []),
        AppleCatalogSection(source: source, catalog: popularCatalog, items: items),
    ]

    let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
    try await writer.write(records: [], sections: sections, enabled: true)

    let data = try Data(contentsOf: root.appending(path: AppleTopShelfSnapshotWriter.filename))
    let snapshot = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: data)
    #expect(snapshot.topPicks.count == 10)
    #expect(snapshot.topPicks.allSatisfy { $0.displayURL.host == "media" && $0.id.count == 64 })
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("tt0000000"))
}

@Test func topShelfContentBuilderOrdersContinueWatchingBeforeTopPicksAndNilsWhenEmpty() {
    func makeItem(_ id: String) -> AppleTopShelfSnapshot.Item {
        .init(
            id: id, title: id, kind: "movie", artworkURL: nil,
            displayURL: URL(string: "openstream://media/\(id)?action=display")!, playURL: nil
        )
    }
    let watching = [makeItem("watching")]
    let picks = [makeItem("pick")]

    let none = AppleTopShelfSnapshot(version: 1, generatedAt: .now, continueWatching: [], recentlyAdded: [], favorites: [])
    #expect(AppleTopShelfContentBuilder.sections(for: none).isEmpty)

    let onlyPicks = AppleTopShelfSnapshot(
        version: 1, generatedAt: .now, continueWatching: [], recentlyAdded: [], favorites: [], topPicks: picks
    )
    #expect(AppleTopShelfContentBuilder.sections(for: onlyPicks).map(\.title) == ["Top Picks"])

    let both = AppleTopShelfSnapshot(
        version: 1, generatedAt: .now, continueWatching: watching, recentlyAdded: [], favorites: [], topPicks: picks
    )
    #expect(AppleTopShelfContentBuilder.sections(for: both).map(\.title) == ["Continue Watching", "Top Picks"])
}

@Test func systemArtworkPolicyRejectsCredentialBearingAndUntrustedURLs() {
    let trusted = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
    #expect(AppleSystemArtworkPolicy.publicURL(trusted) == trusted)
    #expect(AppleSystemArtworkPolicy.publicURL(
        URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg?token=secret")!
    ) == nil)
    // Was asserted as rejected when the policy was a two-host allowlist. That
    // allowlist is what emptied the owner's Continue Watching shelf on
    // 2026-09-16: add-ons serve posters from their own CDNs. A public https
    // host with no credentials and no query is now allowed; see
    // AppleSystemArtworkPolicyTests.
    #expect(AppleSystemArtworkPolicy.publicURL(
        URL(string: "https://addon.example/private-token/poster.jpg")!
    ) != nil)
    #expect(AppleSystemArtworkPolicy.publicURL(
        URL(string: "https://nas.local/poster.jpg")!
    ) == nil)
}

@Test func systemSearchFiltersBeforeApplyingItsResultLimit() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "system-search-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let repository = AppleMediaIndexRepository(fileURL: url)
    let source = UUID()
    var records = (0..<125).map { n in
        AppleMediaRecord(canonicalID: "private-\(n)", kind: .movie, title: "Title A \(n)",
            availability: [.init(instanceID: source, capability: .resolvable, itemReference: "movie|private-\(n)")],
            isPrivate: true)
    }
    records.append(AppleMediaRecord(canonicalID: "public", kind: .movie, title: "Title Z",
        availability: [.init(instanceID: source, capability: .resolvable, itemReference: "movie|public")]))
    try await repository.replace(instanceID: source, with: records)
    #expect(await repository.search("Title", limit: 1, eligibility: .systemDiscovery).map(\.title) == ["Title Z"])
    #expect(await repository.search("Title", limit: 1, eligibility: .playableVideo).map(\.title) == ["Title Z"])
}
