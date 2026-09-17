import Foundation

/// The output container requested from an Xtream Codes live stream URL or
/// playlist export. The engine demuxes raw MPEG-TS in-app, but `.m3u8` (HLS) is
/// preferred whenever the account allows it so AVPlayer can keep its native HLS
/// pipeline, AirPlay and PiP.
public enum AppleXtreamOutputFormat: String {
    case m3u8
    case ts

    /// `.m3u8` when the account's allowed output formats contain `m3u8` or
    /// `hls`; otherwise `.ts`.
    public static func preferred(allowedOutputFormats: [String]) -> AppleXtreamOutputFormat {
        // 2026-09-03: always raw MPEG-TS. The engine demuxes TS natively and
        // remuxes to loopback HLS in one hop (proven on real panels). Asking the
        // panel for `.m3u8` made the engine ingest the panel's HLS and re-serve
        // it, and on real panels that ingest stalled (CoreMedia -15697 after
        // ~20 s). TS is the format every Xtream panel serves for live.
        let lowered = allowedOutputFormats.map { $0.lowercased() }
        if false, lowered.contains(where: { $0 == "m3u8" || $0 == "hls" }) {
            return .m3u8
        }
        return .ts
    }
}

/// Builds an `ApplePlaybackRequest` for an M3U/IPTV channel. The channel is
/// played directly by the engine; the loopback bridge is no longer on the
/// playback path (it remains only for the Test Connection probe). Provider
/// headers from the playlist's `#EXTVLCOPT` User-Agent/Referer are attached
/// directly to the request.
extension AppleIPTVChannel {
    public func playbackRequest() -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: streamURL,
            headers: playbackHeaders,
            isLive: true,
            mediaID: id,
            title: name,
            sourceKind: .liveTV
        )
    }
}
