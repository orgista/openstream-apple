import Foundation
import Testing
@testable import OpenStreamApple

private func subtitleSource(
    host: String,
    name: String,
    resources: [String] = ["stream", "subtitles"],
    enabled: Bool = true
) -> AppleSource {
    AppleSource(
        kind: .stremio,
        name: name,
        url: URL(string: "https://\(host)/manifest.json")!,
        isEnabled: enabled,
        manifestID: host,
        resources: resources
    )
}

// MARK: - Parser

@Test func subRipParserKeepsMultiLineCuesAndStripsMarkup() {
    let srt = """
    1
    00:00:01,000 --> 00:00:04,500
    <i>First line</i>
    {\\an8}Second &amp; last

    2
    01:02:03,250 --> 01:02:04,000
    Later

    """
    let cues = AppleSubtitleTextParser.cues(from: srt)
    #expect(cues.count == 2)
    #expect(cues[0].startTime == 1)
    #expect(cues[0].endTime == 4.5)
    #expect(cues[0].text == "First line\nSecond & last")
    #expect(cues[1].startTime == 3723.25)
    #expect(cues[1].text == "Later")
    #expect(cues.map(\.id) == [0, 1])
}

@Test func webVTTParserAcceptsHourLessTimestampsAndCueSettings() {
    let vtt = """
    WEBVTT

    NOTE this file has no hours

    intro
    00:01.000 --> 00:03.500 line:90% align:middle
    Hello <b>there</b>

    00:00:05.000 --> 00:00:06.000
    Done
    """
    let cues = AppleSubtitleTextParser.cues(from: vtt)
    #expect(cues.count == 2)
    #expect(cues[0].startTime == 1)
    #expect(cues[0].endTime == 3.5)
    #expect(cues[0].text == "Hello there")
    #expect(cues[1].startTime == 5)
    #expect(cues[1].text == "Done")
}

@Test func subtitleParserIgnoresCuesWithoutUsableTextOrTiming() {
    let broken = """
    1
    not a timing line
    Ignored

    2
    00:00:02,000 --> 00:00:02,000
    Zero length

    3
    00:00:09,000 --> 00:00:10,000
    Kept
    """
    let cues = AppleSubtitleTextParser.cues(from: broken)
    #expect(cues.count == 1)
    #expect(cues[0].text == "Kept")
}

@Test func subtitleParserInflatesGzippedFiles() throws {
    let srt = """
    1
    00:00:01,000 --> 00:00:02,000
    Packed
    """
    let deflated = try (Data(srt.utf8) as NSData).compressed(using: .zlib) as Data
    var gzipped = Data([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03])
    gzipped.append(contentsOf: Array("film.srt".utf8) + [0]) // FNAME
    gzipped.append(deflated)
    gzipped.append(Data(count: 8)) // CRC32 + ISIZE, unchecked here
    let cues = AppleSubtitleTextParser.cues(from: gzipped)
    #expect(cues.count == 1)
    #expect(cues[0].text == "Packed")
}

// MARK: - Service

@Test func externalSubtitleServiceMergesAddOnsAndKeepsOneTrackPerLanguage() async {
    let client = AppleStremioPlaybackClient { request in
        let path = request.url?.absoluteString ?? ""
        let body: String
        if path.contains("first.example") {
            body = #"""
            {"subtitles":[
              {"id":"a","url":"https://subs.example/a.srt","lang":"eng"},
              {"id":"b","url":"https://subs.example/b.srt","lang":"fra"}
            ]}
            """#
        } else if path.contains("second.example") {
            body = #"""
            {"subtitles":[
              {"id":"c","url":"https://subs.example/c.srt","lang":"eng"},
              {"id":"d","url":"https://subs.example/d.srt","lang":"spa"}
            ]}
            """#
        } else {
            body = #"{"subtitles":[]}"#
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let service = AppleExternalSubtitleService(client: client, timeout: .seconds(2))
    let query = try! #require(AppleExternalSubtitleQuery(type: "series", mediaID: "tt765", season: 2, episode: 6))
    #expect(query.mediaID == "tt765:2:6")

    let tracks = await service.tracks(
        for: query,
        sources: [
            subtitleSource(host: "first.example", name: "First"),
            subtitleSource(host: "second.example", name: "Second"),
            // No `subtitles` resource, so it is never asked.
            subtitleSource(host: "streams.example", name: "Streams", resources: ["stream"]),
            subtitleSource(host: "off.example", name: "Off", enabled: false),
        ]
    )

    #expect(tracks.map(\.languageCode) == ["eng", "fra", "spa"])
    #expect(tracks[0].displayName == "English (First)")
    #expect(tracks[2].displayName.hasSuffix("(Second)"))
    #expect(tracks[0].url.absoluteString == "https://subs.example/a.srt")
}

@Test func externalSubtitleServiceFailsOpenWhenAnAddOnIsBroken() async {
    let client = AppleStremioPlaybackClient { request in
        let path = request.url?.absoluteString ?? ""
        if path.contains("broken.example") { throw URLError(.cannotConnectToHost) }
        let body = #"{"subtitles":[{"id":"a","url":"https://subs.example/a.vtt","lang":"eng"}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let service = AppleExternalSubtitleService(client: client, timeout: .seconds(2))
    let query = try! #require(AppleExternalSubtitleQuery(type: "movie", mediaID: "tt111"))
    let tracks = await service.tracks(
        for: query,
        sources: [subtitleSource(host: "broken.example", name: "Broken"), subtitleSource(host: "ok.example", name: "OK")]
    )
    #expect(tracks.count == 1)
    #expect(tracks[0].displayName == "English (OK)")
}

// MARK: - Engine

@MainActor
@Test func externalTracksAppendAfterEmbeddedOnesAndLoadTheirCuesWhenSelected() throws {
    let engine = try AetherPlaybackEngine()
    engine.externalSubtitleDataLoader = { url in
        #expect(url.absoluteString == "https://subs.example/english.srt")
        return Data("""
        1
        00:00:02,000 --> 00:00:05,000
        From the add-on
        """.utf8)
    }
    engine.applyEmbeddedSubtitleTracks([
        ApplePlaybackTrack(id: 0, title: "English", language: "eng"),
        ApplePlaybackTrack(id: 1, title: "Forced", language: "eng"),
    ])
    engine.addExternalSubtitleTracks([
        AppleExternalSubtitleTrack(
            id: "addon:english",
            languageCode: "eng",
            sourceName: "Example",
            url: URL(string: "https://subs.example/english.srt")!
        ),
    ])

    #expect(engine.subtitleTracks.map(\.id) == [0, 1, AetherPlaybackEngine.externalSubtitleTrackIDBase])
    #expect(engine.subtitleTracks.last?.title == "English (Example)")
}

@MainActor
@Test func selectingAnExternalSubtitleTrackRendersItsParsedCues() async throws {
    let engine = try AetherPlaybackEngine()
    engine.externalSubtitleDataLoader = { _ in
        Data("""
        1
        00:00:02,000 --> 00:00:05,000
        From the add-on
        """.utf8)
    }
    engine.addExternalSubtitleTracks([
        AppleExternalSubtitleTrack(
            id: "addon:english",
            languageCode: "eng",
            sourceName: "Example",
            url: URL(string: "https://subs.example/english.srt")!
        ),
    ])
    engine.selectSubtitleTrack(id: AetherPlaybackEngine.externalSubtitleTrackIDBase)

    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while engine.subtitleCues.isEmpty, ContinuousClock().now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(engine.subtitleCues.count == 1)
    #expect(engine.subtitleCues.first?.text == "From the add-on")
    #expect(engine.subtitleCues.first?.startTime == 2)

    // Switching back to "Off" drops the add-on cues.
    engine.selectSubtitleTrack(id: nil)
    #expect(engine.subtitleCues.isEmpty)
}

// MARK: - Coordinator hook

@MainActor
@Test func playbackCoordinatorHandsFetchedSubtitlesToTheEngineWithoutDelayingTheLoad() async {
    let engine = FakePlaybackEngine()
    engine.loadHandler = { _ in engine.phase = .playing }
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    coordinator.externalSubtitleFetcher = { query in
        #expect(query.mediaID == "tt765:2:6")
        return [
            AppleExternalSubtitleTrack(
                id: "addon:english",
                languageCode: "eng",
                sourceName: "Example",
                url: URL(string: "https://subs.example/english.srt")!
            ),
        ]
    }
    let request = ApplePlaybackRequest(
        url: URL(string: "https://media.example/movie.mkv")!,
        mediaID: "record-id",
        sourceKind: .stremio,
        hints: .init(addonMediaID: "tt765:2:6", addonMediaType: "series")
    )
    await coordinator.begin(request)
    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while engine.externalSubtitleTracks.isEmpty, ContinuousClock().now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(engine.externalSubtitleTracks.map(\.languageCode) == ["eng"])
    #expect(coordinator.phase == .playing)
    coordinator.stop()
}

@MainActor
@Test func playbackCoordinatorSkipsSubtitleFetchWithoutAnAddOnIdentity() async {
    let engine = FakePlaybackEngine()
    engine.loadHandler = { _ in engine.phase = .playing }
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    coordinator.externalSubtitleFetcher = { _ in
        Issue.record("A request without an add-on identity must not query add-ons")
        return []
    }
    await coordinator.begin(
        ApplePlaybackRequest(
            url: URL(string: "file:///movies/local.mkv")!,
            mediaID: "record-id",
            sourceKind: .files
        )
    )
    try? await Task.sleep(for: .milliseconds(50))
    #expect(engine.externalSubtitleTracks.isEmpty)
    coordinator.stop()
}
