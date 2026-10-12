import Foundation
import MediaPlayer
import Testing
@testable import OpenStreamApple

@Suite("Now Playing metadata")
struct AppleNowPlayingInfoTests {
    private func episodeRequest() throws -> ApplePlaybackRequest {
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/e.mkv")),
                                           mediaID: "tt1:1:3", title: "S1 E3 · Name", sourceKind: .stremio)
        request.subtitle = "Fixture Show"
        request.artworkURL = URL(string: "https://fixture.example/poster.jpg")
        return request
    }

    @Test("An episode: 'S1, E3 · Name', the series as album/artist, video, its poster and duration")
    func episode() throws {
        let metadata = AppleNowPlayingMetadata(request: try episodeRequest())
        #expect(metadata.title == "S1, E3 · Name")
        #expect(metadata.seriesTitle == "Fixture Show")
        #expect(metadata.artworkURL?.absoluteString == "https://fixture.example/poster.jpg")
        let info = metadata.nowPlayingInfo(position: 12, duration: 1_800, isPlaying: true)
        #expect(info[MPMediaItemPropertyTitle] as? String == "S1, E3 · Name")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Fixture Show")
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
        #expect(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 1_800)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
    }

    @Test("A channel: live, no duration, the logo as artwork, no series line")
    func live() throws {
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.m3u8")),
                                           isLive: true, mediaID: "ch1", title: "Fixture News", sourceKind: .liveTV)
        request.artworkURL = URL(string: "https://fixture.example/logo.png")
        let metadata = AppleNowPlayingMetadata(request: request)
        let info = metadata.nowPlayingInfo(position: 40, duration: 3_600, isPlaying: false)
        #expect(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info[MPMediaItemPropertyAlbumTitle] == nil)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(metadata.artworkURL != nil)
    }

    @Test("A film keeps its own title; credentials or odd schemes never become artwork")
    func filmAndArtworkGuard() {
        let film = AppleNowPlayingMetadata(title: "Fixture Film", seriesTitle: nil, isLive: false,
                                           artworkURL: URL(string: "https://user:pw@fixture.example/p.jpg"))
        #expect(film.title == "Fixture Film")
        #expect(film.artworkURL == nil)
        #expect(AppleNowPlayingMetadata(title: nil, isLive: false,
                                        artworkURL: URL(string: "file:///tmp/p.jpg")).artworkURL == nil)
        #expect(AppleNowPlayingMetadata(title: "  ", isLive: false).title == "oStream")
        #expect(AppleNowPlayingMetadata(title: "  ", isLive: false).knownTitle == nil)
    }

    @Test("Channel and add-on requests carry their artwork")
    func requestsCarryArtwork() throws {
        let channel = AppleIPTVChannel(id: "ch", sourceID: UUID(), name: "Fixture",
                                       logoURL: URL(string: "https://fixture.example/logo.png"),
                                       streamURL: try #require(URL(string: "https://fixture.example/1.ts")))
        #expect(channel.playbackRequest().artworkURL?.lastPathComponent == "logo.png")
    }
}
