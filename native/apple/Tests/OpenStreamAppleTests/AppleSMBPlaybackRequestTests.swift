import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized) struct AppleSMBPlaybackRequestTests {
    @Test func networkItemUsesLoopbackRequestAndEngineSourceKindWithoutInspection() async throws {
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let source = AppleSource(
            id: sourceID,
            kind: .nas,
            name: "TestMedia",
            url: try AppleSMBEndpointPolicy.makeURL(
                host: "192.0.2.12",
                port: 1445,
                share: "TestMedia"
            )
        )
        let item = AppleLibraryItem(
            sourceID: sourceID,
            name: "Sample Show S01E01.mkv",
            url: URL(string: "smb://192.0.2.12:1445/TestMedia/Shows/Sample%20Show/S01E01.mkv")!,
            relativePath: "Shows/Sample Show/S01E01.mkv",
            sizeBytes: 10_000
        )
        let loopbackURL = URL(string: "http://127.0.0.1:49152/media/test-token/Sample%20Show%20S01E01.mkv")!
        let request = AppleSMBPlaybackRequestFactory.make(
            source: source,
            item: item,
            playbackURL: loopbackURL
        )

        #expect(request.url == loopbackURL)
        #expect(request.url.host == "127.0.0.1")
        #expect(request.sourceKind == .networkShare)
        #expect(request.headers.isEmpty)
        #expect(request.isLive == false)
        #expect(request.hints.filename == item.name)
        #expect(request.mediaID == AppleMediaIngestion.libraryRecord(source: source, item: item).id)

        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(request)
        #expect(engine.loadedRequests == [request])
        coordinator.stop()
    }
}
