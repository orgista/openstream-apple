import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import OpenStreamApple

/// A live HLS origin the harness points these at. No URL lives in the repo:
/// set `OPENSTREAM_LIVE_LAB_HLS` to a sliding-window `LIVE` playlist (see
/// HANDOFF-NEXT-SESSION.md for the local ffmpeg recipe) and the suite runs;
/// leave it unset and it skips, which is what every ordinary gate run does.
private let labStreamURL: URL? = ProcessInfo.processInfo
    .environment["OPENSTREAM_LIVE_LAB_HLS"].flatMap(URL.init(string:))

/// Where to drop the before/after frame grabs. Optional.
/// A second origin serving a three-segment `LIVE` playlist — no rewind.
private let edgeOnlyStreamURL: URL? = ProcessInfo.processInfo
    .environment["OPENSTREAM_LIVE_LAB_HLS_EDGE"].flatMap(URL.init(string:))

private let labArtifacts: URL? = ProcessInfo.processInfo
    .environment["OPENSTREAM_LIVE_LAB_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }

/// The transport's live seek math, against a real `AVPlayer` playing a real
/// sliding-window live playlist — the one thing the pure tests cannot show.
///
/// Live HLS timelines do not start at zero: their origin is the media sequence
/// (or the programme date-time) the producer is serving. That is what broke
/// skip-back. `AppleTransportOverlayModel.skip(by:)` clamped the target to
/// `ApplePlaybackRequest.effectiveDVRWindowSeconds` — a flat 1800 for every
/// live request — so on a stream whose playhead sits past 1800 s the ten-second
/// step back resolved to "1800", a time outside the seekable range entirely.
/// `AVPlayer` does not error on that: it lands on the nearest seekable time and
/// reports `completed == true`.
@MainActor
@Suite(.serialized) struct AppleLiveSeekIntegrationTests {

    @Test(.enabled(if: labStreamURL != nil), .timeLimit(.minutes(2)))
    func theRealSeekableRangeIsReadFromThePlayerAndASkipLandsInsideIt() async throws {
        let url = try #require(labStreamURL)
        let engine = NativePlaybackEngine()
        defer { engine.stop() }
        try await engine.load(ApplePlaybackRequest(
            url: url, isLive: true, mediaID: "live-seek-lab", title: "Live Seek Lab",
            sourceKind: .liveTV))
        engine.play()

        let range = try #require(
            await settledSeekableRange(engine),
            "the lab stream published no usable seekable range in 45 s")
        let before = engine.position
        report("""
            WIDE WINDOW — seekable range from AVPlayerItem.seekableTimeRanges: \
            \(fmt(range.start))–\(fmt(range.end))s (span \(fmt(range.span))s), playhead \(fmt(before))s
            """)
        // The number the shipped code clamped against, for the record: the
        // request's window is the same 1800 for every live channel and has no
        // relationship to the span above.
        report("request.effectiveDVRWindowSeconds would have been 1800s — \(fmt(1800 / range.span))× the real window")
        try await capture(engine, named: "before-skip-back")

        let target = try #require(
            AppleLiveSeekPolicy.skipTarget(from: before, by: -10, in: range),
            "the fixed math refused a skip on a stream with a real window")
        #expect(range.contains(target))
        await engine.seek(to: target)
        let landed = engine.position
        report("skip-back 10s: target \(fmt(target))s → landed \(fmt(landed))s (from \(fmt(before))s)")
        try await capture(engine, named: "after-skip-back")
        #expect(abs((before - landed) - 10) <= 2,
                "skip-back moved \(fmt(before - landed))s, not ten")
    }

    /// The other half of the report: a live playlist that lists three segments
    /// has no rewind at all. The shipped code still drew skip buttons (the
    /// request's 1800 s window is always positive) and still issued the seek;
    /// `AVPlayer` clamped it to the live edge and reported success, so the
    /// press did nothing and said nothing. The fix reads the real span, finds
    /// it too narrow to matter, and refuses the press — and the overlay draws
    /// no skip buttons to press.
    @Test(.enabled(if: edgeOnlyStreamURL != nil), .timeLimit(.minutes(2)))
    func aLiveStreamWithNoRewindRefusesTheSkipInsteadOfSwallowingIt() async throws {
        let url = try #require(edgeOnlyStreamURL)
        let engine = NativePlaybackEngine()
        defer { engine.stop() }
        try await engine.load(ApplePlaybackRequest(
            url: url, isLive: true, mediaID: "live-seek-lab-edge", title: "Live Seek Lab Edge",
            sourceKind: .liveTV))
        engine.play()
        try await settle(seconds: 8)

        let range = try #require(engine.seekableRange, "no seekable range published at all")
        let before = engine.position
        report("EDGE ONLY — seekable \(fmt(range.start))–\(fmt(range.end))s (span \(fmt(range.span))s), playhead \(fmt(before))s")
        #expect(!AppleLiveSeekPolicy.offersDVR(range), "this origin is serving a wider window than intended")
        #expect(AppleLiveSeekPolicy.skipTarget(from: before, by: -10, in: range) == nil)

        // What the shipped code did with the same press.
        let shippedTarget = min(1800, max(0, before - 10))
        await engine.seek(to: shippedTarget)
        let landed = engine.position
        report("old math on an edge-only stream: target \(fmt(shippedTarget))s → landed \(fmt(landed))s (asked for \(fmt(before - 10))s)")
        #expect(abs(landed - (before - 10)) > 2,
                "the old clamp actually produced a ten-second step here; nothing to show")
    }

    // MARK: - Harness

    /// Waits for the player to publish a seekable span wide enough to rewind in.
    private func settledSeekableRange(_ engine: NativePlaybackEngine) async -> AppleSeekableRange? {
        for _ in 0..<90 {
            try? await Task.sleep(for: .milliseconds(500))
            guard engine.position > 0, let range = engine.seekableRange,
                  AppleLiveSeekPolicy.offersDVR(range) else { continue }
            return range
        }
        return nil
    }

    private func settle(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// One frame of what is actually on screen, so the artifacts show the
    /// stream's own burnt-in clock jumping back rather than a number in a log.
    private func capture(_ engine: NativePlaybackEngine, named name: String) async throws {
        guard let directory = labArtifacts,
              let item = engine.avPlayer?.currentItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        defer { item.remove(output) }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            let context = CIContext()
            guard let png = context.pngRepresentation(
                of: image, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            report("frame → \(name).png at \(fmt(engine.position))s")
            return
        }
    }

    private func fmt(_ seconds: Double) -> String { String(format: "%.2f", seconds) }

    /// Printed so the run's own log is the evidence; also appended to the
    /// artifact directory when one is configured.
    private func report(_ line: String) {
        print("[live-seek-lab] \(line)")
        guard let directory = labArtifacts else { return }
        let log = directory.appendingPathComponent("live-seek-lab.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
