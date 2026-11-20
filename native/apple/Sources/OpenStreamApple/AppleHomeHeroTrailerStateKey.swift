import SwiftUI

/// What the hero's inline trailer is doing, so the iPhone hero's cycle can
/// hold the page while it plays with the sound on
/// (`AppleHeroRotation.cycleIsPaused`).
struct AppleHomeHeroTrailerStateKey: PreferenceKey {
    struct Value: Equatable {
        var isPlaying = false
        /// The video has crossfaded in over the art (it plays behind the
        /// still for a few seconds first). What the scrims follow, so their
        /// change runs with the crossfade and never while the art is up.
        var isOnScreen = false
        var isMuted = true
        /// Started by the Play Trailer button rather than autoplay.
        var isRequested = false
        /// New each time a trailer plays to its end, so the hero can move on
        /// a moment later (`AppleHeroRotation.Cycle.videoEnded`).
        var lastEnd: UUID?
        /// New each time a trailer fails or misses its startup timeout, so the
        /// hero gives the still a fresh dwell (`AppleHeroRotation.Cycle.videoFailed`).
        var lastFailure: UUID?

        /// What the cycle should do with `self` arriving after `previous`.
        func cycleEvent(after previous: Self) -> AppleHeroRotation.VideoEvent? {
            if lastEnd != nil, lastEnd != previous.lastEnd { return .ended }
            if lastFailure != nil, lastFailure != previous.lastFailure { return .failed }
            return nil
        }
    }

    static let defaultValue = Value()

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        if next.isPlaying || (!value.isPlaying && (next.lastEnd != nil || next.lastFailure != nil)) { value = next }
    }
}
