import Foundation

/// Tells a file that ends early from one in a format the device cannot play.
///
/// A download cut short (`head -c 400000 Long.mp4`, a server that dropped the
/// connection while the file was written) fails to open the same way a
/// foreign codec does, so the viewer read "This stream uses a format
/// OpenStream cannot play" and had no Retry (full test 2026-10-01). The
/// container says how long it should be: an MP4 box or the Matroska Segment
/// that reaches past the last byte means the file is incomplete, and that is
/// reported as a network failure, which offers Retry.
enum AppleTruncatedMediaProbe {
    static let message = "The video ended before it finished downloading. Check the connection and try again."

    /// What the viewer reads for a demuxer or engine failure: the engine's
    /// own text ("HLSVideoEngine: open failed (Demuxer: open failed (Invalid
    /// data found when processing input (-1094995529)))") never reaches the
    /// alert.
    ///
    /// "Ended early" needs evidence the file stopped: playback had started
    /// (`midStream`), or the engine hit the end of the input. A demuxer that
    /// refuses a file at its first bytes says nothing about its length: a
    /// complete Dolby Vision x265 MP4 the demuxer cannot parse failed exactly
    /// that way and read "the file ended early" (V13). A file really cut
    /// short is caught by the container probe instead (`endsEarly`, run by
    /// the coordinator for an open failure before anything played).
    static let droppedMessage = "The file ended early or the connection dropped. Try again or choose another source."
    static let openFailedMessage = "oStream could not read this file. Try again or choose another source."

    static func readableEngineMessage(_ raw: String, midStream: Bool) -> String {
        let markers = ["open failed", "demuxer", "invalid data found", "end of file", "input/output error",
                       "hlsvideoengine", "avformat", "averror"]
        let lowered = raw.lowercased()
        guard markers.contains(where: lowered.contains) else { return raw }
        return midStream || hitsEndOfInput(lowered) ? droppedMessage : openFailedMessage
    }

    /// FFmpeg's AVERROR_EOF / EIO wording: the input ran out under the reader.
    private static func hitsEndOfInput(_ lowered: String) -> Bool {
        ["end of file", "input/output error", "averror_eof"].contains(where: lowered.contains)
    }
    /// Bytes read from the start of the file; enough for the header boxes.
    static let headLength = 65_536

    /// Reads the head of `url` and its full length, then `endsEarly(head:totalLength:)`.
    /// False whenever the head or the length cannot be had.
    static func endsEarly(_ url: URL, session: URLSession = .shared) async -> Bool {
        if url.isFileURL {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: headLength)) ?? Data()
            return endsEarly(head: head, totalLength: size.int64Value)
        }
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("bytes=0-\(headLength - 1)", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let total = totalLength(of: http) else { return false }
        var head = Data()
        head.reserveCapacity(headLength)
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count >= headLength { break }
            }
        } catch {
            return false
        }
        return endsEarly(head: head, totalLength: total)
    }

    /// The resource's full length: the total of a 206's Content-Range, or a
    /// 200's Content-Length.
    static func totalLength(of response: HTTPURLResponse) -> Int64? {
        if response.statusCode == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  let slash = range.lastIndex(of: "/") else { return nil }
            return Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    /// Whether the container's own sizes reach past `totalLength`.
    static func endsEarly(head: Data, totalLength: Int64) -> Bool {
        let bytes = [UInt8](head)
        guard bytes.count >= 8, totalLength > 0 else { return false }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return matroskaEndsEarly(bytes, totalLength: totalLength)
        }
        guard String(bytes: bytes[4 ..< 8], encoding: .ascii) == "ftyp" else { return false }
        return mp4EndsEarly(bytes, totalLength: totalLength)
    }

    private static func mp4EndsEarly(_ bytes: [UInt8], totalLength: Int64) -> Bool {
        var offset: Int64 = 0
        while offset + 8 <= Int64(bytes.count) {
            let start = Int(offset)
            var size = Int64(bigEndian(bytes[start ..< start + 4]))
            if size == 1 {
                guard start + 16 <= bytes.count else { return false }
                size = Int64(bitPattern: bigEndian(bytes[start + 8 ..< start + 16]))
            }
            // Zero runs to the end of the file; anything under a header is not a box.
            guard size >= 8 else { return false }
            if offset + size > totalLength { return true }
            offset += size
        }
        return false
    }

    private static func matroskaEndsEarly(_ bytes: [UInt8], totalLength: Int64) -> Bool {
        // EBML header: 4-byte id, then its size; the Segment follows it.
        guard let header = vint(bytes, at: 4) else { return false }
        let segmentID = 4 + header.length + Int(header.value)
        guard segmentID + 4 <= bytes.count,
              bytes[segmentID ..< segmentID + 4].elementsEqual([0x18, 0x53, 0x80, 0x67]),
              let segment = vint(bytes, at: segmentID + 4), !segment.isUnknown else { return false }
        let end = Int64(segmentID + 4 + segment.length) + Int64(segment.value)
        return end > totalLength
    }

    private static func vint(_ bytes: [UInt8], at index: Int) -> (value: UInt64, length: Int, isUnknown: Bool)? {
        guard index < bytes.count, bytes[index] != 0 else { return nil }
        let length = bytes[index].leadingZeroBitCount + 1
        guard index + length <= bytes.count else { return nil }
        var value = UInt64(bytes[index] & (0xFF >> length))
        for byte in bytes[index + 1 ..< index + length] { value = value << 8 | UInt64(byte) }
        let allOnes = (UInt64(1) << UInt64(7 * length)) - 1
        return (value, length, value == allOnes)
    }

    private static func bigEndian(_ slice: ArraySlice<UInt8>) -> UInt64 {
        slice.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
