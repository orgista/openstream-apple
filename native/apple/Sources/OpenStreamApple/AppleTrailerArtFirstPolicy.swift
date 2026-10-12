import Foundation

/// Trailers are art-first (owner, 2026-09-24): the metadata art always
/// draws first; the trailer is asked for only once that art is up, loads
/// behind it, and fades in only once it is really playing. A trailer that
/// is slow, stalls or fails changes nothing on screen — the art stays. No
/// spinner, no "Loading", no message, anywhere a trailer plays.
public enum AppleTrailerArtFirstPolicy {
    /// How long a pressed trailer that has not started may hold the hero's
    /// page before it quietly gives up and the art stays.
    public static let pressedTrailerGiveUp: Double = 30

    public static let startupTimeout: Double = 15

    static func autoplayRequestID(itemID: String, enabled: Bool, art: Art, keys: [String]) -> String {
        "\(itemID):\(enabled):\(art == .loaded):\(keys.joined(separator: ","))"
    }

    /// The trailer the title page's hero shows. Once one has started it is
    /// held by its key, not by its place in the list: the list is the
    /// enriched details' trailers followed by the add-on's, and it changes
    /// under a playing trailer as the details land (a few to dozens of keys,
    /// prepended) or are cleared for a reload. Held by index, the key at that
    /// place changed and the playing trailer was torn down for another one
    /// mid-play — on screen for a moment, then back to the art.
    static func heroTrailerKey(pinned: String?, gaveUp: Bool, candidates: [String]) -> String? {
        if gaveUp { return nil }
        return pinned ?? candidates.first
    }

    /// Where the search for the next playable trailer starts once `key` has
    /// failed: just after it in the current list, or at the top when the
    /// list no longer carries it.
    static func nextCandidateStart(after key: String?, in candidates: [String]) -> Int {
        guard let key, let index = candidates.firstIndex(of: key) else { return 0 }
        return index + 1
    }

    static func acceptsMessage(messageKey: String?, currentKey: String?) -> Bool {
        guard let messageKey, let currentKey else { return false }
        return messageKey == currentKey
    }

    static func startupHasTimedOut(active: Bool, videoIsOnScreen: Bool, elapsed: Double) -> Bool {
        active && !videoIsOnScreen && elapsed >= startupTimeout
    }

    /// Where a hero's or title page's art stands.
    public enum Art: Equatable, Sendable {
        case loading, loaded, failed

        /// Loaded is for good: a later reload keeps the image it had on
        /// screen, so a failure after it does not take the trailer away.
        public func settling(with outcome: Art) -> Art {
            self == .loaded ? .loaded : outcome
        }
    }

    /// Whether the trailer's request may go out. A preview that plays by
    /// itself waits for the art to have loaded. A pressed Play Trailer waits
    /// only for the art to settle, so a title whose art fails still plays
    /// its trailer when asked instead of leaving the press dead.
    public static func mayRequestTrailer(art: Art, pressed: Bool) -> Bool {
        switch art {
        case .loading: false
        case .loaded: true
        case .failed: pressed
        }
    }

    /// Whether a pressed Trailers card shows it is loading (N69): from the
    /// press until its video is on screen, it fails, or the page lets go.
    /// A trailer that autoplays, or one playing already, marks no card. The
    /// hero itself stays art-first and says nothing.
    public static func pressedCardIsLoading(cardKey: String, pressedKey: String?, videoIsOnScreen: Bool) -> Bool {
        pressedKey == cardKey && !videoIsOnScreen
    }

    /// What a player state message does to the video layer.
    public enum VideoLayerChange: Equatable, Sendable {
        /// Crossfade the art away over the live video.
        case reveal
        /// Crossfade back to the art.
        case returnToArt
    }

    /// Not from the page: the trailer's web view reports it when WebKit's
    /// content process dies under it, so the video layer is dropped and the
    /// art stays — never a blank frame.
    public static let webContentTerminatedState = "web-content-terminated"

    /// The video stays hidden under the art until the page reports
    /// "revealed" — it has played real frames for a moment — and goes back
    /// under the art when it ends, pauses, errors or is blocked, or its web
    /// content process dies. Everything else ("ready", "playing", buffering)
    /// leaves the art up.
    public static func videoLayerChange(forPlayerState state: String) -> VideoLayerChange? {
        switch state {
        case "revealed": .reveal
        case "ended", "paused", "error", "autoplay-blocked", "concealed", webContentTerminatedState: .returnToArt
        default: nil
        }
    }

    /// Whether the state ends this trailer for good: the video layer is
    /// removed and the art stays, with no retry and nothing said.
    public static func dropsVideoLayer(forPlayerState state: String) -> Bool {
        state == "error" || state == "autoplay-blocked" || state == webContentTerminatedState
    }

    /// Whether the page takes the video layer away once the art has
    /// crossfaded back: a trailer that has finished, as well as one that
    /// failed (owner, 2026-09-28: "when trailer is done it doesn't go back to
    /// movie art and it should"). Unlike a failure, a finished trailer can be
    /// started again from the art.
    public static func leavesForTheArt(forPlayerState state: String) -> Bool {
        state == "ended" || dropsVideoLayer(forPlayerState: state)
    }

    /// Whether a hero's Play Trailer press asks for the trailer. Only a
    /// trailer that was itself pressed and is on screen ignores it (a second
    /// press would only cut it back to the art). The muted preview that plays
    /// by itself is not an answer to the press: it restarts with sound (iOS
    /// 18.6 regression 2026-10-01: the press did nothing over the preview).
    public static func heroPressRequestsTrailer(videoIsOnScreen: Bool, pressedTrailerPlaying: Bool) -> Bool {
        !(videoIsOnScreen && pressedTrailerPlaying)
    }

    /// 0.4 s (owner 2026-10-09: a graceful ~0.4 s fade from the art into the
    /// first real frames; it was 0.6 s).
    public static let crossfadeDuration: Double = 0.4

    /// The art ↔ video crossfade; an instant swap with Reduce Motion.
    public static func crossfadeDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : crossfadeDuration
    }
}
