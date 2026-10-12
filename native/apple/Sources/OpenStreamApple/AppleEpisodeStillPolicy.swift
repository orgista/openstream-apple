import Foundation

/// Which picture an episode card on the title page's rail shows. An episode
/// the add-on sent no still for used to be a grey box with a play glyph, and a
/// daily show can have a whole season of them; the Apple TV app shows the
/// show's own backdrop there instead — also when the still is named but
/// fails to load, which is how most of those episodes arrive from Cinemeta.
enum AppleEpisodeStillPolicy {
    static func url(still: URL?, stillFailed: Bool = false, seriesBackdrop: URL?) -> URL? {
        guard let still, !stillFailed else { return seriesBackdrop }
        return still
    }
}
