import Foundation

/// The audio half of the "Audio & Subtitles" menu: human labels, one row per
/// distinct label, and which row is playing.
///
/// The engine names tracks the way the container does ("ENG (ac3)", "SPA
/// (aac)") and the menu used to append the language code again, so a row read
/// "ENG (ac3) (eng)" with no check mark on the track playing (full test
/// 2026-10-01). A row now reads "English · AC-3 5.1", "Spanish · AAC
/// Stereo", or "Commentary" when the track is one.
public enum AppleAudioTrackMenu {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let trackID: Int
        public let title: String
        public let isSelected: Bool
        public var id: Int { trackID }
    }

    /// One entry per distinct label, in stream order. Among tracks that read
    /// the same, the playing one stands for the row, else the default, else
    /// the first. `activeTrackID` is the engine's (or the last pick); nil
    /// falls back to the default track, then the first.
    public static func entries(_ tracks: [ApplePlaybackTrack], activeTrackID: Int?) -> [Entry] {
        let active = activeTrackID.flatMap { id in tracks.first { $0.id == id }?.id }
            ?? tracks.first(where: \.isDefault)?.id
            ?? tracks.first?.id
        var order: [String] = []
        var chosen: [String: ApplePlaybackTrack] = [:]
        for track in tracks {
            let title = label(for: track)
            guard let current = chosen[title] else {
                order.append(title)
                chosen[title] = track
                continue
            }
            if track.id == active || (current.id != active && track.isDefault && !current.isDefault) {
                chosen[title] = track
            }
        }
        return order.compactMap { title in
            guard let track = chosen[title] else { return nil }
            return Entry(trackID: track.id, title: title, isSelected: track.id == active)
        }
    }

    /// "English · AC-3 5.1"; "Commentary" for a commentary track.
    public static func label(for track: ApplePlaybackTrack) -> String {
        let languageCode = AppleSubtitleTrackFilter.languageKey(of: track)
        let language = languageCode.isEmpty ? nil : AppleSubtitleTrackFilter.languageName(languageCode)
        if isCommentary(track) { return "Commentary" }
        let format = formatName(for: track)
        switch (language, format) {
        case let (language?, format?): return "\(language) · \(format)"
        case let (language?, nil): return language
        case let (nil, format?): return format
        case (nil, nil):
            let title = track.title.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "Audio" : title
        }
    }

    static func isCommentary(_ track: ApplePlaybackTrack) -> Bool {
        track.isCommentary
            || track.title.range(of: #"\bcommentary\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "E-AC-3 5.1", "AAC Stereo": the codec's own name, never a licensed
    /// format brand (licence audit 2026-10-22). Nil when neither the codec
    /// nor the channel count is known.
    static func formatName(for track: ApplePlaybackTrack) -> String? {
        let codec = codecName(track.codec?.lowercased() ?? "")
        let layout = channelName(track.channels)
        switch (codec, layout) {
        case let (codec?, layout?): return "\(codec) \(layout)"
        case let (codec?, nil): return codec
        case let (nil, layout?): return layout
        case (nil, nil): return nil
        }
    }

    static func codecName(_ codec: String) -> String? {
        switch codec {
        case "ac3", "ac-3": return "AC-3"
        case "eac3", "ec-3", "e-ac-3": return "E-AC-3"
        case "truehd", "mlp": return "TrueHD"
        case "dts", "dca": return "DTS"
        case "aac", "aac_latm", "mp4a": return "AAC"
        case "mp3", "mp3float": return "MP3"
        case "mp2", "mp2float": return "MPEG Audio"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "": return nil
        default:
            return codec.hasPrefix("pcm") ? "PCM" : codec.uppercased()
        }
    }

    static func channelName(_ channels: Int) -> String? {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        case 3...: "\(channels) ch"
        default: nil
        }
    }
}
