import Foundation

/// Which subtitle tracks the captions menu lists.
///
/// A remux routinely carries fifteen or twenty subtitle tracks. The menu
/// listed every one of them even when the viewer had chosen a single language
/// in Settings — the preference was only ever handed to the engine for
/// auto-selection at load, never used to shorten the list (owner 2026-09-14:
/// "subtitles have too many tracks since I only selected one language").
///
/// Matching is on the language code, in the viewer's order of preference, and
/// tolerant about the form it takes: MKVs carry `eng`, `en`, `en-US` and
/// occasionally `English` for the same thing.
public enum AppleSubtitleTrackFilter: Sendable {
    /// The tracks to offer.
    ///
    /// `isExplicitChoice` is the difference between a language the viewer
    /// *picked* and one the app *guessed* from the device:
    ///
    /// - **Picked** (Settings → Playback → Subtitle Languages): that language
    ///   is the whole menu. If the stream carries none, the menu is empty, and
    ///   that is the honest answer — the owner asked for "English can be
    ///   default, only option as well" (2026-09-15), and quietly listing
    ///   fifteen other languages is what made the menu unusable in the first
    ///   place.
    /// - **Guessed** (device defaults, before the viewer has been to that
    ///   screen): fall back to every track when nothing matches, because an
    ///   empty menu is worse than a long one when nobody asked for anything.
    public static func visible(
        _ tracks: [ApplePlaybackTrack],
        preferredLanguages: [String],
        isExplicitChoice: Bool = false
    ) -> [ApplePlaybackTrack] {
        let wanted = preferredLanguages.map(normalized).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return tracks }

        var matched: [ApplePlaybackTrack] = []
        for language in wanted {
            for track in tracks
            where normalized(track.language ?? "") == language && !matched.contains(where: { $0.id == track.id }) {
                matched.append(track)
            }
        }
        if matched.isEmpty { return isExplicitChoice ? [] : tracks }
        return matched
    }

    /// `eng`, `en`, `en-US`, `en_US` and `English` all reduce to `en`.
    static func normalized(_ value: String) -> String {
        let lower = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !lower.isEmpty else { return "" }
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        if base.count == 2 { return base }
        if let alpha2 = Locale.LanguageCode(base).identifier(.alpha2) as String?, alpha2.count == 2 {
            return alpha2.lowercased()
        }
        // A spelled-out name ("English"), matched against the picker's table.
        if let code = AppleSubtitleLanguages.names.first(where: { $0.value.lowercased() == base })?.key,
           let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) as String?, alpha2.count == 2 {
            return alpha2.lowercased()
        }
        return base
    }
}
