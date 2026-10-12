import Foundation

/// The span a stream can actually be seeked within, on the same time axis the
/// engine publishes `position` on.
///
/// This is a FACT read from the player — `AVPlayerItem.seekableTimeRanges` on
/// the AVPlayer route, `AetherEngine.seekableLiveRange` on the demuxing one —
/// not the policy number in `ApplePlaybackRequest.dvrWindowSeconds`. The two
/// are unrelated for live: every live request carries the same 1800 s default
/// while most IPTV playlists are a sliding window of a few segments, so a
/// stream that can rewind 45 seconds was being scrubbed, badged and skipped as
/// if it could rewind thirty minutes.
public struct AppleSeekableRange: Equatable, Sendable {
    public let start: Double
    public let end: Double

    /// Nil for anything non-finite or inverted, which is what a player reports
    /// before its first segment lands.
    public init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        self.start = start
        self.end = end
    }

    public var span: Double { end - start }

    public func contains(_ seconds: Double) -> Bool {
        seconds >= start && seconds <= end
    }

    /// The overlap with `other`, or nil when they do not overlap. Used to fold
    /// what the engine's live window claims together with what the item under
    /// it actually holds; the narrower answer is the true one.
    public func intersected(with other: AppleSeekableRange) -> AppleSeekableRange? {
        AppleSeekableRange(start: Swift.max(start, other.start),
                           end: Swift.min(end, other.end))
    }

    /// The same range widened to hold `seconds`. A playhead is always seekable
    /// to where it already is, so a range sampled a tick behind the playhead
    /// must never exclude it.
    public func expanded(toInclude seconds: Double) -> AppleSeekableRange {
        guard seconds.isFinite else { return self }
        return AppleSeekableRange(start: Swift.min(start, seconds),
                                  end: Swift.max(end, seconds)) ?? self
    }
}

/// Every seek decision for a live stream, as pure functions over a real
/// seekable range. No AVFoundation, no engine, no view — so the arithmetic the
/// transport depends on can be asserted directly.
///
/// The bug this exists to end (owner, GUI audit 2026-09-19): skip-back on a
/// live channel clamped `position + seconds` to a fictional 1800 s window,
/// then handed the result to `AVPlayer.seek`, which never errors on an
/// out-of-range target — it silently lands on the nearest seekable time and
/// reports success. The badge and the scrubber were drawn from the same
/// fiction, so even a seek that did land looked like nothing had happened.
public enum AppleLiveSeekPolicy {
    /// A window narrower than this is not a DVR: there is no room for a single
    /// ten-second step and the tolerance the live edge needs. Streams below it
    /// get no scrubber and no skip buttons rather than buttons that do nothing.
    public static let minimumUsefulSpan: Double = 20

    /// A seek that would move the playhead less than this is not worth issuing:
    /// the playhead is already against the bound, and the round trip through
    /// the player would only stall the picture.
    public static let minimumEffectiveMove: Double = 0.5

    /// `true` when the stream offers enough rewind to be worth a scrubber and
    /// skip buttons.
    public static func offersDVR(_ range: AppleSeekableRange?) -> Bool {
        guard let range else { return false }
        return range.span >= minimumUsefulSpan
    }

    /// Where a `±seconds` skip should land, or nil when it cannot move.
    ///
    /// `position` is clamped into the range first: on a live stream the
    /// playhead can legitimately sit a moment past the sampled edge, and
    /// `edge + seconds` from there would ask for a time the stream does not
    /// have yet.
    public static func skipTarget(
        from position: Double,
        by seconds: Double,
        in range: AppleSeekableRange?
    ) -> Double? {
        guard let range, offersDVR(range), position.isFinite, seconds.isFinite else { return nil }
        let anchored = min(range.end, max(range.start, position))
        let target = min(range.end, max(range.start, anchored + seconds))
        guard abs(target - position) >= minimumEffectiveMove else { return nil }
        return target
    }

    /// Where a scrub to `fraction` of the window lands. Nil when there is no
    /// window to scrub.
    public static func scrubTarget(
        fraction: Double,
        in range: AppleSeekableRange?
    ) -> Double? {
        guard let range, offersDVR(range), fraction.isFinite else { return nil }
        let clamped = min(1, max(0, fraction))
        return range.start + clamped * range.span
    }

    /// `0...1` for the playhead inside the window. `0` when there is no window.
    public static func progress(position: Double, in range: AppleSeekableRange?) -> Double {
        guard let range, range.span > 0, position.isFinite else { return 0 }
        return min(1, max(0, (position - range.start) / range.span))
    }

    /// `true` while the playhead is within `tolerance` of the window's edge —
    /// and always true when there is no window, because there is nowhere else
    /// to be. This is what paints the LIVE badge red.
    public static func isAtLiveEdge(
        position: Double,
        in range: AppleSeekableRange?,
        tolerance: Double
    ) -> Bool {
        guard let range, offersDVR(range), position.isFinite else { return true }
        return position >= range.end - tolerance
    }
}
