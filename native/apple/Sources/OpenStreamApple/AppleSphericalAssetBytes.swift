import Foundation

/// The original sample offsets stay valid; only box headers and an appended movie change.
struct AppleSphericalAssetBytes: Sendable {
    static let chunkSize: Int64 = 4 << 20
    private static let largestMovieHeader: Int64 = 64 << 20
    private let sourceLength: Int64
    private let patches: [Patch]
    let movie: Data
    var totalLength: Int64 { sourceLength + Int64(movie.count) }

    private struct Patch: Sendable {
        let offset: Int64
        let bytes: Data
    }

    static func make(length: Int64, boxes: [UInt8],
                     read: @Sendable (Range<Int64>) async throws -> Data) async throws -> Self? {
        guard length >= 8, length < Int64.max - largestMovieHeader else { return nil }
        var offset: Int64 = 0
        var patches: [Patch] = []
        var movie: Data?
        var boxCount = 0
        while offset < length {
            boxCount += 1
            guard boxCount <= 4096, length - offset >= 8 else { return nil }
            let head = [UInt8](try await readExactly(offset..<min(length, offset + 16), read: read))
            let shortSize = AppleSphericalMetadataWriter.readUInt32(head, at: 0)
            let headerLength: Int64 = shortSize == 1 ? 16 : 8
            let size: Int64
            if shortSize == 1 {
                guard head.count == 16 else { return nil }
                let extended = head[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard let signed = Int64(exactly: extended) else { return nil }
                size = signed
            } else {
                size = shortSize == 0 ? length - offset : Int64(shortSize)
            }
            guard size >= headerLength, size <= length - offset else { return nil }
            if shortSize == 0 {
                // A size-to-EOF box would otherwise swallow the appended movie.
                guard let finiteSize = UInt32(exactly: size) else { return nil }
                patches.append(Patch(offset: offset, bytes: withUnsafeBytes(of: finiteSize.bigEndian) { Data($0) }))
            }
            let type = String(decoding: head[4..<8], as: UTF8.self)
            guard type != "moof", type != "mvex", type != "sidx" else { return nil }
            if type == "moov" {
                guard movie == nil, size <= largestMovieHeader else { return nil }
                let body = try await readExactly(offset + headerLength..<offset + size, read: read)
                let normalizedSize = UInt32(body.count + 8)
                let normalized = [UInt8](withUnsafeBytes(of: normalizedSize.bigEndian) { Data($0) }
                    + Data("moov".utf8) + body)
                guard let children = AppleSphericalMetadataWriter.children(of: normalized, in: 8..<normalized.count),
                      !children.contains(where: { $0.type == "mvex" }),
                      let tagged = AppleSphericalMetadataWriter.taggedMovie(normalized, boxes: boxes) else { return nil }
                movie = Data(tagged)
                patches.append(Patch(offset: offset + 4, bytes: Data("free".utf8)))
            }
            offset += size
        }
        guard let movie, Int64(movie.count) <= Int64.max - length else { return nil }
        return Self(sourceLength: length, patches: patches, movie: movie)
    }

    func bytes(in range: Range<Int64>, read: @Sendable (Range<Int64>) async throws -> Data) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= totalLength else { throw URLError(.badURL) }
        var bytes = Data()
        if range.lowerBound < sourceLength {
            let sourceRange = range.lowerBound..<min(range.upperBound, sourceLength)
            bytes = try await Self.readExactly(sourceRange, read: read)
            for patch in patches {
                for offset in (patch.offset..<patch.offset + Int64(patch.bytes.count)).clamped(to: sourceRange) {
                    bytes[Int(offset - sourceRange.lowerBound)] = patch.bytes[Int(offset - patch.offset)]
                }
            }
        }
        if range.upperBound > sourceLength {
            bytes += movie.subdata(in: Int(max(0, range.lowerBound - sourceLength))..<Int(range.upperBound - sourceLength))
        }
        return bytes
    }

    private static func readExactly(_ range: Range<Int64>,
                                    read: @Sendable (Range<Int64>) async throws -> Data) async throws -> Data {
        var bytes = Data()
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            let end = min(range.upperBound, offset + chunkSize)
            let part = try await read(offset..<end)
            guard !part.isEmpty, part.count <= end - offset else { throw URLError(.badServerResponse) }
            bytes += part
            offset += Int64(part.count)
        }
        return bytes
    }
}
