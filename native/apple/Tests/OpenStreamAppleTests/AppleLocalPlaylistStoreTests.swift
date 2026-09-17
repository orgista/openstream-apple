import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleM3UTextMergerTests {
    let a = """
    #EXTM3U url-tvg="https://fixture.example/epg.xml"
    #EXTINF:-1 tvg-id="tf1.fr" group-title="Généralistes",TF1
    https://fixture.example/tf1.m3u8
    #EXTINF:-1 group-title="Généralistes",France 2
    https://fixture.example/f2.m3u8
    """

    @Test func firstPasteKeepsHeaderAndEveryDirective() {
        let result = AppleM3UTextMerger.merge(existing: nil, incoming: a)
        #expect(result.added == 2)
        #expect(result.total == 2)
        #expect(result.text.hasPrefix("#EXTM3U url-tvg=\"https://fixture.example/epg.xml\"\n"))
        #expect(result.text.contains("#EXTINF:-1 tvg-id=\"tf1.fr\" group-title=\"Généralistes\",TF1\nhttps://fixture.example/tf1.m3u8\n"))
    }

    @Test func secondPasteAppendsOnlyNewStreams() {
        let first = AppleM3UTextMerger.merge(existing: nil, incoming: a)
        let second = AppleM3UTextMerger.merge(existing: first.text, incoming: """
        #EXTM3U
        #EXTINF:-1,France 2 (dup)
        https://fixture.example/f2.m3u8
        #EXTINF:-1,M6
        https://fixture.example/m6.m3u8
        """)
        #expect(second.added == 1)
        #expect(second.total == 3)
        #expect(second.text.components(separatedBy: "https://fixture.example/f2.m3u8").count == 2)
        #expect(second.text.contains("France 2\n"))   // the first copy's name wins
        #expect(second.text.hasSuffix("#EXTINF:-1,M6\nhttps://fixture.example/m6.m3u8\n"))
    }

    @Test func bareURLListsWork() {
        let result = AppleM3UTextMerger.merge(existing: nil, incoming: "https://fixture.example/a.m3u8\n\nhttps://fixture.example/b.m3u8\n")
        #expect(result.total == 2)
        #expect(result.text == "#EXTM3U\nhttps://fixture.example/a.m3u8\nhttps://fixture.example/b.m3u8\n")
    }

    @Test func guideHeaderIsAdoptedWhenOursHasNone() {
        let plain = AppleM3UTextMerger.merge(existing: nil, incoming: "#EXTM3U\nhttps://fixture.example/a.m3u8")
        let merged = AppleM3UTextMerger.merge(existing: plain.text, incoming: a)
        #expect(merged.text.hasPrefix("#EXTM3U url-tvg="))
        #expect(merged.total == 3)
    }
}

@Suite struct AppleLocalPlaylistStoreTests {
    @Test func mergeWritesOneFileTheClientCanRead() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "playlists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppleLocalPlaylistStore(directory: dir)
        try store.merge(text: "#EXTINF:-1,TF1\nhttps://fixture.example/tf1.m3u8")
        let second = try store.merge(text: "#EXTINF:-1,M6\nhttps://fixture.example/m6.m3u8")
        #expect(second.added == 1 && second.total == 2)

        let data = try store.read(AppleLocalPlaylistStore.pastedURL)
        let channels = try AppleIPTVClient.parseM3U(data, sourceID: UUID(), baseURL: AppleLocalPlaylistStore.pastedURL)
        #expect(channels.map(\.name) == ["TF1", "M6"])
    }

    @Test func endpointPolicyAcceptsTheLocalPlaylistURL() throws {
        let url = try AppleIPTVEndpointPolicy.normalize(AppleLocalPlaylistStore.pastedURL.absoluteString)
        #expect(url == AppleLocalPlaylistStore.pastedURL)
        #expect(AppleLocalPlaylistStore.localURL(from: "openstream-playlist://elsewhere/x.m3u") == nil)
        #expect(AppleLocalPlaylistStore.localURL(from: "https://fixture.example/list.m3u") == nil)
    }
}
