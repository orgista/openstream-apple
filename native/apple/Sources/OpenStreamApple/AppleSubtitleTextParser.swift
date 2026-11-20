import Compression
import Foundation

/// Parses a downloaded subtitle file (SubRip or WebVTT) into the same cue type
/// the playback engine already renders. Both formats share one block layout:
/// an optional identifier line, a `start --> end` timing line, then the cue
/// text until a blank line. Timestamps accept either `,` or `.` for the
/// fractional part and may omit the hour field (WebVTT). Inline markup
/// (`<i>…</i>`, ASS `{\an8}` overrides) is stripped so the cue carries plain
/// text; gzip payloads (`.srt.gz`) are inflated first.
public enum AppleSubtitleTextParser {
    /// Cap on cues taken from one file. A feature-length subtitle track holds
    /// roughly 2,000 cues, so this only bounds a hostile or malformed payload.
    public static let maximumCues = 20_000

    /// A subtitle file is a few hundred KB; anything past this is not one.

    static let maximumInflatedBytes = 32_000_000


    /// `language` is the file's declared language, the
    /// best hint for a legacy code page (`AppleSubtitleTextEncoding`).
    public static func cues(from data: Data, language: String? = nil) -> [AppleSubtitleCue] {
        let payload = decompressedIfNeeded(data)
        guard let text = decodeText(payload, language: language) else { return [] }
        return cues(from: text)
    }

    public static func cues(from text: String) -> [AppleSubtitleCue] {
        let normalized = musicNotesRestored(utf8MojibakeRepaired(text))
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

    // MARK: - Repairs

    /// UTF-8 that was read as Latin-1 and written out as UTF-8 again: "Â£"
    /// where "£" was meant, "Ã©" for "é". One of the two OpenSubtitles files
    /// for A Different World S1E1 is this (2026-10-01). Re-read as Latin-1
    /// bytes, such text is valid UTF-8 again; real text with an "Â" or "Ã"
    /// in it almost never is, and any character Latin-1 cannot hold leaves
    /// the text as it was.
    static func utf8MojibakeRepaired(_ text: String) -> String {
        guard text.contains(where: { $0 == "Â" || $0 == "Ã" }),
              let bytes = text.data(using: .isoLatin1, allowLossyConversion: false),
              let repaired = String(data: bytes, encoding: .utf8) else { return text }
        return repaired
    }

    /// Captions taken from US broadcast line 21 carry "♪" as CEA-608's
    /// special character 0x37, right beside "£" (0x36), and caption
    /// extractors have written it out as "£". The file itself says "£": both
    /// OpenSubtitles files for A Different World S1E1 open "£ I know my
    /// parents love me £" (iOS 18.6 regression 2026-10-01, screens 28–31).
    /// A "£" with no amount beside it is that note; "£5", "5 £" and "£ 20"
    /// stay money.
    static func musicNotesRestored(_ text: String) -> String {
        guard text.contains("£") else { return text }
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)
        for (index, character) in characters.enumerated() {
            guard character == "£" else { result.append(character); continue }
            result.append(isAmountBeside(characters, at: index) ? "£" : "♪")
        }
        return result
    }

    private static func isAmountBeside(_ characters: [Character], at index: Int) -> Bool {
        var after = index + 1
        while after < characters.count, characters[after] == " " { after += 1 }
        if after < characters.count, characters[after].isNumber { return true }
        var before = index - 1
        while before >= 0, characters[before] == " " { before -= 1 }
        return before >= 0 && characters[before].isNumber
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

    /// Unicode with or without a byte-order mark, then the legacy code page
    /// of the declared language (`AppleSubtitleTextEncoding`).
    static func decodeText(_ data: Data, language: String? = nil) -> String? {
        AppleSubtitleTextEncoding.decode(data, language: language)
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
        guard let inflated = inflate(deflated, limit: maximumInflatedBytes) else { return data }
        return inflated
    }

    /// Raw DEFLATE, streamed in chunks so a tiny zip bomb stops at `limit`
    /// instead of inflating to gigabytes first. Nil when the payload is
    /// corrupt or would exceed the limit.
    static func inflate(_ deflated: Data, limit: Int) -> Data? {
        let chunkSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }
        var output = Data()
        return deflated.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunkSize
                let pending = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                guard output.count + produced <= limit else { return nil }
                output.append(destination, count: produced)
                switch status {
                case COMPRESSION_STATUS_OK:
                    // No output and no input consumed: stuck on a truncated stream.
                    if produced == 0, stream.pointee.src_size == pending { return nil }
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
    }
}
