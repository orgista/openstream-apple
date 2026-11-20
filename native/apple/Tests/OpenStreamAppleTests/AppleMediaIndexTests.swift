import Foundation
import Testing
@testable import OpenStreamApple

@Test func canonicalMediaRecordKeysIgnoreFallbackFields() {
    let first = AppleMediaRecord(canonicalID: "  TT1234567  ", kind: .movie,
        title: "A Movie", year: 2000, availability: [])
    let second = AppleMediaRecord(canonicalID: "tt1234567", kind: .series,
        title: "Another Title", year: 2026, availability: [])
    #expect(first.id == second.id)
    #expect(first.id == ApplePlaybackIdentity.digest(for: "canonical|tt1234567"))
    #expect(first.canonicalID == "tt1234567")
}

@Test(arguments: [nil, "", " \n "] as [String?])
func fallbackMediaRecordKeysKeepTheirPersistedNormalization(canonicalID: String?) {
    let record = AppleMediaRecord(canonicalID: canonicalID, kind: .movie,
        title: " A / Tést! ", year: 1800, availability: [])
    #expect(record.id == ApplePlaybackIdentity.digest(for: "movie|a test|1800"))
    #expect(record.year == nil)
}

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
        artworkURL: URL(fileURLWithPath: "/fixture/Private/poster.jpg"),
        availability: [.init(
            instanceID: sourceID,
            capability: .direct,
            itemReference: "/fixture/Private/Movies/Amelie.mp4"
        )],
        isPrivate: true
    )
    try await repository.replace(instanceID: sourceID, with: [record])

    #expect(await repository.search("amelie holiday").map(\.id) == [record.id])
    #expect(await repository.search("fabuleux").map(\.id) == [record.id])
    let persisted = try String(decoding: Data(contentsOf: url), as: UTF8.self)
    #expect(!persisted.contains("/fixture/Private"))
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

/// Play on an Apple TV Top Shelf item plays: on tvOS that URL plays;
/// elsewhere a link from any app or page still shows the title first.
@Test func openedPlayLinkPlaysOnlyWhereURLsMayPlay() {
    let id = String(repeating: "b", count: 64)
    #expect(AppleAppRoute.opened(.media(id: id, action: .play), urlMayPlay: true) == .media(id: id, action: .play))
    #expect(AppleAppRoute.opened(.media(id: id, action: .play), urlMayPlay: false) == .media(id: id, action: .display))
    #expect(AppleAppRoute.opened(.media(id: id, action: .display), urlMayPlay: true) == .media(id: id, action: .display))
    #expect(AppleAppRoute.opened(.live(channelID: "fixture-1"), urlMayPlay: true) == .live(channelID: "fixture-1"))
    #expect(AppleAppRoute.opened(.continueWatching, urlMayPlay: false) == .continueWatching)
}

@MainActor @Test func routerOpensTheShelfPlayLinkForThisPlatform() throws {
    let id = String(repeating: "c", count: 64)
    let router = AppleAppRouter()
    router.open(try #require(URL(string: "openstream://media/\(id)?action=play")))
    #if os(tvOS)
    #expect(router.route == .media(id: id, action: .play))
    #else
    #expect(router.route == .media(id: id, action: .display))
    #endif
    #expect(router.revision == 1)
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

@Test func mediaIndexQuarantinesCorruptDataBeforeWritingAgain() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-index-corrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "index.json")
    try Data("not-json".utf8).write(to: url)

    let repository = AppleMediaIndexRepository(fileURL: url)
    #expect(await repository.records().isEmpty)
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

@Test func aRememberedLibraryParseMatchesAFreshOne() {
    // The parser remembers each parse per name and folder: asked twice, it
    // answers the same, and the same name in another folder is its own entry.
    let source = AppleSource(kind: .library, name: "Library", url: URL(fileURLWithPath: "/tmp"))
    let movie = AppleLibraryItem(sourceID: source.id, name: "Heat.1995.1080p.mkv", url: URL(fileURLWithPath: "/tmp/heat.mkv"),
                                 relativePath: "Movies/Heat.1995.1080p.mkv", sizeBytes: 1)
    let other = AppleLibraryItem(sourceID: source.id, name: "Heat.1995.1080p.mkv", url: URL(fileURLWithPath: "/tmp/b/heat.mkv"),
                                 relativePath: "Heat (1986)/Heat.1995.1080p.mkv", sizeBytes: 1)
    for item in [movie, other, movie, other] {
        let record = AppleMediaIngestion.libraryRecord(source: source, item: item)
        let fresh = AppleLibraryTitleParser.parse(item)
        #expect(record.title == AppleMediaRecord(kind: .video, title: fresh.title, availability: []).title)
        #expect(record.year == fresh.year)
    }
    #expect(AppleLibraryTitleParser.parse(movie).alternatives != AppleLibraryTitleParser.parse(other).alternatives)
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

/// N43: the Top Shelf draws a progress bar under a started title, as the
/// Apple TV app does; only Continue Watching carries one.
@Test func topShelfSnapshotCarriesProgressForContinueWatchingOnly() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-topshelf-progress-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let instanceID = UUID()
    let records = [0.3, nil].enumerated().map { index, progress in
        AppleMediaRecord(
            canonicalID: "tt\(String(format: "%07d", index))",
            kind: .movie,
            title: "Movie \(index)",
            availability: [.init(instanceID: instanceID, capability: .resolvable,
                                 itemReference: "https://fixture.example/\(index).mkv")],
            isFavorite: true,
            progress: progress,
            isPrivate: false
        )
    }
    let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
    try await writer.write(records: records, enabled: true)

    let data = try Data(contentsOf: root.appending(path: AppleTopShelfSnapshotWriter.filename))
    let snapshot = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: data)
    #expect(snapshot.continueWatching.map(\.progress) == [0.3])
    #expect(snapshot.favorites.allSatisfy { $0.progress == nil })
    #expect(snapshot.recentlyAdded.allSatisfy { $0.progress == nil })
}

@Test func topShelfSnapshotDecodesItemsWrittenBeforeProgressAsNoProgress() throws {
    let legacyJSON = """
    {"version":1,"generatedAt":0,"continueWatching":[{"id":"a","title":"A","kind":"movie",\
    "displayURL":"openstream://media/a?action=display"}],"recentlyAdded":[],"favorites":[]}
    """
    let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(legacyJSON.utf8))
    #expect(decoded.continueWatching.first?.progress == nil)
}

@Test func topShelfSnapshotDecodesLegacyPayloadsMissingTopPicksAsEmpty() throws {
    let legacyJSON = """
    {"version":1,"generatedAt":0,"continueWatching":[],"recentlyAdded":[],"favorites":[]}
    """
    let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(legacyJSON.utf8))
    #expect(decoded.topPicks.isEmpty)
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
    #expect(AppleTopShelfContentBuilder.sections(for: onlyPicks).map(\.title) == ["Recently Added"])

    let both = AppleTopShelfSnapshot(
        version: 1, generatedAt: .now, continueWatching: watching, recentlyAdded: [], favorites: [], topPicks: picks
    )
    #expect(AppleTopShelfContentBuilder.sections(for: both).map(\.title) == ["Continue Watching", "Recently Added"])
}

@Test func systemArtworkPolicyRejectsCredentialBearingAndUntrustedURLs() {
    let trusted = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
    #expect(AppleSystemArtworkPolicy.publicURL(trusted) == trusted)
    #expect(AppleSystemArtworkPolicy.publicURL(
        URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg?token=secret")!
    ) == nil)
    // Was asserted as rejected when the policy was a two-host allowlist. That
    // allowlist is what emptied the owner's Continue Watching shelf on
    // 2026-09-16: sources serve posters from their own CDNs. A public https
    // host with no credentials and no query is now allowed; see
    // AppleSystemArtworkPolicyTests.
    #expect(AppleSystemArtworkPolicy.publicURL(
        URL(string: "https://cdn.example/private-token/poster.jpg")!
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

/// The content page reads its record through `record(id:)` in its body; the
/// lookup has to be observed so the Download button appears once the index
/// loads, even though the keyed table beside the array is not (F-e).
@MainActor
@Test(.timeLimit(.minutes(1))) func recordLookupByIDObservesTheIndex() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "record-lookup-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    let record = AppleMediaRecord(canonicalID: "tt7654321", kind: .series, title: "A Series",
        availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: "series|tt7654321")])
    let flag = RecordLookupChangeFlag()
    withObservationTracking {
        _ = store.record(id: record.id)
    } onChange: {
        Task { @MainActor in flag.changed = true }
    }
    try await store.upsert(record)
    while !flag.changed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(flag.changed)
    #expect(store.record(id: record.id)?.title == "A Series")
}

/// A download is matched to its record by its media id: the record id itself,
/// or `<record id>:<episode id>` for an episode. The keyed lookup has to give
/// the same answer the scan over `records` gave, earliest record first.
@MainActor
@Test func recordLookupByDownloadMediaIDMatchesTheScanItReplaced() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "record-prefix-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    let instance = UUID()
    let series = AppleMediaRecord(canonicalID: "tt1000001", kind: .series, title: "A Series",
        availability: [.init(instanceID: instance, capability: .resolvable, itemReference: "series|tt1000001")])
    let movie = AppleMediaRecord(canonicalID: "tt1000002", kind: .movie, title: "A Movie",
        availability: [.init(instanceID: instance, capability: .resolvable, itemReference: "movie|tt1000002")])
    try await store.replace(instanceID: instance, with: [series, movie])
    let scan = { (mediaID: String) in
        store.records.first { mediaID == $0.id || mediaID.hasPrefix($0.id + ":") }?.id
    }
    for mediaID in [series.id, movie.id, "\(series.id):\(series.id):1:2", "\(movie.id)", "\(series.id)x:1:2",
                    "tt9999999:1:1", "", ":", series.id + ":"] {
        #expect(store.record(matchingMediaID: mediaID)?.id == scan(mediaID), "\(mediaID)")
    }
    #expect(store.record(matchingMediaID: "\(series.id):tt1000001:1:2")?.title == "A Series")
    #expect(store.record(matchingMediaID: "\(series.id)x:1:2") == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func recordLookupByDownloadMediaIDObservesTheIndex() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "record-prefix-observe-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    let record = AppleMediaRecord(canonicalID: "tt1000003", kind: .series, title: "Another Series",
        availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: "series|tt1000003")])
    let flag = RecordLookupChangeFlag()
    withObservationTracking {
        _ = store.record(matchingMediaID: record.id + ":tt1000003:1:1")
    } onChange: {
        Task { @MainActor in flag.changed = true }
    }
    try await store.upsert(record)
    while !flag.changed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(flag.changed)
    #expect(store.record(matchingMediaID: record.id + ":tt1000003:1:1")?.title == "Another Series")
}

@MainActor
private final class RecordLookupChangeFlag {
    var changed = false
}


@MainActor
@Test func mediaIndexRevisionChangesForSameCountContentUpdates() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "recommendation-index-revision-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    let record = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Film",
        availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: "movie|tt1234567")])
    let initial = store.revision
    try await store.upsert(record)
    #expect(store.revision > initial)
    let loaded = store.revision
    try await store.setFavorite(true, recordID: record.id)
    #expect(store.revision > loaded)
    #expect(store.records.count == 1)
    #expect(store.record(id: record.id)?.isFavorite == true)
}

/// Every launch's library rescan writes the same records back. Writing an
/// unchanged set must not count as a change, or every view reading the index
/// redraws for nothing (Apple TV slowness, 2026-10-16).
@MainActor
@Test func replacingWithTheSameRecordsIsNotAChange() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "record-same-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    let instance = UUID()
    let record = AppleMediaRecord(canonicalID: "tt7654321", kind: .movie, title: "A Movie",
        availability: [.init(instanceID: instance, capability: .resolvable, itemReference: "movie|tt7654321")])
    try await store.replace(instanceID: instance, with: [record])
    let revision = store.revision
    try await store.replace(instanceID: instance, with: [record])
    #expect(store.revision == revision)

    var renamed = record
    renamed.title = "A Movie (Director's Cut)"
    try await store.replace(instanceID: instance, with: [renamed])
    #expect(store.revision != revision)
    #expect(store.records.map(\.title) == ["A Movie (Director's Cut)"])
}

@MainActor @Test(arguments: [true, false])
func unloadedFavoriteWritesPreserveTheSavedIndex(upsertHero: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "index.json")
    let sourceID = UUID()
    let saved = (0..<2).map { index in
        AppleMediaRecord(canonicalID: "tt000000\(index)", kind: .movie, title: "Saved \(index)",
            availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "movie|tt000000\(index)")])
    }
    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.replace(instanceID: sourceID, with: saved)
    try await repository.setFavorite(true, recordID: saved[0].id)
    try await repository.setFavorite(true, recordID: saved[1].id)
    try await repository.updateProgress([saved[1].id: 0.4])
    let before = try #require(await repository.records().first { $0.id == saved[1].id })
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    #expect(store.records.isEmpty)
    let hero = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Cached Hero",
        availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "movie|tt1234567")])
    let target = upsertHero ? hero : saved[0]
    let source = AppleSource(id: sourceID, kind: .mediaServer, name: "Fixture",
        url: try #require(URL(string: "https://fixture.example")))
    let value = AppleDiscoverView.IndexedCatalogItem(record: target,
        item: AppleCatalogItem(mediaID: target.canonicalID ?? target.id, type: "movie", name: target.title), source: source)
    try await AppleDiscoverView.toggleHeroInList(value, mediaIndex: store)

    let reloaded = await AppleMediaIndexRepository(fileURL: url).records()
    #expect(Set(reloaded.map(\.id)) == Set(saved.map(\.id) + (upsertHero ? [hero.id] : [])))
    #expect(reloaded.first { $0.id == saved[1].id } == before)
    #expect(reloaded.first { $0.id == target.id }?.isFavorite == upsertHero)
}

@MainActor @Test func concurrentDiscoverAndSheetLoadsKeepFavoritesAndProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "discover-load-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let playback = ApplePlaybackStore(defaults: defaults)
    let url = root.appending(path: "index.json")
    let sourceID = UUID()
    let records = (0..<3).map { index in
        AppleMediaRecord(canonicalID: "tt000000\(index)", kind: .movie, title: "Movie \(index)",
            availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "movie|tt000000\(index)")])
    }
    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.replace(instanceID: sourceID, with: records)
    try await repository.setFavorite(true, recordID: records[0].id)
    playback.save(mediaID: records[1].id, position: 120, duration: 1200)
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    func prepare() async throws {
        await store.load()
        try await store.synchronizePlaybackProgress(store: playback)
    }
    async let discover: Void = prepare()
    async let sheet: Void = prepare()
    _ = try await (discover, sheet)
    let reloaded = await AppleMediaIndexRepository(fileURL: url).records()
    #expect(Set(reloaded.map(\.id)) == Set(records.map(\.id)))
    #expect(reloaded.first { $0.id == records[0].id }?.isFavorite == true)
    #expect(reloaded.first { $0.id == records[1].id }?.progress == 0.1)
    #expect(reloaded.first { $0.id == records[2].id }?.progress == nil)
    #expect(store.records == reloaded)
}

@MainActor @Test func playbackProgressIsPublishedBeforeTheIndexWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "discover-progress-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let playback = ApplePlaybackStore(defaults: defaults)
    let url = root.appending(path: "index.json")
    let sourceID = UUID()
    let record = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Movie",
        availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "movie|tt1234567")])
    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.replace(instanceID: sourceID, with: [record])
    try await repository.updateProgress([record.id: 0.1])
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    await store.load()
    let before = try Data(contentsOf: url)
    playback.save(mediaID: record.id, position: 240, duration: 1200)
    store.beginSynchronizingPlaybackProgress(store: playback)
    #expect(store.record(id: record.id)?.progress == 0.2)
    #expect(try Data(contentsOf: url) == before)
    let projectedRevision = store.revision
    try await store.waitForPlaybackProgressSynchronization()
    #expect(store.revision == projectedRevision)
    try await store.beginSynchronizingPlaybackProgress(store: playback).value
    #expect(store.revision == projectedRevision)
    let reloaded = try #require(await AppleMediaIndexRepository(fileURL: url).records().first)
    #expect(reloaded.progress == 0.2)
}

@MainActor @Test func aLaterProgressProjectionSurvivesAnEarlierIndexWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "discover-progress-order-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let playback = ApplePlaybackStore(defaults: defaults)
    let url = root.appending(path: "index.json")
    let sourceID = UUID()
    let record = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Movie",
        availability: [.init(instanceID: sourceID, capability: .resolvable, itemReference: "movie|tt1234567")])
    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.replace(instanceID: sourceID, with: [record])
    let store = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: url))
    await store.load()
    playback.save(mediaID: record.id, position: 120, duration: 1200)
    let first = store.beginSynchronizingPlaybackProgress(store: playback)
    playback.save(mediaID: record.id, position: 240, duration: 1200)
    store.beginSynchronizingPlaybackProgress(store: playback)
    #expect(store.record(id: record.id)?.progress == 0.2)
    try await first.value
    #expect(store.record(id: record.id)?.progress == 0.2)
    try await store.waitForPlaybackProgressSynchronization()
    let reloaded = try #require(await AppleMediaIndexRepository(fileURL: url).records().first)
    #expect(reloaded.progress == 0.2)
    #expect(store.record(id: record.id)?.progress == 0.2)
}

/// Indexes written before 2026-10-22 tagged MKV files with a capability no
/// build reads any more; they load as direct files.
@Test func aRetiredPlaybackCapabilityDecodesAsDirect() throws {
    let json = Data(#"["gateway", "resolvable", "direct"]"#.utf8)
    let decoded = try JSONDecoder().decode([AppleMediaPlaybackCapability].self, from: json)
    #expect(decoded == [.direct, .resolvable, .direct])
}

/// A favourite added from a Top 10 or shared-link page belongs to the fixed
/// metadata-only source, which is in no source list; the launch-time
/// availability pass keeps it.
@Test func aFavouriteFromAMetadataOnlyPageSurvivesTheLaunchAvailabilityPass() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "metadata-favourite-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let item = AppleCatalogItem(mediaID: "tt7654321", type: "movie", name: "Fixture Film")
    let source = AppleCatalogSearchMatch.metadataOnly(item).source
    let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.upsert(record)
    try await repository.setFavorite(true, recordID: record.id)

    try await AppleMediaIndexRepository(fileURL: url).retainAvailability(for: [])

    let reloaded = try #require(await AppleMediaIndexRepository(fileURL: url).records().first { $0.id == record.id })
    #expect(reloaded.isFavorite)
    #expect(reloaded.availability.map(\.instanceID) == [AppleMediaAvailability.metadataOnlyInstanceID])
}

/// Every launch upserts the servers' recently added titles; one already
/// indexed with nothing new keeps its dates and the index is not rewritten.
@Test func reloadingUnchangedRecentlyAddedTitlesWritesNothing() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "recently-added-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let server = UUID()
    let item = AppleCatalogItem(mediaID: "jf:movie-1", type: "movie", name: "Fixture Movie",
                                posterURL: URL(string: "https://fixture.example/poster.jpg"))
    let first = Date(timeIntervalSince1970: 1_000_000)
    let repository = AppleMediaIndexRepository(fileURL: url)
    try await repository.upsert([AppleMediaIngestion.catalogRecord(instanceID: server, item: item, verifiedAt: first)])
    try FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: url.path)

    try await repository.upsert([AppleMediaIngestion.catalogRecord(instanceID: server, item: item, verifiedAt: .now)])

    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == first)
    let stored = try #require(await repository.records().first)
    #expect(stored.lastVerified == first)
    #expect(stored.availability.map(\.lastVerified) == [first])

    let newPoster = AppleCatalogItem(mediaID: "jf:movie-1", type: "movie", name: "Fixture Movie",
                                   posterURL: URL(string: "https://fixture.example/poster-2.jpg"))
    try await repository.upsert([AppleMediaIngestion.catalogRecord(instanceID: server, item: newPoster, verifiedAt: .now)])
    #expect(try #require(await repository.records().first).artworkURL?.lastPathComponent == "poster-2.jpg")
}

private func channelRecord(_ id: String, _ instance: UUID) -> AppleMediaRecord {
    AppleMediaRecord(canonicalID: id, kind: .channel, title: id,
        availability: [.init(instanceID: instance, capability: .direct, itemReference: id)])
}

/// Two playlists answering together: each `replace` reads the repository,
/// then compares and indexes off the main actor, so they can finish in the
/// other order. The older read must not overwrite the newer one.
@MainActor
@Test func anOlderSnapshotFinishingLastDoesNotReplaceANewerOne() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "record-stale-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let repository = AppleMediaIndexRepository(fileURL: url)
    let store = AppleMediaIndexStore(repository: repository)
    let first = UUID(), second = UUID()
    try await repository.replace(instanceID: first, with: [channelRecord("one", first)])
    let older = await repository.snapshot()
    try await repository.replace(instanceID: second, with: [channelRecord("two", second)])
    let newer = await repository.snapshot()
    #expect(newer.version > older.version)

    await store.publish(newer)
    let revision = store.revision
    await store.publish(older)
    #expect(Set(store.records.map(\.title)) == ["one", "two"])
    #expect(store.revision == revision)
}

/// Another publish lands while this one compares off the main actor: the
/// compare is redone against the records now up, not on the main actor.
@MainActor
@Test func aPublishRedoesItsCompareWhenTheRecordsMoveUnderIt() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "record-moved-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let repository = AppleMediaIndexRepository(fileURL: url)
    let store = AppleMediaIndexStore(repository: repository)
    let first = UUID(), second = UUID()
    try await repository.replace(instanceID: first, with: [channelRecord("one", first)])
    let older = await repository.snapshot()
    try await repository.replace(instanceID: second, with: [channelRecord("two", second)])
    let newer = await repository.snapshot()
    var compares = 0
    var landed: [Set<String>] = []
    store.afterOffMainCompare = {
        compares += 1
        guard compares == 1 else { return }
        await store.publish(older)
        landed.append(Set(store.records.map(\.title)))
    }
    await store.publish(newer)
    #expect(landed == [["one"]])
    #expect(compares == 3)
    #expect(store.records == newer.records)
}
