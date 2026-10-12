import Foundation

/// Finds the elements of one array in a JSON document without building the
/// whole document's object tree.
///
/// A catalog response can be many megabytes when an add-on inlines full metas
/// (TMDB's series "tmdb.top" shelf is ~12 MB of episode lists). Decoding it in
/// one go parses every episode of every show; walking the bytes instead lets
/// the catalog client decode one entry at a time and stop at its item cap, so
/// only the fields a shelf keeps are ever materialised.
enum AppleJSONArrayElementScanner {
    /// Byte ranges of at most `limit` elements of the array stored under
    /// `key` in the document's top-level object, or nil when the document is
    /// not an object, has no such key, or the value is not an array.
    /// Elements past `limit` are not inspected. Ranges are offsets from the
    /// start of `data`.
    static func elements(ofTopLevelKey key: String, in data: Data, limit: Int) -> [Range<Int>]? {
        data.withUnsafeBytes { scan(key: key, bytes: $0, limit: limit) }
    }

    private static func scan(key: String, bytes: UnsafeRawBufferPointer, limit: Int) -> [Range<Int>]? {
        var scanner = Cursor(bytes: bytes)
        scanner.skipWhitespace()
        guard scanner.consume(UInt8(ascii: "{")) else { return nil }
        let wanted = Array(key.utf8)
        while true {
            scanner.skipWhitespace()
            guard let next = scanner.peek else { return nil }
            if next == UInt8(ascii: "}") { return nil }
            guard next == UInt8(ascii: "\""), let name = scanner.string() else { return nil }
            scanner.skipWhitespace()
            guard scanner.consume(UInt8(ascii: ":")) else { return nil }
            scanner.skipWhitespace()
            if Self.matches(name, wanted, bytes: bytes) {
                return scanner.arrayElements(limit: limit)
            }
            guard scanner.skipValue() else { return nil }
            scanner.skipWhitespace()
            if scanner.consume(UInt8(ascii: ",")) { continue }
            return nil
        }
    }

    /// Compares a raw key (between its quotes) with the wanted name; an
    /// escaped key is decoded first.
    private static func matches(_ range: Range<Int>, _ wanted: [UInt8], bytes: UnsafeRawBufferPointer) -> Bool {
        let raw = bytes[range]
        if !raw.contains(UInt8(ascii: "\\")) { return raw.elementsEqual(wanted) }
        let quoted = Data([UInt8(ascii: "\"")] + Array(raw) + [UInt8(ascii: "\"")])
        guard let decoded = try? JSONDecoder().decode(String.self, from: quoted) else { return false }
        return Array(decoded.utf8) == wanted
    }

    private struct Cursor {
        let bytes: UnsafeRawBufferPointer
        var index = 0

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0xEF
                || byte == 0xBB || byte == 0xBF {
                index += 1
            }
        }

        /// Consumes a string at the cursor; returns the range between its quotes.
        mutating func string() -> Range<Int>? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    let end = index
                    index += 1
                    return start ..< end
                default: index += 1
                }
            }
            return nil
        }

        /// Skips one complete value (object, array, string or literal).
        mutating func skipValue() -> Bool {
            guard let first = peek else { return false }
            switch first {
            case UInt8(ascii: "\""):
                return string() != nil
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""):
                        guard string() != nil else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return true
                        }
                    default:
                        break
                    }
                    index += 1
                }
                return false
            default:
                let start = index
                while let byte = peek, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                                        0x20, 0x0A, 0x0D, 0x09].contains(byte) {
                    index += 1
                }
                return index > start
            }
        }

        mutating func arrayElements(limit: Int) -> [Range<Int>]? {
            guard consume(UInt8(ascii: "[")) else { return nil }
            var result: [Range<Int>] = []
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return result }
            while result.count < limit {
                skipWhitespace()
                let start = index
                guard skipValue() else { return nil }
                result.append(start ..< index)
                skipWhitespace()
                if consume(UInt8(ascii: ",")) { continue }
                guard consume(UInt8(ascii: "]")) else { return nil }
                return result
            }
            return result
        }
    }
}
