import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleContinueWatchingEpisodeTests {
    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex], [false, true])
    func titleDestinationKeepsTheSeriesAndTappedEpisode(kind: AppleMediaServerKind, cachedSeries: Bool) async throws {
        let fixture = try EpisodeFixture(kind: kind)
        defer { fixture.removeState() }
        await fixture.load()
        if cachedSeries { _ = try await fixture.store.detail(for: fixture.reference("show")) }
        let card = try #require(fixture.store.continueWatching.first)
        let destination = fixture.store.titlePageDestination(for: card)
        #expect(card.mediaID == fixture.reference("e5").mediaID)
        #expect(destination.item.mediaID == fixture.reference("show").mediaID)
        #expect(destination.item.type == "series")
        #expect(destination.item.name == "Fixture Series")
        #expect(destination.episodeID == "e5")
        #expect(artworkPath(destination.item.posterURL)?.contains("/e5/") != true)
        if cachedSeries || kind != .plex {
            #expect(artworkPath(destination.item.posterURL)?.contains("/show/") == true)
        }
        #expect(artworkPath(destination.item.backgroundURL)?.contains("/show/") == true)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex])
    func episodeReferenceResolvesItsSeriesAndResumesTheRequestedEpisode(kind: AppleMediaServerKind) async throws {
        let fixture = try EpisodeFixture(kind: kind)
        defer { fixture.removeState() }
        await fixture.load()
        let reference = fixture.reference("e5")
        let detail = try await fixture.store.detail(for: reference)
        #expect(detail.item.id == "e5")
        #expect(detail.seasons.map(\.id) == ["season2"])
        let metadata = fixture.store.metadata(from: detail)
        #expect(metadata.title == "Fixture Series")
        #expect(artworkPath(metadata.posterURL)?.contains("/show/") == true)
        #expect(artworkPath(metadata.backdropURL)?.contains("/show/") == true)
        let episode = try #require(AppleTitlePagePolicy.serverEpisodeToPlay(
            selectedID: nil, startID: "e1", referenceID: reference.itemID,
            referenceIsEpisode: detail.item.type == .episode, episodesBySeason: detail.episodesBySeason))
        #expect(episode.id == "e5")
        let request = try await fixture.store.playbackRequest(for: episode, in: detail, resume: true)
        #expect(request.mediaID == reference.mediaID)
        #expect(request.resumePosition == 120)
        #expect(request.title?.contains("Fixture Series") == true)
        #expect(request.title?.contains("S2E5") == true)
        #expect(AppleTitlePagePolicy.serverEpisodeToPlay(selectedID: "e1", startID: nil,
            referenceID: "e5", referenceIsEpisode: true, episodesBySeason: detail.episodesBySeason)?.id == "e1")

        let card = try #require(fixture.store.continueWatching.first)
        let destination = fixture.store.titlePageDestination(for: card)
        let seriesReference = try #require(AppleMediaServerItemReference.parse(destination.item.mediaID))
        let seriesDetail = try await fixture.store.detail(for: seriesReference)
        let selected = try #require(AppleTitlePagePolicy.serverEpisodeToPlay(
            selectedID: destination.episodeID, startID: "e1", referenceID: seriesReference.itemID,
            referenceIsEpisode: false, episodesBySeason: seriesDetail.episodesBySeason))
        let seriesRequest = try await fixture.store.playbackRequest(for: selected, in: seriesDetail, resume: true)
        #expect(seriesRequest.mediaID == reference.mediaID)
        #expect(seriesRequest.resumePosition == 120)
    }

    @Test func ordinaryTitlesKeepTheirDestination() {
        let store = AppleMediaServerLibraryStore(plexClient: .init(clientIdentifier: "continue-episode-fixture"))
        for type in ["movie", "series"] {
            let item = AppleCatalogItem(mediaID: "tt0000001", type: type, name: "Fixture")
            let destination = store.titlePageDestination(for: item)
            #expect(destination.item == item)
            #expect(destination.episodeID == nil)
        }
    }

    @Test(arguments: ["movie", "series"])
    func unresolvedDestinationKeepsCatalogUpdates(type: String) {
        let original = AppleCatalogItem(mediaID: "library-title", type: type, name: "Filename")
        let updated = AppleCatalogItem(mediaID: "tt0000001", type: type, name: "Catalog title")
        var destination = AppleTitlePagePolicy.ServerDestination(item: original)
        #expect(destination.displayItem(navigationItem: original) == original)
        #expect(destination.displayItem(navigationItem: updated) == updated)
        let series = AppleCatalogItem(mediaID: "server-series", type: "series", name: "Server series")
        destination.resolve((series, "e5"))
        #expect(destination.displayItem(navigationItem: updated) == series)
        #expect(destination.initialEpisodeID == "e5")
    }

    @Test func nasContinueWatchingDestinationGainsItsEpisodeGroupAfterLoading() throws {
        let url = try #require(URL(string: "smb://fixture.example/Media/TV/Fixture"))
        let source = AppleSource(kind: .nas, name: "Fixture", url: url)
        func group(sourceID: UUID) -> AppleLibrarySeries {
            let file = AppleLibraryItem(sourceID: sourceID, name: "Fixture.S02E05.mkv",
                url: url.appendingPathComponent("Fixture.S02E05.mkv"),
                relativePath: "Fixture.S02E05.mkv", sizeBytes: 1)
            return AppleLibrarySeries(id: sourceID.uuidString, parsed: AppleLibraryTitleParser.parse(file), items: [file])
        }
        let matching = group(sourceID: source.id)
        let other = group(sourceID: UUID())
        #expect(AppleTitlePagePolicy.localDestinationGroup(source: source, matchingGroups: []) == nil)
        #expect(AppleTitlePagePolicy.localDestinationGroup(source: source, matchingGroups: [other]) == nil)
        let destination = try #require(AppleTitlePagePolicy.localDestinationGroup(
            source: source, matchingGroups: [other, matching]))
        #expect(destination == matching)
        var episodes = AppleTitlePageEpisodeState()
        episodes.applyEpisodes([], localGroup: destination, mediaID: "tt0000001")
        #expect(episodes.episodes.count == 1)
        #expect(episodes.episodes.first?.season == 2)
        #expect(episodes.episodes.first?.episode == 5)
        for kind in [AppleSourceKind.mediaServer, .library, .liveTV] {
            let nonNAS = AppleSource(id: source.id, kind: kind, name: source.name, url: source.url)
            #expect(AppleTitlePagePolicy.localDestinationGroup(source: nonNAS, matchingGroups: [matching]) == nil)
        }
    }

    @Test func nasDestinationIsChosenOnceAndWaitsForTheGroupOnColdLaunch() throws {
        let url = try #require(URL(string: "smb://fixture.example/Media/TV/Fixture"))
        let file = AppleLibraryItem(sourceID: UUID(), name: "Fixture.S02E05.mkv",
            url: url.appendingPathComponent("Fixture.S02E05.mkv"), relativePath: "Fixture.S02E05.mkv", sizeBytes: 1)
        let group = AppleLibrarySeries(id: "fixture", parsed: AppleLibraryTitleParser.parse(file), items: [file])
        typealias Choice = AppleTitlePagePolicy.TitleDestinationChoice

        // Cold launch: no group yet, the scan is still running.
        var cold = Choice()
        cold.update(group: nil, groupCanStillArrive: true)
        #expect(cold.page == nil)
        cold.update(group: group, groupCanStillArrive: true)
        #expect(cold.page == .local(group))
        cold.update(group: nil, groupCanStillArrive: false)
        #expect(cold.page == .local(group))

        // Opened as the catalog page: a group arriving later does not swap it.
        var catalog = Choice()
        catalog.update(group: nil, groupCanStillArrive: false)
        #expect(catalog.page == .catalog)
        catalog.update(group: group, groupCanStillArrive: false)
        #expect(catalog.page == .catalog)
    }

    @Test func selectingTheEpisodesSeasonKeepsTheTappedEpisode() {
        var state = AppleTitlePageEpisodeState()
        state.episodes = [AppleMediaEpisode(id: "e1", title: "First", season: 2, episode: 1),
            AppleMediaEpisode(id: "e5", title: "Fifth", season: 2, episode: 5),
            AppleMediaEpisode(id: "other", title: "Other season", season: 1, episode: 1)]
        state.selectedEpisodeID = "e5"
        state.selectEpisode(in: 2, defaultID: "e1")
        #expect(state.selectedEpisodeID == "e5")
        state.selectEpisode(in: 1, defaultID: "other")
        #expect(state.selectedEpisodeID == "other")
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex])
    func cachedRowIsCorrectedAfterDetailLoads(kind: AppleMediaServerKind) async throws {
        let fixture = try EpisodeFixture(kind: kind, resumeContainsEpisode: false)
        defer { fixture.removeState() }
        let storedCard = AppleCatalogItem(mediaID: fixture.reference("e5").mediaID, type: "series", name: "Fifth")
        let encodedCard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(storedCard))
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["shelves": [], "continueWatching": [encodedCard]])
            .write(to: fixture.directory.appendingPathComponent("rows.json"))
        fixture.store.loadPersisted()
        let card = try #require(fixture.store.continueWatching.first)
        #expect(fixture.store.item(for: fixture.reference("e5")) == nil)
        var destination = AppleTitlePagePolicy.ServerDestination(item: card)
        destination.resolve(fixture.store.titlePageDestination(for: card))
        #expect(destination.item == card)
        #expect(destination.initialEpisodeID == nil)
        await fixture.load()
        #expect(fixture.store.item(for: fixture.reference("e5")) == nil)
        let detail = try await fixture.store.detail(for: fixture.reference("e5"))
        destination.resolve(fixture.store.titlePageDestination(for: card))
        #expect(destination.item.mediaID == fixture.reference("show").mediaID)
        #expect(destination.item.name == "Fixture Series")
        #expect(destination.initialEpisodeID == "e5")
        var state = AppleTitlePageEpisodeState()
        state.episodes = fixture.store.episodes(from: detail)
        state.selectInitialServerEpisode(destination.startEpisodeID(in: state.episodes, fallbackID: "e1"))
        #expect(state.selectedEpisodeID == "e5")
        #expect(state.selectedSeason == 2)
    }

    @Test func openingEpisodeIsValidatedAndConsumedBySelectionAndCompletion() {
        let series = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Fixture")
        let episodes = [AppleMediaEpisode(id: "e1", title: "First", season: 1, episode: 1),
            AppleMediaEpisode(id: "e5", title: "Fifth", season: 2, episode: 5)]
        var destination = AppleTitlePagePolicy.ServerDestination(item: series)
        destination.resolve((series, "missing"))
        #expect(destination.startEpisodeID(in: episodes, fallbackID: "e1") == "e1")
        destination.resolve((series, "e5"))
        #expect(destination.startEpisodeID(in: [], fallbackID: nil) == nil)
        #expect(destination.startEpisodeID(in: episodes, fallbackID: "e1") == "e5")
        destination.selectionChanged(from: nil, to: "e5")
        #expect(destination.initialEpisodeID == "e5")
        destination.selectionChanged(from: "e5", to: "e1")
        destination.resolve((series, "e5"))
        #expect(destination.startEpisodeID(in: episodes, fallbackID: "e1") == "e1")
        var completed = AppleTitlePagePolicy.ServerDestination(item: series)
        completed.resolve((series, "e5"))
        completed.playbackStarted(episodeID: "e5", wasWatched: false)
        let didComplete = completed.playbackCompleted(selectedEpisodeID: "e5", watchedEpisodeIDs: ["e5"])
        #expect(didComplete)
        completed.resolve((series, "e5"))
        #expect(completed.initialEpisodeID == nil)
        #expect(completed.startEpisodeID(in: episodes, fallbackID: "e1") == "e1")
    }

    @Test func watchedRefreshKeepsAnAlreadyWatchedSelection() {
        let series = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Fixture")
        var destination = AppleTitlePagePolicy.ServerDestination(item: series)
        destination.resolve((series, "e5"))
        #expect(destination.playbackCompleted(selectedEpisodeID: "e5", watchedEpisodeIDs: ["e5"]) == false)
        #expect(destination.initialEpisodeID == "e5")
        destination.selectionChanged(from: "e5", to: "e1")
        #expect(destination.playbackCompleted(selectedEpisodeID: "e1", watchedEpisodeIDs: ["e1", "e5"]) == false)
        destination.playbackStarted(episodeID: "e1", wasWatched: true)
        #expect(destination.playbackCompleted(selectedEpisodeID: "e1", watchedEpisodeIDs: ["e1", "e5"]) == false)
    }

    @Test func onlyTheLaunchedEpisodeCompletingAdvancesSelection() {
        let series = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Fixture")
        let episodes = [AppleMediaEpisode(id: "e5", title: "Fifth", season: 2, episode: 5),
            AppleMediaEpisode(id: "e6", title: "Sixth", season: 2, episode: 6)]
        var destination = AppleTitlePagePolicy.ServerDestination(item: series)
        destination.resolve((series, "e5"))
        var selection = AppleTitlePageEpisodeState()
        selection.episodes = episodes
        selection.selectInitialServerEpisode(destination.startEpisodeID(in: episodes, fallbackID: "e6"))
        destination.playbackStarted(episodeID: "e5", wasWatched: false)
        #expect(destination.playbackCompleted(selectedEpisodeID: selection.selectedEpisodeID,
            watchedEpisodeIDs: ["e1"]) == false)
        #expect(selection.selectedEpisodeID == "e5")
        if destination.playbackCompleted(selectedEpisodeID: selection.selectedEpisodeID, watchedEpisodeIDs: ["e1", "e5"]) {
            selection.selectInitialServerEpisode(destination.startEpisodeID(in: episodes, fallbackID: "e6"))
        }
        #expect(selection.selectedEpisodeID == "e6")
        #expect(destination.initialEpisodeID == nil)
        #expect(destination.playbackCompleted(selectedEpisodeID: "e6", watchedEpisodeIDs: ["e5", "e6"]) == false)
    }

    @Test func completionKeepsASelectionMadeAfterLaunch() {
        let series = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Fixture")
        var destination = AppleTitlePagePolicy.ServerDestination(item: series)
        destination.resolve((series, "e5"))
        destination.playbackStarted(episodeID: "e5", wasWatched: false)
        destination.selectionChanged(from: "e5", to: "e1")
        #expect(destination.playbackCompleted(selectedEpisodeID: "e1", watchedEpisodeIDs: ["e5"]) == false)
        #expect(destination.playbackCompleted(selectedEpisodeID: "e5", watchedEpisodeIDs: ["e5"]) == false)
    }

    @Test func offlineIdentityKeepsTheOpeningEpisodeWhileSeriesDetailsLoad() {
        let episode = AppleCatalogItem(mediaID: "episode", type: "series", name: "Fifth")
        let series = AppleCatalogItem(mediaID: "series", type: "series", name: "Fixture")
        var destination = AppleTitlePagePolicy.ServerDestination(item: episode)
        #expect(destination.offlineItemID(selectedEpisodeID: nil, referenceID: "e5") == "e5")
        destination.resolve((series, "e5"))
        #expect(destination.startEpisodeID(in: [], fallbackID: nil) == nil)
        #expect(destination.offlineItemID(selectedEpisodeID: nil, referenceID: "show") == "e5")
        #expect(destination.offlineItemID(selectedEpisodeID: "e6", referenceID: "show") == "e6")
        destination.selectionChanged(from: "e5", to: "e6")
        #expect(destination.offlineItemID(selectedEpisodeID: nil, referenceID: "show") == "show")
    }

    @Test func openingRecordFollowsTheResolvedSeriesAndItsFavoriteState() async throws {
        let fixture = try EpisodeFixture(kind: .plex, resumeContainsEpisode: false)
        defer { fixture.removeState() }
        let mediaIndex = AppleMediaIndexStore(repository: .init(fileURL: fixture.directory.appendingPathComponent("index.json")))
        let series = AppleCatalogItem(mediaID: fixture.reference("show").mediaID, type: "series", name: "Fixture Series")
        var saved = AppleMediaIngestion.catalogRecord(instanceID: fixture.source.id, item: series)
        saved.isFavorite = true
        try await mediaIndex.upsert(saved)
        let episode = AppleCatalogItem(mediaID: fixture.reference("e5").mediaID, type: "series", name: "Fifth")
        var destination = AppleTitlePagePolicy.ServerDestination(item: episode)
        var actions = AppleTitlePageActionState()
        let opening = actions.openedRecord(item: destination.displayItem(navigationItem: episode),
            sourceID: fixture.source.id, mediaIndex: mediaIndex)
        #expect(actions.isFavorite == false)
        await fixture.load()
        _ = try await fixture.store.detail(for: fixture.reference("e5"))
        destination.resolve(fixture.store.titlePageDestination(for: episode))
        let resolved = actions.openedRecord(item: destination.displayItem(navigationItem: episode),
            sourceID: fixture.source.id, mediaIndex: mediaIndex)
        #expect(resolved.id != opening.id)
        #expect(resolved.id == saved.id)
        #expect(actions.isFavorite)
        try await mediaIndex.upsert(resolved)
        #expect(mediaIndex.record(id: saved.id)?.isFavorite == true)
    }

    @Test func serverPlayPrecedenceUsesOnlyAvailableEpisodes() {
        let episodes = ["season": ["selected", "reference", "start"].map {
            AppleMediaServerItem(id: $0, name: $0, type: .episode)
        }]
        func pick(_ selected: String?, _ start: String?, _ isEpisode: Bool = true) -> String? {
            AppleTitlePagePolicy.serverEpisodeToPlay(selectedID: selected, startID: start,
                referenceID: "reference", referenceIsEpisode: isEpisode, episodesBySeason: episodes)?.id
        }
        #expect(pick("selected", "start") == "selected")
        #expect(pick(nil, "start") == "reference")
        #expect(pick(nil, "start", false) == "start")
        #expect(pick("missing", "start") == "reference")
        #expect(pick("missing", "start", false) == "start")
        #expect(pick(nil, nil, false) == nil)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby], [AppleMediaServerItemType.movie, .series])
    func ordinaryMetadataRetainsItsOriginalArtwork(kind: AppleMediaServerKind, type: AppleMediaServerItemType) throws {
        let fixture = try EpisodeFixture(kind: kind)
        defer { fixture.removeState() }
        let item = AppleMediaServerItem(id: "title", name: "Title", type: type,
            primaryImageTag: "poster", backdropImageTags: ["backdrop"])
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: item, source: fixture.source,
            session: fixture.session, seasons: [], episodesBySeason: [:])
        let metadata = fixture.store.metadata(from: detail)
        #expect(metadata.posterURL?.path == "/Items/title/Images/Primary")
        #expect(query(metadata.posterURL, "maxWidth") == "600")
        #expect(metadata.backdropURL?.path == "/Items/title/Images/Backdrop")
        #expect(query(metadata.backdropURL, "maxWidth") == String(AppleArtworkSizePolicy.backdropMaximumWidth))
        var noOwnArt = AppleMediaServerItem(id: "title", name: "Title", type: type, seriesID: "parent")
        noOwnArt.seriesPrimaryImageTag = "parent-poster"
        noOwnArt.parentBackdropItemID = "parent"
        noOwnArt.parentBackdropImageTags = ["parent-backdrop"]
        let fallback = fixture.store.metadata(from: .init(item: noOwnArt, source: fixture.source,
            session: fixture.session, seasons: [], episodesBySeason: [:]))
        #expect(fallback.posterURL == nil)
        #expect(fallback.backdropURL == nil)
    }

    @Test(arguments: ["show", "movie"])
    func ordinaryPlexTitlesKeepTheirOriginalMetadataArtwork(id: String) async throws {
        let fixture = try EpisodeFixture(kind: .plex)
        defer { fixture.removeState() }
        await fixture.load()
        let detail = try await fixture.store.detail(for: fixture.reference(id))
        let metadata = fixture.store.metadata(from: detail)
        #expect(metadata.posterURL == nil)
        #expect(metadata.backdropURL == nil)
    }

    @Test func plexDetailKeepsFreshEpisodeWhenChildrenAreStale() async throws {
        let fixture = try EpisodeFixture(kind: .plex, stalePlexChildren: true)
        defer { fixture.removeState() }
        await fixture.load()
        let reference = fixture.reference("e5")
        let detail = try await fixture.store.detail(for: reference)
        #expect(detail.item.name == "Fifth")
        #expect(detail.item.userData?.positionSeconds == 120)
        #expect(fixture.store.item(for: reference)?.name == "Fifth")
        #expect(fixture.store.item(for: reference)?.userData?.positionSeconds == 120)
        #expect(detail.episodesBySeason["season2"]?.first { $0.id == "e5" }?.userData?.positionSeconds == 120)
        let parent = try await fixture.store.detail(for: fixture.reference("show"))
        #expect(parent.item.type == .series)
        #expect(fixture.store.item(for: reference)?.userData?.positionSeconds == 120)
        let request = try await fixture.store.playbackRequest(for: detail.item, in: detail, resume: true)
        #expect(request.resumePosition == 120)
        #expect(request.url.path == "/library/parts/e5/file.mp4")
        #expect(fixture.store.metadata(from: detail).title == "Fixture Series")
    }

    @Test func plexSiblingKeepsItsMediaAndNewerProgressWithoutADetailCacheEntry() async throws {
        let onDeck = try EpisodeFixture(kind: .plex)
        defer { onDeck.removeState() }
        await onDeck.load()
        let sibling = try #require(onDeck.store.plexItem(for: onDeck.reference("e5")))
        let fixture = try EpisodeFixture(kind: .plex, stalePlexChildren: true)
        defer { fixture.removeState() }
        let reference = fixture.reference("e5")
        let indexedSibling = AppleMediaServerItem(id: "e5", name: "Indexed Fifth", type: .episode,
            runtimeSeconds: 2400, userData: .init(positionSeconds: 180))
        let encoder = JSONEncoder()
        let cached: [String: Any] = ["shelves": [], "continueWatching": [], "sources": [[
            "id": fixture.source.id.uuidString, "configurationRevision": fixture.source.configurationRevision,
            "items": [try JSONSerialization.jsonObject(with: encoder.encode(indexedSibling))],
            "plexItems": [try JSONSerialization.jsonObject(with: encoder.encode(sibling))]
        ]]]
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: cached).write(to: fixture.directory.appendingPathComponent("rows.json"))
        fixture.store.loadPersisted(sources: [fixture.source]) { _ in fixture.session }
        #expect(fixture.store.item(for: reference) == indexedSibling)
        #expect(fixture.store.plexItem(for: reference) == sibling)
        #expect(sibling.viewOffsetSeconds == 120)
        #expect(sibling.parts.isEmpty == false)
        let detail = try await fixture.store.detail(for: fixture.reference("e1"))
        #expect(fixture.store.plexItem(for: reference) == sibling)
        #expect(fixture.store.item(for: reference) == indexedSibling)
        let listedSibling = try #require(detail.episodesBySeason["season2"]?.first { $0.id == "e5" })
        #expect(listedSibling == indexedSibling)
        let request = try await fixture.store.playbackRequest(for: listedSibling, in: detail, resume: true)
        #expect(request.resumePosition == 120)
        #expect(request.url.path == "/library/parts/e5/file.mp4")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [AppleMediaServerKind.jellyfin, .emby, .plex],
          [EpisodeFixture.Parent.invalid, .missing, .unreachable])
    func episodeWithoutAParentSeriesOpensAlone(kind: AppleMediaServerKind, parent: EpisodeFixture.Parent) async throws {
        let fixture = try EpisodeFixture(kind: kind, parent: parent)
        defer { fixture.removeState() }
        await fixture.load()
        let reference = fixture.reference("e5")
        let detail = try await fixture.store.detail(for: reference)
        #expect(detail.item.id == "e5")
        #expect(detail.item.type == .episode)
        #expect(detail.seasons.isEmpty)
        let episode = try #require(AppleTitlePagePolicy.serverEpisodeToPlay(
            selectedID: nil, startID: nil, referenceID: reference.itemID, referenceIsEpisode: true,
            episodesBySeason: detail.episodesBySeason) ?? AppleTitlePagePolicy.standaloneServerEpisode(in: detail))
        #expect(episode.id == "e5")
        let request = try await fixture.store.playbackRequest(for: episode, in: detail, resume: true)
        #expect(request.mediaID == reference.mediaID)
        #expect(request.resumePosition == 120)
        // A parent that failed to load is asked for again on the next open.
        let before = fixture.parentRequests.value
        _ = try await fixture.store.detail(for: reference)
        #expect(fixture.parentRequests.value == before + (parent == .unreachable ? 1 : 0))
    }

    @Test func seriesEpisodeIsNotStandalone() async throws {
        let fixture = try EpisodeFixture(kind: .jellyfin)
        defer { fixture.removeState() }
        await fixture.load()
        let detail = try await fixture.store.detail(for: fixture.reference("e5"))
        #expect(AppleTitlePagePolicy.standaloneServerEpisode(in: detail) == nil)
    }

    private func query(_ url: URL?, _ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
            .first { $0.name == name }?.value
    }

    private func artworkPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "url" }?.value ?? url.path
    }
}

@MainActor
struct EpisodeFixture {
    enum Parent: Sendable { case series, invalid, missing, unreachable }
    final class Counter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    let parentRequests = Counter()
    let domain = "continue-episode-\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let source: AppleSource
    let session: AppleMediaServerSession
    let store: AppleMediaServerLibraryStore

    init(kind: AppleMediaServerKind, stalePlexChildren: Bool = false, parent: Parent = .series,
         resumeContainsEpisode: Bool = true) throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        source = AppleSource(kind: .mediaServer, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example")))
        session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "user")
        let parentRequests = parentRequests
        let loader: AppleMediaServerClient.Loader = { request in
            let url = try #require(request.url)
            let body: String
            var status = 200
            if ["/library/metadata/show", "/Users/user/Items/show"].contains(url.path) {
                parentRequests.increment()
                if parent == .unreachable { status = 500 }
            }
            if kind == .plex {
                var episode = #"{"ratingKey":"e5","key":"/library/metadata/e5","type":"episode","title":"Fifth","grandparentRatingKey":"show","grandparentTitle":"Fixture Series","parentRatingKey":"season2","parentIndex":2,"index":5,"duration":2400000,"viewOffset":120000,"thumb":"/library/metadata/e5/thumb/still","art":"/library/metadata/show/art/backdrop","Media":[{"Part":[{"key":"/library/parts/e5/file.mp4","container":"mp4"}]}]}"#
                if parent == .missing { episode = episode.replacingOccurrences(of: #""grandparentRatingKey":"show","#, with: "") }
                let first = #"{"ratingKey":"e1","key":"/library/metadata/e1","type":"episode","title":"First","grandparentRatingKey":"show","grandparentTitle":"Fixture Series","parentIndex":2,"index":1}"#
                switch url.path {
                case "/library/onDeck":
                    body = #"{"MediaContainer":{"Metadata":["# + (resumeContainsEpisode ? episode : "") + "]}}"
                case "/library/metadata/e5": body = #"{"MediaContainer":{"Metadata":["# + episode + "]}}"
                case "/library/metadata/e1": body = #"{"MediaContainer":{"Metadata":["# + first + "]}}"
                case "/library/metadata/movie":
                    body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"movie","key":"/library/metadata/movie","type":"movie","title":"Fixture Movie","thumb":"/library/metadata/movie/thumb/poster","art":"/library/metadata/movie/art/backdrop"}]}}"#
                case "/library/metadata/show" where parent == .invalid:
                    body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"show","key":"/library/metadata/show","type":"episode","title":"Invalid parent","grandparentRatingKey":"e5"}]}}"#
                case "/library/metadata/show":
                    body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"show","key":"/library/metadata/show","type":"show","title":"Fixture Series","thumb":"/library/metadata/show/thumb/poster","art":"/library/metadata/show/art/backdrop"}]}}"#
                case "/library/metadata/show/children":
                    body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"season2","key":"/library/metadata/season2","type":"season","title":"Season 2","parentRatingKey":"show","index":2}]}}"#
                case "/library/metadata/season2/children":
                    let listed = stalePlexChildren
                        ? #"{"ratingKey":"e5","key":"/library/metadata/e5","type":"episode","title":"Stale Fifth","grandparentRatingKey":"show","parentRatingKey":"season2","parentIndex":2,"index":5,"viewOffset":0}"# : episode
                    body = #"{"MediaContainer":{"Metadata":["# + first + "," + listed + "]}}"
                default: body = #"{"MediaContainer":{}}"#
                }
            } else {
                var episode = #"{"Id":"e5","Name":"Fifth","Type":"Episode","SeriesId":"show","SeriesName":"Fixture Series","SeasonId":"season2","ParentIndexNumber":2,"IndexNumber":5,"RunTimeTicks":24000000000,"ImageTags":{"Primary":"still"},"SeriesPrimaryImageTag":"poster","ParentBackdropItemId":"show","ParentBackdropImageTags":["backdrop"],"UserData":{"PlaybackPositionTicks":1200000000,"Played":false}}"#
                if parent == .missing { episode = episode.replacingOccurrences(of: #""SeriesId":"show","#, with: "") }
                let first = #"{"Id":"e1","Name":"First","Type":"Episode","SeriesId":"show","ParentIndexNumber":2,"IndexNumber":1}"#
                switch url.path {
                case "/Users/user/Items/Resume": body = #"{"Items":["# + (resumeContainsEpisode ? episode : "") + "]}"
                case "/Users/user/Items/e5": body = episode
                case "/Users/user/Items/show" where parent == .invalid:
                    body = #"{"Id":"show","Name":"Invalid parent","Type":"Episode","SeriesId":"e5"}"#
                case "/Users/user/Items/show":
                    body = #"{"Id":"show","Name":"Fixture Series","Type":"Series","ImageTags":{"Primary":"poster"},"BackdropImageTags":["backdrop"]}"#
                case "/Shows/show/Seasons":
                    body = #"{"Items":[{"Id":"season2","Name":"Season 2","Type":"Season","IndexNumber":2}]}"#
                case "/Shows/show/Episodes": body = #"{"Items":["# + first + "," + episode + "]}"
                case "/Items/e5/PlaybackInfo":
                    body = #"{"MediaSources":[{"Id":"version","Container":"mp4","SupportsDirectPlay":true}]}"#
                default: body = #"{"Items":[],"TotalRecordCount":0}"#
                }
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        store = AppleMediaServerLibraryStore(client: .init(loader: loader),
            plexClient: .init(loader: loader, clientIdentifier: "continue-episode-fixture"),
            progressDefaults: defaults, cacheFileURL: directory.appendingPathComponent("rows.json"))
    }

    func reference(_ id: String) -> AppleMediaServerItemReference {
        .init(sourceID: source.id, itemID: id)
    }

    func load() async {
        await store.reload(sources: [source]) { _ in session }
    }

    func removeState() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }
}
