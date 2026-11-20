import AVFoundation
import Testing
import AetherEngine
@testable import OpenStreamApple

@Suite struct AppleEngineChaptersTests {
    @Test func engineChaptersMapToMarkersAndTheOpeningIsFound() {
        let infos = [
            ChapterInfo(id: 1, name: "Opening", startSeconds: 0, durationSeconds: 70),
            ChapterInfo(id: 2, name: "Chapter 2", startSeconds: 70, durationSeconds: 1300),
        ]
        let mapped = infos.map(AetherPlaybackEngine.mapChapter)
        #expect(mapped == [AppleChapter(title: "Opening", start: 0, end: 70),
                           AppleChapter(title: "Chapter 2", start: 70, end: 1370)])
        #expect(AppleChapterMarkers.intro(in: mapped, duration: 1370)?.title == "Opening")
    }

    @Test func aNegativeDurationDoesNotProduceAnInvertedChapter() {
        let mapped = AetherPlaybackEngine.mapChapter(ChapterInfo(id: 9, name: "Intro", startSeconds: 12, durationSeconds: -5))
        #expect(mapped.end == 12)
    }
}

/// The overlay's side of the chapter work: which engine events re-derive the
/// opening, and how long "the viewer already skipped it" lasts.
///
/// The runtime and the chapter list reach `AetherPlaybackEngine` through two
/// independent Combine publishers (`$duration`, `$mediaChapters`), so neither
/// order is guaranteed, and the same overlay model outlives a load whenever the
/// viewer switches source or channel without leaving the player.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppleOverlayChapterEventTests {
    private func makeModel(_ engine: ChapterFakeEngine) -> (ApplePlaybackCoordinator, AppleTransportOverlayModel) {
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        return (coordinator, AppleTransportOverlayModel(coordinator: coordinator, isLive: false))
    }

    @Test func chapterSeekRevalidatesTheCurrentRuntimeAndVersion() async {
        let engine = ChapterFakeEngine()
        engine.duration = 1000
        let version = UUID()
        engine.chapterMediaVersion = version
        let marker = AppleChapter(title: "Opening", start: 10, end: 70,
                                  provenance: .init(source: .embeddedContainer, mediaVersion: version))
        engine.chapters = [marker]
        let (coordinator, model) = makeModel(engine)
        engine.duration = 40 // No duration event has reached the overlay yet.
        await model.skipIntro()
        await model.jump(to: marker)
        #expect(engine.seeks.isEmpty)
        engine.duration = 1000
        engine.chapterMediaVersion = UUID()
        await model.skipIntro()
        await model.jump(to: marker)
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    @Test func unknownRuntimeNeverSeeksToAnUnboundedIntro() async {
        let engine = ChapterFakeEngine()
        engine.chapters = [AppleChapter(title: "Intro", start: 0, end: 60)]
        let (coordinator, model) = makeModel(engine)
        await model.skipIntro()
        await model.jump(to: engine.chapters[0])
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    // MARK: - Event ordering

    @Test func aRuntimeArrivingAfterTheChaptersRetractsAnOverlongOpening() async {
        let engine = ChapterFakeEngine()
        // 280 s passes the absolute length test, so with no runtime to measure
        // it against `AppleChapterMarkers` has to let it stand.
        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 280)]
        let (coordinator, model) = makeModel(engine)
        #expect(model.introChapter?.title == "Opening")

        engine.duration = 600
        engine.emit(.duration(600))
        await waitUntil { model.duration == 600 }
        // 280 s is 47% of a ten-minute programme: a mislabelled single-chapter
        // file, not an opening. The share-of-runtime rule can only run now, so
        // `.duration` has to re-derive the marker.
        #expect(model.introChapter == nil)
        coordinator.stop()
    }

    @Test func aRuntimeArrivingAfterTheChaptersKeepsAnOpeningThatFits() async {
        let engine = ChapterFakeEngine()
        engine.chapters = [AppleChapter(title: "Opening Credits", start: 0, end: 70)]
        let (coordinator, model) = makeModel(engine)
        engine.duration = 1370
        engine.emit(.duration(1370))
        await waitUntil { model.duration == 1370 }
        #expect(model.introChapter?.title == "Opening Credits")
        coordinator.stop()
    }

    @Test func chaptersArrivingAfterTheRuntimeAreJudgedAgainstIt() async {
        let engine = ChapterFakeEngine()
        engine.duration = 600
        let (coordinator, model) = makeModel(engine)
        #expect(model.introChapter == nil)

        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 280)]
        engine.emit(.tracks)
        engine.audioTracks = [ApplePlaybackTrack(id: 0, title: "English", language: "eng")]
        engine.emit(.tracks)
        await waitUntil { model.audioTracks.count == 1 }
        #expect(model.introChapter == nil)

        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 70)]
        engine.emit(.tracks)
        await waitUntil { model.introChapter != nil }
        #expect(model.introChapter == AppleChapter(title: "Opening", start: 0, end: 70))
        coordinator.stop()
    }

    // MARK: - The skip is sticky within the item

    @Test func skippingStaysStickyAcrossLaterTrackEventsAndSeeksBack() async {
        let engine = ChapterFakeEngine()
        engine.duration = 1370
        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 70)]
        let (coordinator, model) = makeModel(engine)
        engine.emit(.position(10))
        await waitUntil { model.position == 10 }
        #expect(model.showsSkipIntro)

        await model.skipIntro()
        #expect(engine.seeks == [70])
        #expect(model.hasSkippedIntro)
        #expect(!model.showsSkipIntro)

        // A sidecar subtitle file lands mid-item and re-emits `.tracks`; the
        // chapter list is unchanged, so nothing about the skip may change.
        engine.subtitleTracks = [ApplePlaybackTrack(id: 9, title: "English", language: "eng")]
        engine.emit(.tracks)
        await waitUntil { model.subtitleTracks.count == 1 }
        #expect(model.hasSkippedIntro)

        // Seeking back into the opening must not put the button up again.
        engine.emit(.position(5))
        await waitUntil { model.position == 5 }
        #expect(!model.showsSkipIntro)
        coordinator.stop()
    }

    // MARK: - …and ends with the item

    @Test func aNewLoadClearsTheSkippedOpening() async {
        let engine = ChapterFakeEngine()
        engine.duration = 1370
        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 70)]
        let (coordinator, model) = makeModel(engine)
        engine.emit(.position(10))
        await waitUntil { model.position == 10 }
        await model.skipIntro()
        #expect(model.hasSkippedIntro)

        // Switching source or channel through the same overlay runs the new
        // load through the engine's `stop()`, which reports `.idle`.
        engine.emit(.phase(.idle))
        await waitUntil { !model.hasSkippedIntro }
        // The old item's marker goes with it.
        #expect(model.introChapter == nil)

        // Different episodes can have identical chapter markers. The load
        // boundary, rather than chapter equality, must reset the skip.
        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 70)]
        engine.emit(.tracks)
        await waitUntil { model.introChapter?.title == "Opening" }
        // Position 10 is inside the new item's opening: the button is offered
        // again, because this is a different stream.
        #expect(model.showsSkipIntro)
        coordinator.stop()
    }

    @Test func updatedChapterMetadataDoesNotUndoTheSkipWithinTheItem() async {
        // Chapter metadata can change without the playback item changing.
        // Only the engine's item boundary should clear the sticky skip.
        let engine = ChapterFakeEngine()
        engine.duration = 1370
        engine.chapters = [AppleChapter(title: "Opening", start: 0, end: 70)]
        let (coordinator, model) = makeModel(engine)
        engine.emit(.position(10))
        await waitUntil { model.position == 10 }
        await model.skipIntro()
        #expect(model.hasSkippedIntro)

        engine.chapters = [AppleChapter(title: "Theme", start: 0, end: 40)]
        engine.emit(.tracks)
        await waitUntil { model.introChapter?.title == "Theme" }
        #expect(model.hasSkippedIntro, "A metadata update must retain the skip: \(model.hasSkippedIntro)")
        #expect(!model.showsSkipIntro, "Updated markers must not re-offer a skipped intro")
        coordinator.stop()
    }
}

/// `FakePlaybackEngine` takes the protocol's default `chapters` (`[]`) and
/// cannot report markers, so the chapter tests use their own stand-in of the
/// same shape: scripted state, plus `emit` to drive the model's event stream.
@MainActor
final class ChapterFakeEngine: ApplePlaybackEngine {
    var kind: ApplePlaybackEngineKind = .openStream
    var phase: ApplePlaybackEnginePhase = .idle
    var route: ApplePlaybackPresentationRoute = .surface
    var position: Double = 0
    var duration: Double? = nil
    var audioTracks: [ApplePlaybackTrack] = []
    var subtitleTracks: [ApplePlaybackTrack] = []
    var subtitleCues: [AppleSubtitleCue] = []
    var chapterMediaVersion: UUID? = nil
    var chapters: [AppleChapter] = []
    var failure: ApplePlaybackFailure? = nil
    var avPlayer: AVPlayer? { nil }
    var seeks: [Double] = []

    private var continuations: [AsyncStream<ApplePlaybackEngineEvent>.Continuation] = []

    var events: AsyncStream<ApplePlaybackEngineEvent> {
        AsyncStream { continuation in
            continuations.append(continuation)
        }
    }

    func emit(_ event: ApplePlaybackEngineEvent) {
        for continuation in continuations { continuation.yield(event) }
    }

    func load(_ request: ApplePlaybackRequest) async throws {}
    func play() { phase = .playing }
    func pause() { phase = .paused }
    func stop() { phase = .idle }
    func seek(to seconds: Double) async { seeks.append(seconds) }
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int?) {}
}

/// Waits for engine events to reach the model through its main-actor
/// `AsyncStream` task. No wall-clock deadline: the parallel gate can hold the
/// main actor for seconds; the suite's time limit fails a change that never lands.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    while !condition(), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
