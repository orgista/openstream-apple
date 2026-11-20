import Foundation

/// Declares in-stream captions that a provider's manifest left out.
///
/// AVFoundation only offers a legible track it can see in the manifest. When
/// `AppleCEA608Detector` finds CEA-608 data in a segment, this adds the
/// `EXT-X-MEDIA` line and the `CLOSED-CAPTIONS` attribute that make the same
/// data discoverable, and the existing caption pipeline
/// (`NativePlaybackEngine.applySubtitleSelection`) picks it up with no decoder
/// of our own.
///
/// Nothing here changes a manifest that already declares captions, and nothing
/// here changes a media playlist's bytes. Live playback can optimistically
/// wrap an undeclared media playlist while the bounded 608 probe observes it.
public enum AppleHLSCaptionDeclaration: Sendable {
    public static let groupID = "openstream-cc"
    public static let instreamID = "CC1"

    /// A master playlist is the one that lists variants; only it can carry a
    /// `CLOSED-CAPTIONS` declaration.
    public static func isMasterPlaylist(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    /// True when the provider already said something about captions — either a
    /// declaration or an explicit `CLOSED-CAPTIONS=NONE`, which is the
    /// provider saying "there are none" and must be left alone.
    public static func declaresClosedCaptions(_ text: String) -> Bool {
        text.contains("CLOSED-CAPTIONS") || text.contains("TYPE=CLOSED-CAPTIONS")
    }

    /// Adds the declaration to a master playlist. Returns the text unchanged
    /// when it is not a master, or when the provider already spoke.
    public static func declaring(_ text: String, language: String = "en") -> String {
        guard isMasterPlaylist(text), !declaresClosedCaptions(text) else { return text }
        let media = "#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"\(groupID)\","
            + "NAME=\"CC1\",LANGUAGE=\"\(language)\",INSTREAM-ID=\"\(instreamID)\","
            + "DEFAULT=NO,AUTOSELECT=YES"
        var lines = text.components(separatedBy: .newlines)
        var inserted = false
        var result: [String] = []
        result.reserveCapacity(lines.count + 1)
        for line in lines {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("#EXT-X-STREAM-INF") {
                if !inserted {
                    result.append(media)
                    inserted = true
                }
                result.append(clean + ",CLOSED-CAPTIONS=\"\(groupID)\"")
            } else {
                result.append(line)
            }
        }
        lines = result
        return lines.joined(separator: "\n")
    }

    /// Most live IPTV channels hand out a *media* playlist directly, and a
    /// media playlist has nowhere to declare captions. Wrapping it in a
    /// one-variant master gives the declaration somewhere to live without
    /// touching the media playlist the player then fetches.
    ///
    /// `bandwidth` is required by the format; the value is nominal because
    /// there is only ever one variant to choose from.
    public static func master(
        wrapping mediaPlaylistURI: String, bandwidth: Int = 2_000_000, language: String = "en"
    ) -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="\(groupID)",NAME="CC1",\
        LANGUAGE="\(language)",INSTREAM-ID="\(instreamID)",DEFAULT=NO,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CLOSED-CAPTIONS="\(groupID)"
        \(mediaPlaylistURI)
        """
    }

    /// The first segment a media playlist names, which is what the probe
    /// fetches to look for caption data. `nil` when the playlist names none.
    public static func firstSegmentURI(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !clean.hasPrefix("#") else { continue }
            return clean
        }
        return nil
    }
}
