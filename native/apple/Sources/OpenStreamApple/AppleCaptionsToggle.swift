import Foundation

/// The rules behind the player's CC key — the one-tap on/off for the viewer's
/// preferred-language subtitle track.
///
/// It is deliberately separate from the Audio & Subtitles menu. The menu is for
/// choosing *among* tracks; the key is for turning the one track the viewer
/// already settled on off when a scene is loud and back on when it is quiet,
/// without a menu in the way (owner 2026-09-20).
///
/// Pure so the state machine can be tested without a player: the key's whole
/// behaviour is "which track id does the next tap select, and is one selected
/// now".
public enum AppleCaptionsToggle: Sendable {
    /// The track the key turns on: the single preferred-language track the
    /// subtitles picker was reduced to. `nil` when the stream carries none, and
    /// then the key has nothing to do.
    public static func trackToEnable(visible: [ApplePlaybackTrack]) -> Int? {
        visible.first?.id
    }

    /// Whether the key is drawn at all. A stream with no subtitle track in the
    /// viewer's language gets no key rather than a dead one.
    public static func isAvailable(visible: [ApplePlaybackTrack]) -> Bool {
        trackToEnable(visible: visible) != nil
    }

    /// The key reads as *on* when the selected track is one the key could have
    /// turned on. A track picked from the menu that is not the preferred one —
    /// possible when the viewer has no language preference and the menu lists
    /// the whole file — still counts as on: captions are on screen, so a key
    /// that claimed otherwise would be lying.
    public static func isOn(selected: Int?) -> Bool {
        selected != nil
    }

    /// What the next tap selects. `nil` means "off".
    ///
    /// Turning on always selects the preferred track, even when some other
    /// track was the last one on: the key has one job, and the menu is where a
    /// different track is chosen.
    public static func nextSelection(selected: Int?, visible: [ApplePlaybackTrack]) -> Int? {
        isOn(selected: selected) ? nil : trackToEnable(visible: visible)
    }
}
