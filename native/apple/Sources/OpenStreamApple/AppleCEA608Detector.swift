import Foundation

/// Finds broadcast captions that a provider forgot to declare.
///
/// Why this exists: many IPTV providers carry CEA-608 captions inside the
/// video elementary stream, as H.264 SEI user data (ATSC A/53), and never put
/// `CLOSED-CAPTIONS` / `INSTREAM-ID` in the HLS manifest. AVFoundation
/// discovers legible tracks from the manifest, so it never offers them — which
/// is why the same channel shows captions on the Android build (it decodes the
/// in-stream data regardless of what the manifest says) and shows none here.
///
/// This type only answers "are they in there?". Nothing is decoded: once the
/// answer is yes, the manifest is patched to declare `INSTREAM-ID="CC1"` and
/// AVFoundation's own caption pipeline does the rest —
/// `NativePlaybackEngine.applySubtitleSelection` already works once a track is
/// discoverable. See `AppleHLSCaptionDeclaration`.
public enum AppleCEA608Detector: Sendable {
    /// ATSC A/53 `user_data_registered_itu_t_t35`: country code 0xB5 (United
    /// States), provider code 0x0031 (ATSC), user identifier "GA94". The four
    /// ASCII bytes make this specific enough that a run of video bytes does not
    /// trip it by accident.
    public static let atscUserIdentifier: [UInt8] = [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34]

    /// Captions ride one SEI message per frame, so a segment that really
    /// carries them has dozens of hits. A handful is the bar, which leaves no
    /// room for a coincidence and still clears on a very short segment.
    public static let minimumOccurrences = 3

    /// MPEG-TS packet length, sync byte first.
    public static let transportPacketLength = 188
    static let transportSyncByte: UInt8 = 0x47

    /// Does this segment carry CEA-608 captions the manifest never declared?
    ///
    /// Accepts a transport-stream segment or a raw elementary stream; a `.ts`
    /// segment is unwrapped first so a packet header cannot split the signature
    /// and hide it.
    public static func carriesCEA608(
        in data: Data, minimumOccurrences: Int = minimumOccurrences
    ) -> Bool {
        let payload = elementaryStream(from: data) ?? data
        return occurrences(of: atscUserIdentifier, in: payload) >= minimumOccurrences
    }

    /// Strips 188-byte transport packet headers (and adaptation fields), giving
    /// back the packetized elementary stream. `nil` when the data is not a
    /// transport stream, in which case the caller scans it as it arrived.
    public static func elementaryStream(from data: Data) -> Data? {
        guard data.count >= transportPacketLength, data.first == transportSyncByte else { return nil }
        var result = Data()
        result.reserveCapacity(data.count)
        var index = data.startIndex
        while index + transportPacketLength <= data.endIndex {
            let packet = data[index ..< index + transportPacketLength]
            index += transportPacketLength
            guard packet.first == transportSyncByte else { return nil }
            let bytes = [UInt8](packet)
            let adaptationControl = (bytes[3] & 0x30) >> 4
            // 0b00 and 0b10 carry no payload; 0b11 puts an adaptation field
            // first, whose own length byte says how far the payload starts.
            var payloadStart = 4
            if adaptationControl == 0b10 || adaptationControl == 0b00 { continue }
            if adaptationControl == 0b11 {
                payloadStart += 1 + Int(bytes[4])
                guard payloadStart <= transportPacketLength else { continue }
            }
            result.append(contentsOf: bytes[payloadStart...])
        }
        return result.isEmpty ? nil : result
    }

    /// How many times the signature appears. Exposed so a probe can report a
    /// count rather than a bare yes/no.
    public static func occurrences(of pattern: [UInt8], in data: Data) -> Int {
        guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
        let bytes = [UInt8](data)
        var count = 0
        var index = 0
        let limit = bytes.count - pattern.count
        while index <= limit {
            if bytes[index] == pattern[0] {
                var matched = true
                for offset in 1 ..< pattern.count where bytes[index + offset] != pattern[offset] {
                    matched = false
                    break
                }
                if matched {
                    count += 1
                    index += pattern.count
                    continue
                }
            }
            index += 1
        }
        return count
    }
}
