import Testing
@testable import OpenStreamApple

@Suite struct AppleLogicalItemKeyTests {
    @Test func titleKeyPrefersIMDbLowercasesAndFallsBackToTMDb() {
        #expect(AppleLogicalItemKey.title(kind: .series, imdb: "TT0903747", tmdb: "1396") == "li:series:tt0903747")
        #expect(AppleLogicalItemKey.title(kind: .series, imdb: nil, tmdb: "1396") == "li:series:tmdb:1396")
        #expect(AppleLogicalItemKey.title(kind: .movie, imdb: nil, tmdb: nil) == nil)
    }
    @Test func emptyTitleIDsAreAbsent() {
        #expect(AppleLogicalItemKey.title(kind: .movie, imdb: "", tmdb: "") == nil)
        #expect(AppleLogicalItemKey.title(kind: .movie, imdb: "", tmdb: "123") == "li:movie:tmdb:123")
    }
    @Test func episodeKeyAppendsSeasonAndEpisode() {
        #expect(AppleLogicalItemKey.episode(seriesKey: "li:series:tt1", season: 1, episode: 2) == "li:series:tt1:1:2")
    }
    @Test func localFileClassNeedsPositiveSize() {
        #expect(AppleLogicalItemKey.localFileClass(titleKey: "li:movie:tt1", season: nil, episode: nil, sizeBytes: 0) == nil)
        #expect(AppleLogicalItemKey.localFileClass(titleKey: "li:movie:tt1", season: nil, episode: nil, sizeBytes: -1) == nil)
        #expect(AppleLogicalItemKey.localFileClass(titleKey: "li:movie:tt1", season: nil, episode: nil, sizeBytes: 734003200) == "li:movie:tt1:734003200")
        #expect(AppleLogicalItemKey.localFileClass(titleKey: "li:series:tt1", season: 1, episode: 2, sizeBytes: 734003200) == "li:series:tt1:1:2:734003200")
    }
    @Test func legacyEpisodeClassIsPrefixed() {
        #expect(AppleLogicalItemKey.legacyEpisodeClass(fileEpisodeID: "local-file-example") == "le:local-file-example")
    }
}
