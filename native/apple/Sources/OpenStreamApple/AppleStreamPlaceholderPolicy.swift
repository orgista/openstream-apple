import Foundation

/// Debrid and add-on error clips: a provider that cannot serve a title still
/// answers with a short video saying so ("Debrid failed to split torrent into
/// single videos, only rar is available"). Played as the episode it ran for a
/// few seconds, counted as watched, and auto-advanced through the season
/// (iPad v2 re-run, 2026-10-01). These are demoted in ranking by their words,
/// and treated as a failed source at playback by their length.
public enum AppleStreamPlaceholderPolicy {
    /// Words add-ons put in the name or description of an error clip, and in
    /// the file names of the clips themselves.
    /// Only add-ons send these clips, so the App Store flavour (add-ons
    /// compiled out) ships no list and keeps the runtime check below.
    #if OPENSTREAM_ADDONS
    static let markers: [String] = [
        "failed to split torrent", "only rar is available", "only rar available",
        "download failed", "not cached", "debrid failed", "failed to download",
        "failed_rar", "download_failed", "failed_access", "failed_unexpected",
        "failed_opening", "limits_exceeded", "failed_infringement",
    ]
    #else
    static let markers: [String] = []
    #endif

    /// Whether this text names an error clip rather than the title.
    public static func isPlaceholder(text: String) -> Bool {
        let lower = text.lowercased()
        return markers.contains { lower.contains($0) }
    }

    public static func isPlaceholder(_ candidate: AppleStremioHTTPPlaybackCandidate) -> Bool {
        isPlaceholder(text: [candidate.title, candidate.qualityDescription ?? "", candidate.filename ?? "",
                             candidate.sourceURL.lastPathComponent].joined(separator: " "))
    }

    /// Below this a runtime is not trusted to judge a clip by (a short).
    static let minimumKnownRuntime: Double = 10 * 60

    /// Whether a stream this long is a clip and not the title it was asked
    /// for: under a tenth of the known runtime (and never under a minute) of
    /// a title that runs at least ten minutes. Nil inputs are never judged.
    public static func isPlaceholder(duration: Double?, expectedRuntime: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0,
              let expectedRuntime, expectedRuntime.isFinite, expectedRuntime >= minimumKnownRuntime else { return false }
        return duration < max(60, expectedRuntime * 0.1)
    }

    /// The failure that sends playback on to the next candidate.
    public static let failureMessage = "This stream is a short error clip from the provider, not the title."
}
