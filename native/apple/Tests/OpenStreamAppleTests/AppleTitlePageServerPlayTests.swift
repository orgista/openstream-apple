import Foundation
import Testing
@testable import OpenStreamApple

/// Owner recording 2026-11-04: Chernobyl, a media-server series, kept Play
/// greyed out and Cast & Crew empty while its server's detail call was slow.
struct AppleTitlePageServerPlayTests {
    @Test func aMediaServerTitleDoesNotWaitForTheDetailCall() {
        #expect(!AppleTitlePagePolicy.playWaitsForPreparation(isPreparing: true, isMediaServerTitle: true))
        #expect(AppleTitlePagePolicy.playWaitsForPreparation(isPreparing: true, isMediaServerTitle: false))
        #expect(!AppleTitlePagePolicy.playWaitsForPreparation(isPreparing: false, isMediaServerTitle: false))
    }

    @Test func aServerSeriesCanPlayBeforeItsEpisodeListArrives() {
        #expect(AppleTitlePagePolicy.canStartPlayback(type: "series", hasPlaybackRoute: true, isPreparing: false,
                                                      hasSelectedEpisode: false, picksEpisodeAtStart: true))
        #expect(!AppleTitlePagePolicy.canStartPlayback(type: "series", hasPlaybackRoute: true, isPreparing: false,
                                                       hasSelectedEpisode: false))
        #expect(!AppleTitlePagePolicy.canStartPlayback(type: "series", hasPlaybackRoute: false, isPreparing: false,
                                                       hasSelectedEpisode: false, picksEpisodeAtStart: true))
    }

    @Test func catalogCreditsStandInUntilThePageHasItsOwn() {
        #expect(AppleTitlePagePolicy.creditOrigin(pageHasCredits: false, catalogHasCredits: true, shown: nil) == .catalog)
        #expect(AppleTitlePagePolicy.creditOrigin(pageHasCredits: true, catalogHasCredits: true, shown: nil) == .page)
        #expect(AppleTitlePagePolicy.creditOrigin(pageHasCredits: false, catalogHasCredits: false, shown: nil) == nil)
    }

    @Test func theCreditsThatDrewFirstKeepTheSection() {
        #expect(AppleTitlePagePolicy.creditOrigin(pageHasCredits: true, catalogHasCredits: true, shown: .catalog) == .catalog)
        #expect(AppleTitlePagePolicy.creditOrigin(pageHasCredits: true, catalogHasCredits: true, shown: .page) == .page)
    }

    /// Play pressed before the page's episode list arrived picks from the
    /// detail it fetched itself; the series id is never played as an episode.
    @Test func playBeforeTheListPicksAnEpisodeAndNeverTheSeries() {
        let first = AppleMediaServerItem(id: "e1", name: "1:23:45", type: .episode, seriesID: "chernobyl")
        let second = AppleMediaServerItem(id: "e2", name: "Please Remain Calm", type: .episode, seriesID: "chernobyl")
        let episodes = ["season-1": [first, second]]
        func pick(selected: String? = nil, start: String?, isEpisode: Bool = false,
                  in seasons: [String: [AppleMediaServerItem]] = episodes) -> String? {
            AppleTitlePagePolicy.serverEpisodeToPlay(selectedID: selected, startID: start, referenceID: "chernobyl",
                referenceIsEpisode: isEpisode, episodesBySeason: seasons)?.id
        }
        #expect(pick(start: "e2") == "e2")
        #expect(pick(selected: "e1", start: "e2") == "e1")
        // No start pick (nothing eligible): nothing to play, not the series id.
        #expect(pick(start: nil) == nil)
        #expect(pick(start: nil, in: ["season-1": [AppleMediaServerItem(id: "chernobyl", name: "Chernobyl", type: .series)]]) == nil)
        // An episode reference plays itself.
        #expect(AppleTitlePagePolicy.serverEpisodeToPlay(selectedID: nil, startID: nil, referenceID: "e2",
            referenceIsEpisode: true, episodesBySeason: episodes)?.id == "e2")
    }

    /// Cast & Crew for a server title comes from the metadata disk cache when
    /// the title was seen before: no TMDB call, no server call.
    @Test func catalogCreditsAreReadFromTheDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CreditCalls()
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            await calls.add()
            let body = url.path == "/3/find/tt7366338"
                ? #"{"movie_results":[],"tv_results":[{"id":87108}]}"#
                : #"{"id":87108,"name":"Chernobyl","credits":{"cast":[{"name":"Jared Harris","character":"Valery Legasov","profile_path":"/jh.jpg"}],"crew":[]}}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let fetched = try await client.cachedDetails(imdbID: "tt7366338", kind: .series, configuration: configuration,
            cache: AppleMetadataDiskCache(directory: directory))
        #expect(fetched.castMembers.map(\.name) == ["Jared Harris"])
        #expect(await calls.count == 2)
        let offline = AppleTMDBClient { _ in
            Issue.record("a cached title asked TMDB")
            throw URLError(.notConnectedToInternet)
        }
        let cached = try await offline.cachedDetails(imdbID: "tt7366338", kind: .series, configuration: configuration,
            cache: AppleMetadataDiskCache(directory: directory))
        #expect(cached == fetched)
    }
}

private actor CreditCalls {
    private(set) var count = 0
    func add() { count += 1 }
}
