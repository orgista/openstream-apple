import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleLiveStreamRoutePolicyTests {
    let bare = URL(string: "https://fixture.example/895")!
    let hls = URL(string: "https://fixture.example/live/tf1.m3u8")!
    let ts = URL(string: "http://fixture.example/live/u/p/22128.ts")!

    @Test func onlyExtensionLessHTTPURLsNeedAProbe() {
        #expect(AppleLiveStreamRoutePolicy.needsProbe(bare))
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(hls))
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(ts))
        #expect(!AppleLiveStreamRoutePolicy.needsProbe(URL(string: "openstream-playlist://local/x.m3u")!))
    }

    @Test func extensionsDecideWithoutAProbe() {
        #expect(AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: hls, probedKind: nil))
        #expect(!AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: ts, probedKind: nil))
        #expect(!AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: bare, probedKind: nil))
    }

    @Test func aProbeVerdictWins() {
        #expect(AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: bare, probedKind: .hlsPlaylist))
        #expect(!AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: bare, probedKind: .rawMPEGTransportStream))
        #expect(!AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: hls, probedKind: .rawMPEGTransportStream))
    }

    @Test func channelRequestCarriesTheVerdict() {
        let channel = AppleIPTVChannel(id: "c1", sourceID: UUID(), name: "TMC", group: "Généralistes",
                                       logoURL: nil, streamURL: bare, userAgent: nil, referer: nil, origin: nil,
                                       guideID: nil, guideURL: nil)
        #expect(!channel.playbackRequest().hints.nativeRemoteHLS)
        #expect(channel.withProbedMediaKind(.hlsPlaylist).playbackRequest().hints.nativeRemoteHLS)
        #expect(channel.withProbedMediaKind(.hlsPlaylist).playbackRequest().isLive)
    }

    @Test func cachedChannelsWithoutTheFieldStillDecode() throws {
        let channel = AppleIPTVChannel(id: "c1", sourceID: UUID(), name: "TMC", group: "g",
                                       logoURL: nil, streamURL: bare, userAgent: nil, referer: nil, origin: nil,
                                       guideID: nil, guideURL: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(channel)) as! [String: Any]
        json["probedMediaKind"] = nil
        let decoded = try JSONDecoder().decode(AppleIPTVChannel.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.probedMediaKind == nil)
        #expect(decoded.streamURL == bare)
    }

    @Test func guideLoaderAcceptsANationalXMLTVFileBehindARedirect() {
        #expect(AppleIPTVGuideLoader.maximumGuideBytes >= 16 * 1024 * 1024)
        #expect(AppleIPTVGuideLoader.redirectPolicy == .secureHTTPOnly)
        #expect(AppleIPTVGuideLoader.requestTimeout >= 20)
    }
}
