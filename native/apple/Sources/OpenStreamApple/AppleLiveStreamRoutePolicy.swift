import Foundation

/// Decides whether a live channel should be handed to AVPlayer as remote HLS
/// (`LoadOptions.nativeRemoteHLS`) or demuxed by the engine as raw MPEG-TS.
///
/// Tester, build 10 / owner 2026-09-17: a French playlist served HLS from
/// extension-less URLs (`https://host/895` → 302 → `….m3u8`). The engine's
/// raw live path opened those with FFmpeg and failed ("Demuxer: open failed
/// (Operation not permitted (-1))"). Extensions decide when they can; when
/// they cannot, a 32 KB probe (`AppleIPTVStreamProbe`) looks at the bytes.
public enum AppleLiveStreamRoutePolicy {
    static let hlsExtensions: Set<String> = ["m3u8", "m3u"]
    static let rawExtensions: Set<String> = ["ts", "m2ts", "mts", "mp4", "mkv", "webm", "mov", "flv", "avi", "mp3", "aac"]

    /// True when the URL's extension says nothing usable and a probe is worth
    /// the round trip.
    public static func needsProbe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        return !hlsExtensions.contains(ext) && !rawExtensions.contains(ext)
    }

    /// The route: `true` = AVPlayer plays the origin URL (HLS), `false` = the
    /// engine demuxes it. `probedKind` wins when present; otherwise only an
    /// HLS extension flips the bit, so raw and unknown streams stay on the
    /// engine path that has always played them.
    public static func nativeRemoteHLS(url: URL, probedKind: AppleIPTVStreamProbeResult.MediaKind?) -> Bool {
        switch probedKind {
        case .hlsPlaylist: return true
        case .rawMPEGTransportStream, .other: return false
        case nil: return hlsExtensions.contains(url.pathExtension.lowercased())
        }
    }
}
