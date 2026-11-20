import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleSphericalAssetBytesTests {
    private func box(_ type: String, _ body: Data = Data(), extended: Bool = false, toEnd: Bool = false) -> Data {
        let size: UInt32 = toEnd ? 0 : (extended ? 1 : UInt32(body.count + 8))
        var bytes = withUnsafeBytes(of: size.bigEndian) { Data($0) } + Data(type.utf8)
        if extended { bytes += withUnsafeBytes(of: UInt64(body.count + 16).bigEndian) { Data($0) } }
        return bytes + body
    }

    private var video: Data {
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + Data("vide".utf8))
        let stsd = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + box("avc1", Data(repeating: 7, count: 78)))
        return box("trak", box("mdia", hdlr + box("minf", box("stbl", stsd))))
    }

    private func plan(_ original: Data) async throws -> AppleSphericalAssetBytes? {
        try await AppleSphericalAssetBytes.make(length: Int64(original.count), boxes: [1, 2, 3]) { range in
            original.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
    }

    @Test(arguments: [false, true])
    func fragmentedMovieIsRejected(fragmentInsideMovie: Bool) async throws {
        let original = box("moov", video + (fragmentInsideMovie ? box("mvex") : Data()))
            + (fragmentInsideMovie ? box("mdat") : box("moof"))
        #expect(try await plan(original) == nil)
    }

    @Test func mappingCrossesTheAppendedMovieBoundary() async throws {
        let original = box("moov", video) + box("mdat", Data([10, 11, 12]))
        let map = try #require(try await plan(original))
        let start = Int64(original.count - 2)
        let bytes = try await map.bytes(in: start..<start + 14) { range in
            original.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        #expect(bytes == original.suffix(2) + map.movie.prefix(12))
    }

    @Test func freeRenameWorksAcrossEveryChunkBoundaryAndShortRead() async throws {
        let original = box("moov", video) + box("mdat", Data([10, 11, 12]))
        let map = try #require(try await plan(original))
        var result = Data()
        for offset in 0..<original.count {
            result += try await map.bytes(in: Int64(offset)..<Int64(offset + 1)) { range in
                original.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            }
        }
        var expected = original
        expected.replaceSubrange(4..<8, with: Data("free".utf8))
        #expect(result == expected)
        let all = try await map.bytes(in: 0..<map.totalLength) { range in
            original.subdata(in: Int(range.lowerBound)..<min(Int(range.upperBound), Int(range.lowerBound) + 3))
        }
        #expect(all == expected + map.movie)
    }

    @Test(arguments: ["moov", "mdat"])
    func zeroSizeBoxIsClampedBeforeAppending(type: String) async throws {
        let original = type == "moov" ? box("mdat") + box("moov", video, toEnd: true)
            : box("moov", video) + box("mdat", Data([9, 8, 7]), toEnd: true)
        let map = try #require(try await plan(original))
        let bytes = try await map.bytes(in: 0..<map.totalLength) { range in
            original.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let zeroOffset = type == "moov" ? 8 : box("moov", video).count
        #expect(AppleSphericalMetadataWriter.readUInt32(Array(bytes), at: zeroOffset) == original.count - zeroOffset)
        #expect(bytes.suffix(map.movie.count) == map.movie)
    }

    @Test func extendedSizeMovieIsNormalizedAndOffsetsStayPut() async throws {
        let original = box("moov", video, extended: true) + box("mdat", Data([4, 5, 6]))
        let map = try #require(try await plan(original))
        #expect(map.movie.count == video.count + 8 + 3)
        #expect(AppleSphericalMetadataWriter.readUInt32(Array(map.movie), at: 0) == map.movie.count)
        let bytes = try await map.bytes(in: 8..<Int64(original.count)) { range in
            original.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        #expect(bytes == original.dropFirst(8))
    }

    @Test func malformedExtendedSizeAndTruncatedHeadersAreRejected() async throws {
        #expect(try await plan(Data([0, 0, 0, 1]) + Data("moov".utf8)) == nil)
        let invalid = Data([0, 0, 0, 1]) + Data("moov".utf8) + Data(repeating: 255, count: 8)
        #expect(try await plan(invalid) == nil)
        #expect(try await plan(box("moov", video) + Data([0])) == nil)
    }

    @Test func emptyReadFailsInsteadOfSpinning() async throws {
        let map = try #require(try await plan(box("moov", video)))
        await #expect(throws: URLError.self) {
            _ = try await map.bytes(in: 0..<8) { _ in Data() }
        }
    }
}
