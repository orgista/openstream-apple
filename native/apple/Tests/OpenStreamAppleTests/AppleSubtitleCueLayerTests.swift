import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// The OpenStream engine hands the stock player's captions to the app, and
/// nothing drew them: every MKV/TS subtitle and every live-TS caption played
/// blank on a device (Q4a8 paths 1 and 2).
@Suite("Subtitle cue layer")
@MainActor
struct AppleSubtitleCueLayerTests {
    // MARK: - Route → mounted

    @Test("Mounted over the stock player for either engine", arguments: [
        (ApplePlaybackEngineKind.openStream, ApplePlaybackPresentationRoute.avPlayer, true),
        (.openStream, .surface, false),
        (.openStream, .none, false),
        (.openStream, .audioOnly, false),
        (.native, .avPlayer, true),
        (.native, .surface, false),
    ])
    func mountDecision(engine: ApplePlaybackEngineKind, route: ApplePlaybackPresentationRoute, mounted: Bool) {
        #expect(AppleSubtitleCueLayerPolicy.mountsOverStockPlayer(engine: engine, route: route) == mounted)
    }

    @Test("Inline Live draws cues on AVPlayer and surface routes", arguments: [
        ApplePlaybackEngineKind.openStream, .native,
    ])
    func inlineLiveMountDecision(engine kind: ApplePlaybackEngineKind) {
        let engine = FakePlaybackEngine()
        engine.kind = kind
        let subtitles = AppleStockPlayerSubtitles()
        for route in [ApplePlaybackPresentationRoute.avPlayer, .surface, .none, .audioOnly] {
            engine.scriptedRoute = route
            subtitles.refresh(from: engine)
            #expect(subtitles.drawsInlineCues == (route == .avPlayer || route == .surface))
        }
    }

    /// Owner 2026-09-28: the preferred language is the only entry beside Off.
    @Test func inlineMenuOffersOffAndOnlyThePreferredLanguage() {
        let tracks = [
            ApplePlaybackTrack(id: 1, title: "English", language: "en"),
            ApplePlaybackTrack(id: 2, title: "French", language: "fr"),
        ]
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: tracks, preferredLanguages: ["fr"], languagesAreExplicit: true, activeTrackID: 2)
        #expect(entries.map(\.trackID) == [nil, 2])
        #expect(entries.map(\.isSelected) == [false, true])
    }

    // MARK: - Cue clock

    @Test("Cues follow the frame on screen when the scrub clock is held")
    func cuesFollowPresentationTimeNotScrubPosition() {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .avPlayer
        engine.position = 100
        engine.scriptedPresentationTime = 104
        engine.subtitleCues = [
            AppleSubtitleCue(id: 1, startTime: 99, endTime: 101, body: .text("HELD SCRUB CLOCK")),
            AppleSubtitleCue(id: 2, startTime: 103, endTime: 105, body: .text("ON SCREEN NOW")),
        ]
        let subtitles = AppleStockPlayerSubtitles()
        subtitles.refresh(from: engine)
        #expect(subtitles.cues.map(\.id) == [2])
    }

    @Test("Engines with one clock pace cues from position")
    func presentationTimeDefaultsToPosition() {
        let engine = ChapterFakeEngine()
        engine.position = 42
        #expect(engine.presentationTime == 42)
    }

    // MARK: - Cue → content

    @Test func textCuesDrawTheirText() {
        let cue = AppleSubtitleCue(id: 1, startTime: 1, endTime: 3, body: .text("CC ONE AT 1S"))
        #expect(AppleSubtitleCueContent(cue) == .text("CC ONE AT 1S"))
    }

    @Test func richTextRunsKeepTheirEmphasis() {
        let cue = AppleSubtitleCue(id: 1, startTime: 1, endTime: 3, body: .richText([
            AppleSubtitleTextRun(text: "Hello, ", isItalic: true),
            AppleSubtitleTextRun(text: "world", isBold: true),
        ]))
        #expect(AppleSubtitleCueContent(cue) == .richText([
            AppleSubtitleTextRun(text: "Hello, ", isItalic: true),
            AppleSubtitleTextRun(text: "world", isBold: true),
        ]))
    }

    @Test func bitmapCuesDrawTheSameImageWithItsGeometry() throws {
        let image = try #require(Self.pixel())
        let bitmap = AppleSubtitleBitmap(image: image, rect: CGRect(x: 0.3, y: 0.884, width: 0.402, height: 0.056),
                                         canvasSize: CGSize(width: 1920, height: 1080), isForced: true)
        let cue = AppleSubtitleCue(id: 1, startTime: 1, endTime: 3, body: .image(bitmap))
        #expect(AppleSubtitleCueContent(cue) == .image(bitmap))
        #expect(cue.isForced)
        let other = AppleSubtitleBitmap(image: try #require(Self.pixel()), rect: bitmap.rect,
                                        canvasSize: bitmap.canvasSize, isForced: true)
        #expect(AppleSubtitleCueContent(cue) != .image(other))
        let moved = AppleSubtitleBitmap(image: image, rect: .zero, canvasSize: bitmap.canvasSize, isForced: true)
        #expect(AppleSubtitleCueContent(cue) != .image(moved))
    }

    // MARK: - Active cue

    @Test func theCueOverlappingThePositionIsActiveAndItsEndIsExclusive() {
        let cues = [
            AppleSubtitleCue(id: 1, startTime: 1, endTime: 3, body: .text("one")),
            AppleSubtitleCue(id: 2, startTime: 4, endTime: 6, body: .text("two")),
        ]
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 0.5).isEmpty)
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 1).map(\.id) == [1])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 3).isEmpty)
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 5.9).map(\.id) == [2])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: [], at: 2).isEmpty)
    }

    /// A PGS composition is one cue per object; `.first` used to drop the
    /// sign or the dialogue depending on array order (Q4a8 §4).
    @Test func everyOverlappingCueIsActiveSoASignAndDialogueShowTogether() throws {
        let image = try #require(Self.pixel())
        let canvas = CGSize(width: 1920, height: 1080)
        let sign = AppleSubtitleCue(id: 0, startTime: 0.5, endTime: 58, body: .image(AppleSubtitleBitmap(
            image: image, rect: CGRect(x: 0.321, y: 0.078, width: 0.359, height: 0.05), canvasSize: canvas, isForced: true)))
        let dialogue = AppleSubtitleCue(id: 1, startTime: 2, endTime: 5, body: .image(AppleSubtitleBitmap(
            image: image, rect: CGRect(x: 0.3, y: 0.884, width: 0.402, height: 0.056), canvasSize: canvas)))
        let later = AppleSubtitleCue(id: 2, startTime: 6, endTime: 8, body: .text("later"))
        let cues = [dialogue, sign, later]
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 1).map(\.id) == [0])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 3).map(\.id) == [1, 0])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 7).map(\.id) == [0, 2])
    }

    // MARK: - Menu

    @Test func theMenuIsOffThenTheVisibleTracksWithTheActiveOneTicked() {
        let tracks = [ApplePlaybackTrack(id: 2, title: "ENG (srt)", language: "eng", codec: "subrip", isDefault: true)]
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: tracks, preferredLanguages: [], languagesAreExplicit: false, activeTrackID: 2)
        #expect(entries.map(\.trackID) == [nil, 2])
        #expect(entries.map(\.isSelected) == [false, true])
    }

    @Test func noTracksMeansNoMenu() {
        #expect(AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: [], preferredLanguages: [], languagesAreExplicit: false, activeTrackID: nil).isEmpty)
    }

    // MARK: - Feed

    @Test func theFeedShowsTheCueAtThePositionAndSelectsThroughTheEngine() {
        let engine = FakePlaybackEngine()
        engine.subtitleCues = [AppleSubtitleCue(id: 7, startTime: 36005, endTime: 36008, body: .text("CC ONE"))]
        engine.position = 36006
        let subtitles = AppleStockPlayerSubtitles()
        subtitles.refresh(from: engine)
        #expect(subtitles.cues.map(\.id) == [7])

        // "Off": the engine drops its cues and the layer empties at once,
        // without waiting for a position tick that a paused player never sends.
        engine.subtitleCues = []
        subtitles.select(nil, on: engine)
        #expect(engine.selectedSubtitle == [nil])
        #expect(subtitles.cues.isEmpty)
    }

    private static func pixel() -> CGImage? {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }
}
