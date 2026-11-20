import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleLiveFixtureOriginTests {
    @Test(arguments: [
        ("http://127.0.0.1/live.m3u8", true, true),
        ("http://10.42.0.1/live.m3u8", false, true),
        ("http://192.168.50.20/live.m3u8", false, true),
        ("http://172.20.0.10/live.m3u8", false, true),
        ("http://172.32.0.10/live.m3u8", false, false),
        ("http://203.0.113.1/live.m3u8", false, false),
        ("http://fixture.example/live.m3u8", false, false),
        ("http://fixture:fixture@10.42.0.1/live.m3u8", false, false),
        ("https://10.42.0.1/live.m3u8", false, false)
    ])
    @MainActor func inlinePlaybackRequiresAnExplicitPrivateLANOptIn(raw: String, loopback: Bool, optedIn: Bool) throws {
        let url = try #require(URL(string: raw))
        #expect(AppleLiveInlineFixtureView.isFixtureURL(url, allowsLAN: false) == loopback)
        #expect(AppleLiveInlineFixtureView.isFixtureURL(url, allowsLAN: true) == optedIn)
    }

    @Test(arguments: [
        ("http://127.0.0.1:8767/sliding/channels.m3u", true),
        ("http://127.0.0.1:8768/sliding/channels.m3u", false),
        ("https://127.0.0.1:8767/sliding/channels.m3u", false),
        ("http://fixture.example:8767/sliding/channels.m3u", false),
        ("http://fixture:fixture@127.0.0.1:8767/channels.m3u", false)
    ])
    func onlyTheExplicitLoopbackOriginCanBypassStubs(url: String, expected: Bool) throws {
        #expect(AppleNetworkStubPolicy.isLiveFixtureURL(try #require(URL(string: url)),
            base: try #require(URL(string: "http://127.0.0.1:8767"))) == expected)
    }

    @Test(arguments: ["http://fixture.example:8767", "https://127.0.0.1:8767",
                      "http://fixture:fixture@127.0.0.1:8767"])
    func anUnsafeBaseCannotGrantABypass(raw: String) throws {
        let base = try #require(URL(string: raw))
        #expect(!AppleNetworkStubPolicy.isLiveFixtureURL(base.appendingPathComponent("channels.m3u"), base: base))
    }
}
