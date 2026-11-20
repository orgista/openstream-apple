import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// When the shared trailer page may reveal its player after PLAYING.
/// The host's art-first gate (picture band, geometry settle) still runs after it.
///
/// A platform that waits lets the embed's start-up chrome fade on its own,
/// behind the artwork (`startupChromeCanShow`).
struct AppleTrailerRevealRule: Equatable, Sendable {
    /// Never earlier than this after PLAYING.
    var minimumWait: TimeInterval
    /// Media time that must have played since PLAYING: frames are flowing,
    /// not a stalled first buffer.
    var minimumMediaAdvance: TimeInterval

    func allowsReveal(sincePlaying: TimeInterval, mediaAdvance: TimeInterval) -> Bool {
        sincePlaying >= minimumWait && mediaAdvance >= minimumMediaAdvance
    }
}

enum AppleTrailerRevealPolicy {
    static let minimumWait: TimeInterval = 0.5
    static let minimumMediaAdvance: TimeInterval = 0.3
    /// Media time the embed's start-up chrome stays up, plus a margin.
    static let startupChromeMediaTime: TimeInterval = 4.5

    /// Leave room for a slow first buffer before starting the reveal deadline.
    static let playbackStartTimeout: TimeInterval = 30
    static let revealTimeout: TimeInterval = 12
    static let mediaJumpSlack: TimeInterval = 1

    /// OWNER DECISION PENDING (lead, 2026-10-29): whether iPhone waits out
    /// YouTube's start-up chrome (its centre play/pause glyph, title strip
    /// and link) behind the art like every other platform. Waiting puts the
    /// iPhone reveal ~4.5 s after PLAYING instead of 0.3 s; the seamless
    /// pass's iPhone recordings showed the glyph over the trailer for ~3 s
    /// after a fast reveal. `false` brings the fast reveal back.
    static let iPhoneWaitsForStartupChrome = false

    /// Whether the embed's start-up chrome can still be up when the page
    /// would reveal, so it waits `startupChromeMediaTime` behind the art.
    static func startupChromeCanShow(on platform: AppleUIPlatform = .current, isPhone: Bool) -> Bool {
        platform != .iOS || !isPhone || iPhoneWaitsForStartupChrome
    }

    #if canImport(UIKit)
    static func startupChromeCanShow(for idiom: UIUserInterfaceIdiom) -> Bool {
        startupChromeCanShow(isPhone: idiom == .phone)
    }
    #endif

    static func rule(startupChromeCanShow: Bool) -> AppleTrailerRevealRule {
        AppleTrailerRevealRule(minimumWait: minimumWait,
                               minimumMediaAdvance: startupChromeCanShow ? startupChromeMediaTime : minimumMediaAdvance)
    }

    /// The page's rule: `[minimum wait ms, media advance s]`.
    static func javascriptRule(startupChromeCanShow: Bool) -> String {
        let rule = rule(startupChromeCanShow: startupChromeCanShow)
        return "[\(Int((rule.minimumWait * 1000).rounded())), \(rule.minimumMediaAdvance)]"
    }
}
