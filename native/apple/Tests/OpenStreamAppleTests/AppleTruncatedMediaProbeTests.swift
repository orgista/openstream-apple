import Foundation
import Testing
@testable import OpenStreamApple

/// Full test 2026-10-01: a file cut short read "a format OpenStream cannot
/// play" with no Retry.
@Suite("Truncated media probe")
struct AppleTruncatedMediaProbeTests {
    private func box(_ type: String, size: UInt32, payload: Int = 0) -> [UInt8] {
        withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + [UInt8](repeating: 0, count: payload)
    }

    /// ftyp, then an mdat that says it is 2 MB long.
    private var mp4Head: Data {
        Data(box("ftyp", size: 32, payload: 24) + box("free", size: 8) + box("mdat", size: 2_000_000, payload: 64))
    }

    @Test func anMP4WhoseMdatRunsPastTheEndIsCutShort() {
        #expect(AppleTruncatedMediaProbe.endsEarly(head: mp4Head, totalLength: 400_000))
    }

    @Test func theWholeFileIsNotCutShort() {
        #expect(!AppleTruncatedMediaProbe.endsEarly(head: mp4Head, totalLength: 2_000_040))
    }

    @Test func somethingThatIsNotAContainerIsLeftAlone() {
        #expect(!AppleTruncatedMediaProbe.endsEarly(head: Data("#EXTM3U\n#EXTINF:-1,\n".utf8), totalLength: 10))
    }

    @Test func aMatroskaSegmentPastTheEndIsCutShort() {
        // EBML header (size 4, payload 4 bytes), Segment with a 4-byte size of 1,000,000.
        let head: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0, 0, 0, 0,
                             0x18, 0x53, 0x80, 0x67, 0x10, 0x0F, 0x42, 0x40] + [UInt8](repeating: 0, count: 32)
        #expect(AppleTruncatedMediaProbe.endsEarly(head: Data(head), totalLength: 400_000))
        #expect(!AppleTruncatedMediaProbe.endsEarly(head: Data(head), totalLength: 1_000_017))
    }

    @Test func anUnknownSizeSegmentIsLeftAlone() {
        let head: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0, 0, 0, 0,
                             0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(!AppleTruncatedMediaProbe.endsEarly(head: Data(head), totalLength: 400_000))
    }

    @Test func aTruncatedLocalFileIsFound() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("truncated-\(UUID()).mp4")
        try mp4Head.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await AppleTruncatedMediaProbe.endsEarly(url))
    }

    // MARK: V13 — an open failure is not a truncation

    @Test func aDemuxerRefusingACompleteFileIsNotCalledTruncated() {
        let raw = "HLSVideoEngine: open failed (Demuxer: open failed (Invalid data found when processing input (-1094995529)))"
        #expect(AppleTruncatedMediaProbe.readableEngineMessage(raw, midStream: false)
                == AppleTruncatedMediaProbe.openFailedMessage)
        #expect(!AppleTruncatedMediaProbe.openFailedMessage.contains("ended early"))
    }

    @Test func endOfInputOrAStartedStreamIsADrop() {
        #expect(AppleTruncatedMediaProbe.readableEngineMessage("Demuxer: read failed (End of file)", midStream: false)
                == AppleTruncatedMediaProbe.droppedMessage)
        #expect(AppleTruncatedMediaProbe.readableEngineMessage("avformat: Input/output error", midStream: false)
                == AppleTruncatedMediaProbe.droppedMessage)
        #expect(AppleTruncatedMediaProbe.readableEngineMessage("Demuxer: Invalid data found when processing input",
                                                               midStream: true) == AppleTruncatedMediaProbe.droppedMessage)
    }

    @MainActor @Test(arguments: [false, true])
    func theCoordinatorAsksTheContainerBeforeSayingTruncated(cutShort: Bool) async throws {
        // A complete MP4 head (mdat fits) vs one whose mdat runs past the end.
        let url = FileManager.default.temporaryDirectory.appending(path: "v13-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let mdatSize: UInt32 = cutShort ? 2_000_000 : 72
        try Data(box("ftyp", size: 32, payload: 24) + box("mdat", size: mdatSize, payload: 64)).write(to: url)
        let engine = FakePlaybackEngine()
        engine.failOnLoad = ApplePlaybackFailure(kind: .player, message: AppleTruncatedMediaProbe.openFailedMessage)
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(ApplePlaybackRequest(url: url, mediaID: "v13", sourceKind: .files))
        for _ in 0..<50 {
            if case .failed = coordinator.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed(let failure) = coordinator.phase else {
            Issue.record("expected a failure, got \(coordinator.phase)")
            return
        }
        #expect(failure.message == (cutShort ? AppleTruncatedMediaProbe.message : AppleTruncatedMediaProbe.openFailedMessage))
        coordinator.stop()
    }
}
