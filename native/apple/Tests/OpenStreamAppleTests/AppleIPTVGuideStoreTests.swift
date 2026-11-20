import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AppleIPTVGuideStore Tests")
struct AppleIPTVGuideStoreTests {
    @MainActor @Test func oneRefreshPopulatesEveryVisibleChannelBeyondTheFirstFifty() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QualifiedGuideURLProtocol.self]
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: configuration)))
        let source = UUID()
        store.configure(xtreamBase: URL(string: "https://fixture.example")!, username: "fixture",
                        password: "fixture", sourceID: source)
        let ids = Set((1...300).map { "\(source.uuidString):\($0)" })
        await store.refreshVisible(channelIDs: ids)
        #expect(Set(store.guide(for: ids).allProgrammes.map(\.channelID)) == ids)
    }

    @Test func unconditionalLoadRejects304WithoutARetainedGuide() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnexpectedNotModifiedGuideProtocol.self]
        let loader = AppleIPTVGuideLoader(session: URLSession(configuration: config))
        await #expect(throws: URLError.self) {
            _ = try await loader.load(xmltvURL: URL(string: "https://fixture.example/unconditional.xml")!)
        }
    }

    @Test func playlistRetainsGuideURLAndProviderChannelID() throws {
        let data = Data("""
        #EXTM3U x-tvg-url="guide.xml"
        #EXTINF:-1 tvg-id="news.one",News One
        live/news.m3u8
        """.utf8)
        let channel = try #require(AppleIPTVClient.parseM3U(data, sourceID: UUID(),
            baseURL: URL(string: "https://fixture.example/playlist.m3u")!).first)
        #expect(channel.guideID == "news.one")
        #expect(channel.guideURL == URL(string: "https://fixture.example/guide.xml"))
    }

    @MainActor
    @Test func sourceQualifiedChannelIDsResolveGuideAndConfigurationsStaySeparate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QualifiedGuideURLProtocol.self]
        let loader = AppleIPTVGuideLoader(session: URLSession(configuration: configuration))
        let store = AppleIPTVGuideStore(loader: loader)
        let first = UUID()
        let second = UUID()
        store.configure(xtreamBase: URL(string: "https://first.example")!, username: "fixture", password: "fixture", sourceID: first)
        store.configure(xtreamBase: URL(string: "https://second.example")!, username: "fixture", password: "fixture", sourceID: second)
        let firstID = "\(first.uuidString):123"
        let secondID = "\(second.uuidString):123"
        await store.refreshVisible(channelIDs: [firstID, secondID])
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1700000000), duration: 3600)
        #expect(store.programmes(channelID: firstID, in: interval).first?.title == "first.example")
        #expect(store.programmes(channelID: secondID, in: interval).first?.title == "second.example")
        #expect(store.programmes(channelID: firstID, in: interval).first?.channelID == firstID)
    }

    @Test func testVisibleRefreshAndCacheExpiry() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let loader = AppleIPTVGuideLoader(session: session)
        
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await AppleIPTVGuideStore(loader: loader, diskCache: AppleIPTVGuideDiskCache(directory: directory))
        await store.configure(xmltvURL: URL(string: "https://fixture.example/guide.xml"))
        
        var requestCount = 0
        let xmlData = """
        <?xml version="1.0" encoding="utf-8"?>
        <tv>
            <channel id="ch1"><display-name>CH 1</display-name></channel>
            <programme start="20260902200000 +0000" stop="20260902210000 +0000" channel="ch1">
                <title>Test Prog</title>
            </programme>
        </tv>
        """.data(using: .utf8)!
        
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, xmlData)
        }
        
        await store.refreshVisible(channelIDs: ["ch1"])
        
        var progs = await store.programmes(channelID: "ch1", in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(progs.count == 1)
        #expect(progs[0].title == "Test Prog")
        #expect(requestCount == 1)
        
        // Refresh again, should use cache
        await store.refreshVisible(channelIDs: ["ch1"])
        progs = await store.programmes(channelID: "ch1", in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(progs.count == 1)
        #expect(requestCount == 1)
        
        // A new channel is served from the already parsed XMLTV file
        await store.refreshVisible(channelIDs: ["ch2"])
        #expect(requestCount == 1)
    }
}

private final class QualifiedGuideURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let title = request.url?.host ?? "missing"
        let body = """
        {"epg_listings":[{"title":"\(title)","start_timestamp":"1700000000","stop_timestamp":"1700003600"}]}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UnexpectedNotModifiedGuideProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 304,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
