import Foundation

/// When the shared trailer page (`AppleYouTubePreviewHTML`) may reveal its
/// player once YouTube has said PLAYING — one rule for the iPhone, iPad,
/// Vision Pro and Mac pages; the host's own art-first gate (picture band,
/// geometry settle) still runs after it.
///
/// Reveal depends on advancing frames, not hiding YouTube's attribution.
/// YouTube's title, channel and link remain visible when its player draws them.
/// Vision Pro retains its existing settle delay until visually verified.
struct AppleTrailerRevealRule: Equatable, Sendable {
    /// Never earlier than this after PLAYING.
    var minimumWait: TimeInterval
    /// Media time that must have played since PLAYING: frames are flowing,
    /// not a stalled first buffer.
    var minimumMediaAdvance: TimeInterval
    /// Reveals at this regardless (the old fixed wait).
    var cap: TimeInterval

    func allowsReveal(sincePlaying: TimeInterval, mediaAdvance: TimeInterval) -> Bool {
        if sincePlaying >= cap { return true }
        return sincePlaying >= minimumWait && mediaAdvance >= minimumMediaAdvance
    }
}

enum AppleTrailerRevealPolicy {
    static let landscapeCap: TimeInterval = 3.2
    static let portraitCap: TimeInterval = 0.9
    static let minimumWait: TimeInterval = 0.5
    static let minimumMediaAdvance: TimeInterval = 0.3

    /// Whether YouTube's start-up title strip and link can reach the screen
    /// on this platform's trailer page (see the type's notes).
    static var startupChromeCanShow: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    static func rule(isLandscape: Bool, startupChromeCanShow: Bool) -> AppleTrailerRevealRule {
        let cap = isLandscape ? landscapeCap : portraitCap
        guard !startupChromeCanShow else {
            return AppleTrailerRevealRule(minimumWait: cap, minimumMediaAdvance: 0, cap: cap)
        }
        return AppleTrailerRevealRule(minimumWait: min(minimumWait, cap), minimumMediaAdvance: minimumMediaAdvance, cap: cap)
    }

    /// The same rules for the page's script: `[minimum wait ms, media
    /// advance s, cap ms]` per orientation.
    static func javascriptRules(startupChromeCanShow: Bool) -> String {
        func entry(_ rule: AppleTrailerRevealRule) -> String {
            "[\(Int((rule.minimumWait * 1000).rounded())), \(rule.minimumMediaAdvance), \(Int((rule.cap * 1000).rounded()))]"
        }
        let landscape = rule(isLandscape: true, startupChromeCanShow: startupChromeCanShow)
        let portrait = rule(isLandscape: false, startupChromeCanShow: startupChromeCanShow)
        return "{landscape: \(entry(landscape)), portrait: \(entry(portrait))}"
    }
}
