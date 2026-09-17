import Foundation

/// Parses a downloaded subtitle file (SubRip or WebVTT) into the same cue type
/// the playback engine already renders. Both formats share one block layout:
/// an optional identifier line, a `start --> end` timing line, then the cue
/// text until a blank line. Timestamps accept either `,` or `.` for the
/// fractional part and may omit the hour field (WebVTT). Inline markup
/// (`<i>…</i>`, ASS `{\an8}` overrides) is stripped so the cue carries plain
/// text; gzip payloads are inflated first because add-ons commonly serve
/// `.srt.gz`.
public enum AppleSubtitleTextParser {
    /// Cap on cues taken from one file. A feature-length subtitle track holds
    /// roughly 2,000 cues, so this only bounds a hostile or malformed payload.
    public static let maximumCues = 20_000

    /// A subtitle file is a few hundred KB; anything past this is not one.

    static let maximumInflatedBytes = 32_000_000


    public static func cues(from data: Data) -> [AppleSubtitleCue] {
        let payload = decompressedIfNeeded(data)
        guard let text = decodeText(payload) else { return [] }
        return cues(from: text)
    }

    public static func cues(from text: String) -> [AppleSubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var cues: [AppleSubtitleCue] = []
        var index = 0
        while index < lines.count, cues.count < maximumCues {
            let line = lines[index]
            index += 1
            guard let timing = timing(in: line) else { continue }
            var body: [String] = []
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if self.timing(in: next) != nil { break }
                // An identifier line directly above the next timing line
                // belongs to that cue, not to this one.
                if !body.isEmpty, index + 1 < lines.count, self.timing(in: lines[index + 1]) != nil { break }
                body.append(strippedMarkup(next))
                index += 1
            }
            let joined = body
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, timing.end > timing.start else { continue }
            cues.append(
                AppleSubtitleCue(
                    id: cues.count,
                    startTime: timing.start,
                    endTime: timing.end,
                    body: .text(joined)
                )
            )
        }
        return cues
    }

    // MARK: - Timing

    static func timing(in line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        guard let start = seconds(String(line[line.startIndex ..< arrow.lowerBound])),
              let end = seconds(String(line[arrow.upperBound ..< line.endIndex])) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, or the hour-less WebVTT `MM:SS.mmm`.
    /// Trailing WebVTT cue settings (`line:90% align:middle`) are ignored.
    static func seconds(_ raw: String) -> Double? {
        let token = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: " ")
            .first
            .map(String.init)
        guard let token else { return nil }
        let parts = token.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: - Text

    /// Drops `<…>` and `{…}` markup and decodes the handful of HTML entities
    /// subtitle files actually use.
    static func strippedMarkup(_ line: String) -> String {
        var result = ""
        var angleDepth = 0
        var braceDepth = 0
        for character in line {
            switch character {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            default:
                if angleDepth == 0, braceDepth == 0 { result.append(character) }
            }
        }
        return decodedEntities(result).trimmingCharacters(in: .whitespaces)
    }

    private static func decodedEntities(_ value: String) -> String {
        AppleHTMLEntities.decoded(value)
    }

    /// UTF-8 first, then the legacy single-byte encodings older SubRip files
    /// still use. A byte-order mark is dropped by the UTF-8 decoder.
    static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let cp1252 = String(data: data, encoding: .windowsCP1252) { return cp1252 }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - gzip

    /// Inflates a gzip payload by stripping the RFC 1952 header and trailer and
    /// running the raw DEFLATE body through Foundation's zlib decompressor.
    /// Non-gzip data is returned unchanged.
    static func decompressedIfNeeded(_ data: Data) -> Data {
        let start = data.startIndex
        guard data.count > 18,
              data[start] == 0x1f, data[start + 1] == 0x8b, data[start + 2] == 0x08 else { return data }
        let flags = data[start + 3]
        var offset = start + 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= data.endIndex else { return data }
            let length = Int(data[offset]) | Int(data[offset + 1]) << 8
            offset += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME
            guard offset < data.endIndex, let end = data[offset...].firstIndex(of: 0) else { return data }
            offset = end + 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            guard offset < data.endIndex, let end = data[offset...].firstIndex(of: 0) else { return data }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < data.endIndex - 8 else { return data }
        let deflated = Data(data[offset ..< (data.endIndex - 8)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib),
              inflated.length <= maximumInflatedBytes else { return data }
        return inflated as Data
    }
}
