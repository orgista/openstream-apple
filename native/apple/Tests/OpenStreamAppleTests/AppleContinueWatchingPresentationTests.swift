import Foundation
import Testing
import Synchronization
@testable import OpenStreamApple

struct AppleContinueWatchingPresentationTests {
    @Test func aResumedEpisodeNamesItsEpisodeAndRemainingTime() {
        let saved = ApplePlaybackProgress(position: 1_020, duration: 2_400, partID: "fixture:2:5")
        let info = AppleContinueWatchingTileInfo.make(type: "series", saved: saved, recordProgress: 0.1)
        #expect(info.subtitle == "S2 E5 · 23 min left")
        #expect(info.progress == 0.425)
    }

    @Test func aMovieUsesHoursAndMinutes() {
        let saved = ApplePlaybackProgress(position: 1_800, duration: 6_120)
        let info = AppleContinueWatchingTileInfo.make(type: "movie", saved: saved, recordProgress: nil)
        #expect(info.subtitle == "1 hr 12 min left")
    }

    @Test func aSuccessorReplacesTheCompletedClockAndHasNoProgressBar() {
        let finished = ApplePlaybackProgress(position: 2_400, duration: 2_400, partID: "fixture:2:5")
        let next = AppleMediaEpisode(id: "fixture:2:6", title: "Morning", season: 2, episode: 6)
        let info = AppleContinueWatchingTileInfo.make(type: "series", saved: finished,
            recordProgress: 1, episode: next, isNext: true)
        #expect(info.subtitle == "Next · S2 E6")
        #expect(info.progress == nil)
    }

    @Test func serverEpisodeNumbersDoNotDependOnParsingItsOpaqueID() {
        let episode = AppleMediaEpisode(id: "ms:fixture:opaque", title: "Harbor", season: 2, episode: 5)
        let saved = ApplePlaybackProgress(position: 1_020, duration: 2_400)
        let info = AppleContinueWatchingTileInfo.make(type: "series", saved: saved,
            recordProgress: nil, episode: episode)
        #expect(info.subtitle == "S2 E5 · 23 min left")
        #expect(info.progress == 0.425)
    }

    @Test func resumeArtworkUsesTheEpisodeStillThenBackdropsThenPosterCrops() throws {
        let still = try #require(URL(string: "https://fixture.example/episode.jpg"))
        let backdrop = try #require(URL(string: "https://fixture.example/backdrop.jpg"))
        let poster = try #require(URL(string: "https://fixture.example/poster.jpg"))
        let item = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Harbor",
                                   posterURL: poster, backgroundURL: backdrop)
        let fallback = AppleArtworkResolver.Artwork(posterURL: poster, backgroundURL: nil)
        let candidates = AppleCatalogArtworkPolicy.resumeCandidates(item: item, still: still, fallback: fallback)
        #expect(candidates == [still, backdrop, poster])
        #expect(AppleCatalogArtworkPolicy.next(in: candidates, failed: [still]) == backdrop)
        #expect(AppleCatalogArtworkPolicy.next(in: candidates, failed: [still, backdrop]) == poster)
        let posterOnly = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Harbor", posterURL: poster)
        #expect(AppleCatalogArtworkPolicy.resumeCandidates(item: posterOnly, fallback: fallback) == [poster])
    }

    @Test(arguments: [Double.greatestFiniteMagnitude, .infinity, .nan])
    func unusableRuntimesNeverOverflowTheRemainingTimeFormatter(duration: Double) {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 10, duration: duration) == nil)
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func serverCardsUseTheProviderEpisodeStillAndClock(isNext: Bool, unknownRuntime: Bool) async throws {
        let domain = "cw-server-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example/jellyfin")))
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url,
                                             accessToken: "fixture", userID: "fixture")
        let episodeNumber = Mutex(isNext ? 6 : 5)
        let client = AppleMediaServerClient { request in
            let url = try #require(request.url)
            let number = episodeNumber.withLock { $0 }
            let episode = """
            {"Id":"episode-\(number)","Name":"The Harbor","SeriesName":"Harbor Lights","Type":"Episode",
             "SeriesId":"series","ParentIndexNumber":2,"IndexNumber":\(number),
             \(unknownRuntime ? "" : "\"RunTimeTicks\":24000000000,")"ImageTags":{"Primary":"still"},
             "ParentBackdropItemId":"series","ParentBackdropImageTags":["backdrop"],
             "UserData":{"PlaybackPositionTicks":\(isNext ? 0 : 10200000000),"Played":false}}
            """
            let json: String
            if url.path.hasSuffix("Views") {
                json = #"{"Items":[{"Id":"tv","Name":"TV","CollectionType":"tvshows"}]}"#
            } else if url.path.hasSuffix("Resume") && !isNext || url.path.hasSuffix("NextUp") && isNext {
                json = "{\"Items\":[\(episode)]}"
            } else if url.path.hasSuffix("Latest") {
                json = "[]"
            } else { json = #"{"Items":[]}"# }
            return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil)))
        }
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await library.reload(sources: [source]) { _ in session }
        let item = try #require(library.continueWatching.first)
        let info = library.continueWatchingInfo(for: item, store: ApplePlaybackStore(defaults: defaults))
        #expect(info.subtitle == (isNext ? "Next · S2 E6" : unknownRuntime ? "S2 E5" : "S2 E5 · 23 min left"))
        #expect(info.title == "Harbor Lights")
        #expect(info.episode?.thumbnailURL?.path.contains("/episode-\(isNext ? 6 : 5)/Images/Primary") == true)
        #expect(info.episode?.thumbnailURL != item.backgroundURL)
        #expect(info.progress == (isNext || unknownRuntime ? nil : 0.425))
        if isNext {
            episodeNumber.withLock { $0 = 7 }
            await library.refreshAffectedHubs(reference: try #require(AppleMediaServerItemReference.parse(item.mediaID)))
            let replacement = try #require(library.continueWatching.first)
            #expect(library.continueWatching.count == 1)
            #expect(replacement.mediaID != item.mediaID)
            #expect(library.continueWatchingInfo(for: replacement, store: ApplePlaybackStore(defaults: defaults)).subtitle == "Next · S2 E7")
        }
    }

    @MainActor @Test(arguments: ["finishedEpisode", "finishedPosition", "series", "source", "localSeries", "prunedEpisode"])
    func discoverSortsUnplayedSuccessorsWithLocalEmbyAndXtreamItems(activityFrom: String) async throws {
        let domain = "cw-mixed-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let stamp = Date(timeIntervalSince1970: 400)
        let jellyfin = AppleSource(id: UUID(), kind: .mediaServer, name: "Jellyfin",
            url: try #require(URL(string: "https://jf.fixture.example")),
            lastValidatedAt: activityFrom == "source" ? stamp : nil)
        let emby = AppleSource(id: UUID(), kind: .mediaServer, name: "Emby",
            url: try #require(URL(string: "https://emby.fixture.example")))
        let refreshed = Mutex(false)
        let client = AppleMediaServerClient { request in
            let url = try #require(request.url)
            let isJellyfin = url.host == jellyfin.url.host
            let json: String
            if url.path.hasSuffix("Views") {
                json = isJellyfin ? #"{"Items":[{"Id":"tv","Name":"TV","CollectionType":"tvshows"}]}"# : #"{"Items":[]}"#
            } else if url.path.hasSuffix("Resume") {
                json = isJellyfin ? #"{"Items":[]}"# : #"{"Items":[{"Id":"film","Name":"Emby Film","Type":"Movie","RunTimeTicks":36000000000,"UserData":{"PlaybackPositionTicks":12000000000,"LastPlayedDate":"1970-01-01T00:03:20Z"}}]}"#
            } else if url.path.hasSuffix("NextUp") {
                // The successor has no watch date or UserData: eligibility comes from this hub.
                if activityFrom == "prunedEpisode", !refreshed.withLock({ $0 }) {
                    json = #"{"Items":[{"Id":"finished","Name":"Night","Type":"Episode","SeriesId":"show","UserData":{"Played":true,"LastPlayedDate":"1970-01-01T00:06:40Z"}}]}"#
                } else {
                    json = #"{"Items":[{"Id":"next","Name":"Morning","Type":"Episode","SeriesId":"show","SeriesName":"Harbor Lights","ParentIndexNumber":2,"IndexNumber":6}]}"#
                }
            } else if url.path.hasSuffix("Latest") {
                if activityFrom == "finishedEpisode" {
                    json = #"[{"Id":"finished","Name":"Night","Type":"Episode","SeriesId":"show","UserData":{"Played":true,"LastPlayedDate":"1970-01-01T00:06:40Z"}}]"#
                } else if activityFrom == "finishedPosition" {
                    json = #"[{"Id":"finished","Name":"Night","Type":"Episode","SeriesId":"show","RunTimeTicks":24000000000,"UserData":{"Played":false,"PlaybackPositionTicks":24000000000,"LastPlayedDate":"1970-01-01T00:06:40Z"}}]"#
                } else if activityFrom == "series" {
                    json = #"[{"Id":"show","Name":"Harbor Lights","Type":"Series","UserData":{"LastPlayedDate":"1970-01-01T00:06:40Z"}}]"#
                } else { json = "[]" }
            } else { json = #"{"Items":[]}"# }
            return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil)))
        }
        let server = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await server.reload(sources: [jellyfin, emby]) { source in
            AppleMediaServerSession(kind: source.id == jellyfin.id ? .jellyfin : .emby,
                baseURL: source.url, accessToken: "fixture", userID: "fixture")
        }
        if activityFrom == "prunedEpisode" {
            refreshed.withLock { $0 = true }
            await server.refreshAffectedHubs(reference: .init(sourceID: jellyfin.id, itemID: "finished"))
            #expect(server.item(for: .init(sourceID: jellyfin.id, itemID: "finished")) == nil)
        }
        let playback = ApplePlaybackStore(defaults: defaults)
        if activityFrom == "localSeries" {
            let parent = AppleMediaServerItemReference(sourceID: jellyfin.id, itemID: "show").mediaID
            playback.restoreConfigurationPlaybackActivity([parent: .init(position: 2400, duration: 2400, updatedAt: stamp)])
        }
        let localSource = AppleSource(id: UUID(), kind: .library, name: "Local",
            url: try #require(URL(string: "https://local.fixture.example")))
        let localItem = AppleCatalogItem(mediaID: "local-film", type: "movie", name: "Local Film")
        let local = AppleDiscoverView.IndexedCatalogItem(
            record: AppleMediaIngestion.catalogRecord(instanceID: localSource.id, item: localItem),
            item: localItem, source: localSource, continueWatchingUpdatedAt: Date(timeIntervalSince1970: 300))
        let xtreamSource = AppleSource(id: UUID(), kind: .liveTV, name: "Xtream",
            url: try #require(URL(string: "https://xc.fixture.example")))
        let xtreamItem = AppleCatalogItem(mediaID: AppleXtreamReference(sourceID: xtreamSource.id,
            kind: .movie, providerID: "1").mediaID, type: "movie", name: "Xtream Film")
        let xtreamRecord = AppleMediaIngestion.catalogRecord(instanceID: xtreamSource.id, item: xtreamItem)
        playback.restoreConfigurationProgress([xtreamRecord.id: .init(position: 600, duration: 3600,
            updatedAt: Date(timeIntervalSince1970: 500))])
        let result = AppleDiscoverView.mergedContinueWatching(local: [local], mediaServerLibrary: server,
            xtreamItems: [xtreamItem], xtreamSource: { _ in xtreamSource },
            sources: [jellyfin, emby, localSource, xtreamSource], playbackStore: playback)
        #expect(result.map(\.item.name) == ["Xtream Film", "Morning", "Local Film", "Emby Film"])
        let next = try #require(result.first { $0.item.name == "Morning" })
        #expect(next.continueWatchingUpdatedAt == stamp)
        #expect(next.continueWatchingInfo?.subtitle == "Next · S2 E6")
        #expect(result.first?.continueWatchingInfo?.subtitle == "50 min left")
    }

    @MainActor @Test func liveProgressRefreshesAPreparedCaptionBeforeUsingItsCachedFallback() throws {
        let domain = "cw-live-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let playback = ApplePlaybackStore(defaults: defaults)
        let source = AppleSource(id: UUID(), kind: .library, name: "Local",
            url: try #require(URL(string: "https://fixture.example")))
        let item = AppleCatalogItem(mediaID: "local-film", type: "movie", name: "Local Film")
        let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
        let cached = AppleContinueWatchingTileInfo.make(type: "movie",
            saved: .init(position: 600, duration: 3600), recordProgress: nil)
        let value = AppleDiscoverView.IndexedCatalogItem(record: record, item: item, source: source,
            continueWatchingInfo: cached, progressKeys: ["local-file"])
        #expect(AppleDiscoverView.continueWatchingInfo(value, store: playback) == cached)
        let revision = ApplePlaybackProgressFeed.shared.revision
        playback.save(mediaID: "local-file", position: 1800, duration: 3600)
        #expect(ApplePlaybackProgressFeed.shared.revision > revision)
        let refreshed = AppleDiscoverView.continueWatchingInfo(value, store: playback)
        #expect(refreshed.subtitle == "30 min left")
        #expect(refreshed.progress == 0.5)
    }
}
