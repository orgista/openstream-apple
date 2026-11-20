import Foundation

/// Writes Google spherical-video boxes (`st3d`, `sv3d`) into an MP4/QuickTime
/// `moov`, which AVFoundation turns into APMP when it opens the file with
/// `AVURLAssetShouldParseExternalSphericalTagsKey`.
enum AppleSphericalMetadataWriter {
    /// Half-equirectangular: a quarter of the sphere's width is outside the
    /// frame on each side (0.32 fixed point).
    private static let hemisphereSideBound: UInt32 = 0x4000_0000

    /// The boxes a video sample entry carries for `layout`. Nil for
    /// right-eye-first files: `st3d` has no eye-order field; those use the compositor.
    static func sphericalBoxes(for layout: AppleImmersiveVideoLayout) -> [UInt8]? {
        guard !layout.eyesSwapped else { return nil }
        let stereoMode: UInt8 = switch layout.packing {
        case .mono: 0
        case .overUnder: 1
        case .sideBySide: 2
        }
        let side = layout.projection == .halfSphere ? hemisphereSideBound : 0
        let header = fullBox("svhd", [0])
        let pose = fullBox("prhd", [UInt8](repeating: 0, count: 12))
        let bounds = fullBox("equi", bigEndian(0) + bigEndian(0) + bigEndian(side) + bigEndian(side))
        return fullBox("st3d", [stereoMode]) + box("sv3d", header + box("proj", pose + bounds))
    }

    /// `moov` with `boxes` appended to every video sample entry, sizes fixed
    /// up the tree. Nil when there is no video entry or the header is not
    /// laid out as expected.
    static func taggedMovie(_ moov: [UInt8], boxes: [UInt8]) -> [UInt8]? {
        guard let top = children(of: moov, in: 0..<moov.count), top.count == 1,
              let tagged = rewrite(moov, top[0], depth: 0, boxes: boxes),
              tagged.count > moov.count else { return nil }
        return tagged
    }

    // MARK: Boxes

    struct Box: Equatable {
        let type: String
        let range: Range<Int>
        var body: Range<Int> { range.lowerBound + 8..<range.upperBound }
    }

    /// Boxes with 32-bit sizes filling `range` exactly.
    static func children(of bytes: [UInt8], in range: Range<Int>) -> [Box]? {
        var boxes: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(readUInt32(bytes, at: offset))
            guard size >= 8, offset + size <= range.upperBound else { return nil }
            boxes.append(Box(type: String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self),
                             range: offset..<offset + size))
            offset += size
        }
        return offset == range.upperBound ? boxes : nil
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static let path = ["moov", "trak", "mdia", "minf", "stbl", "stsd"]

    private static func rewrite(_ bytes: [UInt8], _ box: Box, depth: Int, boxes: [UInt8]) -> [UInt8]? {
        if depth == path.count {
            return self.box(box.type, Array(bytes[box.body]) + boxes)
        }
        guard box.type == path[depth], depth != 1 || isVideoTrack(bytes, box) else { return Array(bytes[box.range]) }
        // stsd: version, flags and entry count come before the entries.
        let skip = box.type == "stsd" ? 8 : 0
        let first = box.body.lowerBound + skip
        guard first <= box.range.upperBound,
              let entries = children(of: bytes, in: first..<box.range.upperBound) else { return nil }
        var body = Array(bytes[box.body.lowerBound..<first])
        for entry in entries {
            guard let rebuilt = rewrite(bytes, entry, depth: depth + 1, boxes: boxes) else { return nil }
            body += rebuilt
        }
        return self.box(box.type, body)
    }

    /// `trak/mdia/hdlr` names the `vide` handler.
    private static func isVideoTrack(_ bytes: [UInt8], _ trak: Box) -> Bool {
        guard let mdia = children(of: bytes, in: trak.body)?.first(where: { $0.type == "mdia" }),
              let hdlr = children(of: bytes, in: mdia.body)?.first(where: { $0.type == "hdlr" }),
              hdlr.body.count >= 12 else { return false }
        return bytes[hdlr.body.lowerBound + 8..<hdlr.body.lowerBound + 12].elementsEqual("vide".utf8)
    }

    private static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        bigEndian(UInt32(body.count + 8)) + Array(type.utf8) + body
    }

    private static func fullBox(_ type: String, _ body: [UInt8]) -> [UInt8] {
        box(type, [0, 0, 0, 0] + body)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
