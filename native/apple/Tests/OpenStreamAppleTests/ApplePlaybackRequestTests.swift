import Foundation
import Testing
@testable import OpenStreamApple

@Test func externalPlaybackRequiresAPublicHeaderFreeRoute() {
    let direct = ApplePlaybackRequest(url: URL(string: "https://media.example/movie.mp4")!, mediaID: "fixture", sourceKind: .stremio)
    #expect(direct.allowsExternalPlayback(playerURL: direct.url))
    #expect(!direct.allowsExternalPlayback(playerURL: URL(string: "http://127.0.0.1/movie.m3u8")!))
    #expect(!direct.allowsExternalPlayback(playerURL: URL(string: "http://[::1]/movie.m3u8")!))
    #expect(!direct.allowsExternalPlayback(playerURL: URL(fileURLWithPath: "/tmp/movie.mp4")))
    #expect(!direct.allowsExternalPlayback(playerURL: nil))
    var protected = direct
    protected.headers = ["Referer": "https://fixture.example"]
    #expect(!protected.allowsExternalPlayback(playerURL: direct.url))
}

@Test func effectiveHeadersProxyHeadersOverrideRequestHeadersOnCollision() {
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/video.mp4")!,
        headers: ["User-Agent": "A"],
        mediaID: "id",
        sourceKind: .files,
        hints: .init(notWebReady: false, proxyHeaders: ["User-Agent": "B"])
    )
    #expect(request.effectiveHeaders["User-Agent"] == "B")
}

@Test func effectiveDVRWindowSecondsDefaultsTo1800ForLiveWhenAbsent() {
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/live.m3u8")!,
        isLive: true,
        mediaID: "id",
        sourceKind: .iptv
    )
    #expect(request.effectiveDVRWindowSeconds == 1800)
}

@Test func effectiveDVRWindowSecondsIsNilForNonLiveEvenWhenSet() {
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/video.mp4")!,
        isLive: false,
        dvrWindowSeconds: 3600,
        mediaID: "id",
        sourceKind: .files
    )
    #expect(request.effectiveDVRWindowSeconds == nil)
}

@Test func effectiveDVRWindowSecondsUsesExplicitValueWhenProvidedForLive() {
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/live.m3u8")!,
        isLive: true,
        dvrWindowSeconds: 600,
        mediaID: "id",
        sourceKind: .iptv
    )
    #expect(request.effectiveDVRWindowSeconds == 600)
}

@MainActor
@Test func fakeEngineEmitsScriptedPhasesInOrderAndEndsOnLastPhase() async throws {
    let engine = FakePlaybackEngine()
    engine.script([.loading, .playing])
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/video.mp4")!,
        mediaID: "id",
        sourceKind: .files
    )

    let stream = engine.events
    try await engine.load(request)

    var collected: [ApplePlaybackEngineEvent] = []
    for await event in stream {
        collected.append(event)
        if collected.count >= 2 { break }
    }

    #expect(collected == [.phase(.loading), .phase(.playing)])
    #expect(engine.phase == .playing)
}

@MainActor
@Test func fakeEngineFailOnLoadThrowsAndSetsFailure() async throws {
    let engine = FakePlaybackEngine()
    engine.failOnLoad = ApplePlaybackFailure(kind: .unsupportedMedia, message: "Unsupported format.")
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/video.mkv")!,
        mediaID: "id",
        sourceKind: .files
    )

    do {
        try await engine.load(request)
        Issue.record("load should have thrown")
    } catch let failure as ApplePlaybackFailure {
        #expect(failure.kind == .unsupportedMedia)
        #expect(engine.failure?.kind == .unsupportedMedia)
    }
}

@Test func playbackRequestEqualityComparesAllFields() {
    let url = URL(string: "https://media.example/video.mp4")!
    let a = ApplePlaybackRequest(url: url, mediaID: "id", sourceKind: .files)
    let b = ApplePlaybackRequest(url: url, mediaID: "id", sourceKind: .files)
    #expect(a == b)

    let c = ApplePlaybackRequest(url: url, mediaID: "other", sourceKind: .files)
    #expect(a != c)
}

@Test func hintsDefaultsAreEmpty() {
    let hints = ApplePlaybackRequest.Hints()
    #expect(hints.notWebReady == false)
    #expect(hints.proxyHeaders.isEmpty)
    #expect(hints.filename == nil)
}
