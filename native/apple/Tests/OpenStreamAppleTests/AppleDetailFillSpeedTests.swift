import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// The title page fill (speed item D2): the per-opening timeline and which
/// titles a focused poster may warm.
@Suite("Detail fill timeline")
@MainActor
struct AppleDetailFillTimelineTests {
    /// A clock the test moves by hand.
    private final class ManualClock {
        let base = ContinuousClock.now
        var offset: Duration = .zero
        var now: ContinuousClock.Instant { base.advanced(by: offset) }
    }

    @Test func milestonesAreMeasuredFromTheOpeningAndRecordedOnce() {
        let clock = ManualClock()
        let timeline = AppleDetailFillTimeline(now: { clock.now })
        timeline.begin(title: "Breaking Bad")
        #expect(timeline.mark(.paint) == "detail fill \"Breaking Bad\" paint +0ms")
        clock.offset = .milliseconds(664)
        #expect(timeline.mark(.episodes, detail: "80") == "detail fill \"Breaking Bad\" episodes +664ms 80")
        clock.offset = .milliseconds(900)
        #expect(timeline.mark(.episodes) == nil)
    }

    @Test func navigationTapPrecedesThePageTask() {
        let clock = ManualClock()
        AppleDetailFillTimeline.navigationTap(title: "Fixture", at: clock.now)
        clock.offset = .milliseconds(120)
        let timeline = AppleDetailFillTimeline(now: { clock.now })
        timeline.begin(title: "Fixture")
        #expect(timeline.mark(.paint) == "detail fill \"Fixture\" paint +120ms")
    }

    @Test func nothingIsRecordedBeforeTheFirstOpening() {
        let timeline = AppleDetailFillTimeline()
        #expect(timeline.mark(.overview) == nil)
        #expect(timeline.recordArtworkDecoded() == nil)
    }

    @Test func artworkDecodeIsRecordedOncePerOpening() {
        let clock = ManualClock()
        let timeline = AppleDetailFillTimeline(now: { clock.now })
        timeline.begin(title: "Fixture")
        clock.offset = .milliseconds(15)
        #expect(timeline.recordArtworkDecoded() == "detail fill \"Fixture\" artworkDecoded +15ms")
        clock.offset = .milliseconds(40)
        #expect(timeline.recordArtworkDecoded() == nil)
    }

    @Test func aNewOpeningStartsAFreshTimeline() {
        let clock = ManualClock()
        let timeline = AppleDetailFillTimeline(now: { clock.now })
        timeline.begin(title: "One")
        timeline.mark(.metadata)
        clock.offset = .seconds(30)
        timeline.begin(title: "Two")
        clock.offset = .seconds(30) + .milliseconds(250)
        #expect(timeline.mark(.metadata) == "detail fill \"Two\" metadata +250ms")
    }

    @Test func subMillisecondTimesRoundToTheNearestMillisecond() {
        #expect(AppleDetailFillTimeline.line(title: "T", milestone: .done, elapsed: .microseconds(1_600))
            == "detail fill \"T\" done +2ms")
    }
}

@Suite("Downloaded episode lookup")
struct AppleDownloadedEpisodeLookupTests {
    /// One manifest read answers for every episode: only ids with a record
    /// whose file is still on disk count as downloaded.
    @Test func onlyRecordsWithAFileOnDiskCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "fill-lookup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let present = library.appending(path: "present.mp4")
        try Data([0]).write(to: present)
        let manifest = [
            "tt1:1:1": AppleOfflineRecord(mediaID: "tt1:1:1", localURL: present, sourceExtension: "mp4"),
            "tt1:1:2": AppleOfflineRecord(
                mediaID: "tt1:1:2", localURL: library.appending(path: "gone.mp4"), sourceExtension: "mp4"),
        ]
        try JSONEncoder().encode(manifest).write(to: library.appending(path: "manifest.json"))
        let store = AppleOfflineMediaStore(rootDirectory: library, allowedDirectories: [root])

        let downloaded = await store.downloadedMediaIDs(among: ["tt1:1:1", "tt1:1:2", "tt1:1:3"])

        #expect(downloaded == ["tt1:1:1"])
    }
}
