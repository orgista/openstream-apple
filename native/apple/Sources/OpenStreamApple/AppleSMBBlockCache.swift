import Foundation

/// Disc-image bytes the SMB bridge has already read, in aligned 1 MiB blocks.
///
/// The engine walks a Blu-ray's UDF directory and playlists with one 256 KB
/// read-ahead window, and the walk alternates between the file entries (~1 MB
/// into the image) and the playlist data (~36 MB in), so every read evicts the
/// window the next one needs. The Last Airbender (2010).iso took 295 range
/// requests that touch 4 distinct 1 MiB blocks; each request was a full SMB
/// open, stat, read and close, ~57 ms on the owner's Wi-Fi, 17 s in all
/// (trace iphone-1017b, 2026-10-17). Served from these blocks it is 4 reads.
///
/// Only the engine's structure reads come here: 256 KB requests in the first
/// 64 MiB of a disc image. The title's own stream starts with the same 256 KB
/// read after every seek and then doubles; caching those would pull whole
/// blocks over SMB for each one and push the structure out. The blocks
/// outlive a play (each play gets a fresh bridge token), so a retry or a
/// second play of the same disc reads its structure from memory.
struct AppleSMBBlockCache {
    static let blockSize: UInt64 = 1 << 20
    /// 16 MiB in all; one Blu-ray's structure needed 4 blocks.
    static let capacity = 16
    /// The engine's disc-structure reads are 256 KB; its sequential title
    /// reads double from there to 8 MB.
    static let largestCachedRequest: UInt64 = 256 * 1_024
    /// Where a disc image keeps its structure: the UDF descriptors and file
    /// entries and the BDMV playlists and clip files sit ahead of the streams
    /// (The Last Airbender: all of it under 37 MiB).
    static let structureBlocks: UInt64 = 64

    struct Key: Hashable {
        let file: String
        let index: UInt64
    }

    private var blocks: [Key: Data] = [:]
    private var order: [Key] = []

    static func caches(path: String, request: Range<UInt64>) -> Bool {
        request.count <= largestCachedRequest
            && request.lowerBound < structureBlocks * blockSize
            && AppleDiscImagePolicy.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// The blocks `range` touches; `range` must be non-empty.
    static func blockIndices(for range: Range<UInt64>) -> ClosedRange<UInt64> {
        (range.lowerBound / blockSize) ... ((range.upperBound - 1) / blockSize)
    }

    /// The bytes of block `index`, cut at the end of the file.
    static func byteRange(ofBlock index: UInt64, fileSize: UInt64) -> Range<UInt64> {
        let start = index * blockSize
        return start ..< min(start + blockSize, fileSize)
    }

    /// The part of `block` (block `index`) that falls inside `range`; empty
    /// when the block ends before it (a short read at the end of the file).
    static func slice(_ block: Data, index: UInt64, of range: Range<UInt64>) -> Data {
        let start = index * blockSize
        let lower = max(range.lowerBound, start) - start
        let upper = min(range.upperBound, start + UInt64(block.count))
        guard upper > start + lower else { return Data() }
        let base = block.startIndex
        return block.subdata(in: (base + Int(lower)) ..< (base + Int(upper - start)))
    }

    mutating func block(for key: Key) -> Data? {
        guard let data = blocks[key] else { return nil }
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return data
    }

    mutating func store(_ data: Data, for key: Key) {
        if blocks[key] == nil, order.count >= Self.capacity {
            blocks[order.removeFirst()] = nil
        }
        blocks[key] = data
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    mutating func removeAll() {
        blocks.removeAll()
        order.removeAll()
    }

    var count: Int { blocks.count }
}

/// The disc-structure blocks of recent disc images on disk, so a disc opened
/// again after a relaunch reads its structure without touching the share.
///
/// The engine keeps its disc parse per process and keys it by the playback
/// URL, which carries a fresh bridge token every play, so every open after a
/// relaunch walked the UDF and BDMV tree over SMB again. A file is the same
/// file only at the same path, size and modification date; without a date
/// nothing is kept.
public struct AppleDiscStructureStore: Sendable {
    static let standard = AppleDiscStructureStore(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenStream", isDirectory: true).appendingPathComponent("disc-structure", isDirectory: true))
    /// Discs kept; each holds only the 1 MiB structure blocks its opens read (4 for one Blu-ray).
    static let discLimit = 8

    let directory: URL

    /// The stored blocks of `file`, dropping any that are not the block's full length.
    @concurrent func blocks(file: String, fileSize: UInt64) async -> [UInt64: Data] {
        let folder = folder(for: file)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var blocks: [UInt64: Data] = [:]
        for name in names {
            guard let index = UInt64(name), index < AppleSMBBlockCache.structureBlocks,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  data.count == AppleSMBBlockCache.byteRange(ofBlock: index, fileSize: fileSize).count else { continue }
            blocks[index] = data
        }
        if !blocks.isEmpty {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.path)
        }
        return blocks
    }

    @concurrent func store(_ block: Data, index: UInt64, file: String) async {
        let fileManager = FileManager.default
        let folder = folder(for: file)
        let isNew = !fileManager.fileExists(atPath: folder.path)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try block.write(to: folder.appendingPathComponent(String(index)), options: .atomic)
        } catch {
            return
        }
        if isNew { pruneOldestDiscs() }
    }

    private func folder(for file: String) -> URL {
        directory.appendingPathComponent(ApplePlaybackIdentity.digest(for: file), isDirectory: true)
    }

    private func pruneOldestDiscs() {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard folders.count > Self.discLimit else { return }
        let byAge = folders.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for folder in byAge.prefix(folders.count - Self.discLimit) { try? fileManager.removeItem(at: folder) }
    }
}

/// What one bridge session read, for the trace and the disc start budget.
struct AppleSMBReadStats: Equatable, Sendable {
    var requests = 0
    var bytesServed: UInt64 = 0
    var cacheHits = 0
    var diskBlocks = 0
    /// SMB file opens: one per read and one per streamed range.
    var smbOpens = 0
    var smbBytes: UInt64 = 0
    /// Whole reads: open, read and close, timed to the last byte.
    var smbReads = 0
    var readMilliseconds = 0
    var slowestReadMilliseconds = 0
    /// Streamed ranges, timed to the first bytes the player can be sent.
    var streams = 0
    var firstByteMilliseconds = 0
    var slowestFirstByteMilliseconds = 0
    /// Set when the share no longer has the file.
    var openFailure: AppleSMBError?

    mutating func recordSMBRead(milliseconds: Int) {
        smbOpens += 1
        smbReads += 1
        readMilliseconds += milliseconds
        slowestReadMilliseconds = max(slowestReadMilliseconds, milliseconds)
    }

    mutating func recordStreamFirstByte(milliseconds: Int) {
        streams += 1
        firstByteMilliseconds += milliseconds
        slowestFirstByteMilliseconds = max(slowestFirstByteMilliseconds, milliseconds)
    }

    /// "312 requests (41.0 MB), 296 from cache, 4 blocks from disk, 17 SMB opens (16.0 MB):
    /// 15 reads avg 58 ms max 120 ms, 2 streams first byte avg 21 ms max 40 ms".
    var traceLine: String {
        let readAverage = smbReads > 0 ? readMilliseconds / smbReads : 0
        let firstByteAverage = streams > 0 ? firstByteMilliseconds / streams : 0
        return "\(requests) requests (\(Self.megabytes(bytesServed))), \(cacheHits) from cache, \(diskBlocks) blocks from disk, "
            + "\(smbOpens) SMB opens (\(Self.megabytes(smbBytes))): "
            + "\(smbReads) reads avg \(readAverage) ms max \(slowestReadMilliseconds) ms, "
            + "\(streams) streams first byte avg \(firstByteAverage) ms max \(slowestFirstByteMilliseconds) ms"
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
