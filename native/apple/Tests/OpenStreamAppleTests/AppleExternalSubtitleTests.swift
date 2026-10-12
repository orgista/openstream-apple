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
        ],
        // Named outright: an empty list now means the device's language only.
        preferredLanguages: ["eng", "fra", "spa"]
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

    // The download and parse run in a task; wait for it to finish rather than
    // for a wall-clock deadline, which a loaded gate run could outlast.
    let load = try #require(engine.pendingExternalSubtitleLoad)
    await load.value
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

// MARK: - Add-on language and native cue regression coverage

@MainActor
@Test(arguments: [("eng", "en" as String?), ("en-US", "en"), ("", nil), ("und", nil)])
func addOnTracksUseEmbeddedLanguageNormalization(code: String, expected: String?) throws {
    let track = AppleExternalSubtitleTrack(
        id: "fixture", languageCode: code, displayName: "Fixture subtitles",
        url: URL(fileURLWithPath: "/unused.srt"))
    let native = NativePlaybackEngine()
    let aether = try AetherPlaybackEngine()
    for engine: any ApplePlaybackEngine in [native, aether] {
        engine.addExternalSubtitleTracks([track])
        let appended = try #require(engine.subtitleTracks.first)
        #expect(appended.language == expected)
        engine.stop()
    }
}

@MainActor
@Test(arguments: [AppleCaptionsPreference.always, .english, .deviceLanguage])
func preferredLanguageAutoSelectsAnAddOnTrack(preference: AppleCaptionsPreference) async throws {
    let native = NativePlaybackEngine()
    let aether = try AetherPlaybackEngine()
    native.externalSubtitleDataLoader = { _ in Data("1\n00:00:00,000 --> 00:01:00,000\nFixture cue\n".utf8) }
    aether.externalSubtitleDataLoader = native.externalSubtitleDataLoader
    for engine: any ApplePlaybackEngine in [native, aether] {
        engine.applyCaptionPreferences(preference: preference, languages: ["eng"], languagesAreExplicit: true)
        engine.addExternalSubtitleTracks([
            AppleExternalSubtitleTrack(id: "french", languageCode: "fra", displayName: "French",
                                       url: URL(fileURLWithPath: "/unused-fr.srt")),
            AppleExternalSubtitleTrack(id: "english", languageCode: "eng", displayName: "English",
                                       url: URL(fileURLWithPath: "/unused-en.srt")),
        ])
        let english = try #require(engine.subtitleTracks.first { $0.language == "en" })
        let load = try #require(engine is NativePlaybackEngine ? native.externalSubtitleLoad : aether.pendingExternalSubtitleLoad)
        await load.value
        #expect(engine.activeSubtitleTrackID == english.id)
        engine.selectSubtitleTrack(id: nil)
        engine.addExternalSubtitleTracks([
            AppleExternalSubtitleTrack(id: "another", languageCode: "eng", displayName: "Another",
                                       url: URL(fileURLWithPath: "/unused-other.srt"))
        ])
        #expect(engine.activeSubtitleTrackID == nil)
        engine.stop()
    }
}

@MainActor
@Test func languageAutoSelectionDoesNotFallBackToAnUnmatchedAddOn() throws {
    let native = NativePlaybackEngine()
    let aether = try AetherPlaybackEngine()
    for engine: any ApplePlaybackEngine in [native, aether] {
        engine.applyCaptionPreferences(preference: .english, languages: ["eng"], languagesAreExplicit: false)
        engine.addExternalSubtitleTracks([
            AppleExternalSubtitleTrack(id: "french", languageCode: "fra", displayName: "French",
                                       url: URL(fileURLWithPath: "/unused.srt"))
        ])
        #expect(engine.activeSubtitleTrackID == nil)
        engine.stop()
    }
}

private var nativeSubtitleFixture: AppleExternalSubtitleTrack {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/addon-subtitles.srt")
    return AppleExternalSubtitleTrack(
        id: "local-srt", languageCode: "eng", displayName: "English fixture", url: url)
}

@concurrent
private func readSubtitleFixture(_ url: URL) async throws -> Data {
    #expect(url.isFileURL)
    return try Data(contentsOf: url)
}

@MainActor
@Test func nativeEnginePublishesParsedLocalSRTCuesThroughTheAppMenu() async throws {
    let engine = NativePlaybackEngine()
    defer { engine.stop() }
    engine.externalSubtitleDataLoader = readSubtitleFixture
    engine.addExternalSubtitleTracks([nativeSubtitleFixture, nativeSubtitleFixture])
    #expect(engine.subtitleTracks.count == 1)
    let track = try #require(engine.subtitleTracks.first)
    let entries = AppleSubtitleCueLayerPolicy.menuEntries(
        tracks: engine.subtitleTracks, preferredLanguages: ["en"],
        languagesAreExplicit: true, activeTrackID: nil)
    let selected = try #require(entries.last?.trackID)
    let menu = AppleStockPlayerSubtitles()
    menu.select(selected, on: engine)
    let load = try #require(engine.externalSubtitleLoad)
    await load.value
    #expect(engine.activeSubtitleTrackID == track.id)
    #expect(engine.subtitleCues.map(\.text) == ["From the add-on", "Second line"])
    #expect(engine.subtitleCues.map(\.startTime) == [0, 4])
    #expect(engine.subtitleCues.map(\.endTime) == [3, 6])
    menu.refresh(from: engine)
    #expect(menu.cues.map(\.text) == ["From the add-on"])
    #expect(AppleSubtitleCueLayerPolicy.activeCues(in: engine.subtitleCues, at: 3).isEmpty)
    #expect(AppleSubtitleCueLayerPolicy.activeCues(in: engine.subtitleCues, at: 5).first?.text == "Second line")
    menu.select(nil, on: engine)
    #expect(engine.subtitleCues.isEmpty)
    #expect(menu.cues.isEmpty)
}

@MainActor
@Test func nativeStopCancelsPendingSidecarAndClearsTracks() async throws {
    let engine = NativePlaybackEngine()
    engine.externalSubtitleDataLoader = readSubtitleFixture
    engine.addExternalSubtitleTracks([nativeSubtitleFixture])
    engine.selectSubtitleTrack(id: try #require(engine.subtitleTracks.first?.id))
    let load = try #require(engine.externalSubtitleLoad)
    engine.stop()
    await load.value
    #expect(engine.subtitleCues.isEmpty)
    #expect(engine.subtitleTracks.isEmpty)
    #expect(engine.activeSubtitleTrackID == nil)
    #expect(engine.externalSubtitleLoad == nil)
}

@MainActor
@Test func addOnWithMissingStremioLanguageBecomesANilLanguageTrack() throws {
    let data = Data(#"{"subtitles":[{"id":"missing-lang","url":"https://fixture.example/subtitles.srt"}]}"#.utf8)
    let parsed = try #require(AppleStremioPlaybackClient.parseSubtitles(data).first)
    let track = AppleExternalSubtitleTrack(
        id: parsed.id, languageCode: parsed.language, sourceName: "Fixture", url: parsed.url)
    let native = NativePlaybackEngine()
    let aether = try AetherPlaybackEngine()
    for engine: any ApplePlaybackEngine in [native, aether] {
        engine.addExternalSubtitleTracks([track])
        #expect(try #require(engine.subtitleTracks.first).language == nil)
        engine.stop()
    }
}

private actor SubtitleDownloadGate {
    private var reader: CheckedContinuation<Data, any Error>?
    private var observer: CheckedContinuation<Void, Never>?

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            reader = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitForRead() async {
        if reader != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func finish(fails: Bool) {
        if fails { reader?.resume(throwing: URLError(.cannotConnectToHost)) }
        else { reader?.resume(returning: Data("1\n00:00:00,000 --> 00:01:00,000\nFixture cue\n".utf8)) }
        reader = nil
    }
}

@MainActor
@Test(arguments: [false, true])
func externalSubtitleIsSelectedOnlyAfterASuccessfulDownload(fails: Bool) async throws {
    for useNative in [false, true] {
        let gate = SubtitleDownloadGate()
        let aether = try AetherPlaybackEngine()
        aether.captionsPreference = .off
        let native = NativePlaybackEngine()
        native.applyCaptionPreferences(preference: .off, languages: [], languagesAreExplicit: false)
        aether.externalSubtitleDataLoader = { _ in try await gate.read() }
        native.externalSubtitleDataLoader = { _ in try await gate.read() }
        let engine: any ApplePlaybackEngine = useNative ? native : aether
        defer { engine.stop() }
        engine.addExternalSubtitleTracks([.init(id: "fixture", languageCode: "en", sourceName: "Fixture",
            url: URL(string: "https://fixture.example/subtitle.srt")!)])
        engine.selectSubtitleTrack(id: 1_000_000)
        await gate.waitForRead()
        #expect(engine.activeSubtitleTrackID == nil)
        let load = try #require(useNative ? native.externalSubtitleLoad : aether.pendingExternalSubtitleLoad)
        await gate.finish(fails: fails)
        await load.value
        #expect(engine.activeSubtitleTrackID == (fails ? nil : 1_000_000))
        #expect(engine.subtitleCues.isEmpty == fails)
        if fails {
            native.externalSubtitleDataLoader = { _ in Data("1\n00:00:00,000 --> 00:01:00,000\nRetry cue\n".utf8) }
            aether.externalSubtitleDataLoader = native.externalSubtitleDataLoader
            engine.selectSubtitleTrack(id: 1_000_000)
            let retry = try #require(useNative ? native.externalSubtitleLoad : aether.pendingExternalSubtitleLoad)
            await retry.value
            #expect(engine.activeSubtitleTrackID == 1_000_000)
            #expect(engine.subtitleCues.first?.text == "Retry cue")
        }
    }
}

@MainActor
@Test func cancellingAPendingSubtitleCannotSelectItAfterDownload() async throws {
    for useNative in [false, true] {
        let gate = SubtitleDownloadGate()
        let aether = try AetherPlaybackEngine()
        aether.captionsPreference = .off
        let native = NativePlaybackEngine()
        native.applyCaptionPreferences(preference: .off, languages: [], languagesAreExplicit: false)
        aether.externalSubtitleDataLoader = { _ in try await gate.read() }
        native.externalSubtitleDataLoader = { _ in try await gate.read() }
        let engine: any ApplePlaybackEngine = useNative ? native : aether
        defer { engine.stop() }
        engine.addExternalSubtitleTracks([.init(id: "fixture", languageCode: "en", sourceName: "Fixture",
            url: URL(string: "https://fixture.example/subtitle.srt")!)])
        engine.selectSubtitleTrack(id: 1_000_000)
        await gate.waitForRead()
        let load = try #require(useNative ? native.externalSubtitleLoad : aether.pendingExternalSubtitleLoad)
        engine.selectSubtitleTrack(id: nil)
        await gate.finish(fails: false)
        await load.value
        #expect(engine.activeSubtitleTrackID == nil)
        #expect(engine.subtitleCues.isEmpty)
    }
}
