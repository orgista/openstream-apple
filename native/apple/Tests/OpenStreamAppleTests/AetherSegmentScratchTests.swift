import Darwin
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AetherSegmentScratch")
struct AetherSegmentScratchTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeSession(_ name: String, marker: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: dir.appendingPathComponent("seg-0.m4s"))
        if marker {
            try Data().write(to: dir.appendingPathComponent(AetherSegmentScratch.liveMarkerName))
        }
        return dir
    }

    /// Holds the marker the way a live SegmentCache does, on its own open file description.
    private func holdMarker(of dir: URL) throws -> Int32 {
        let fd = open(dir.appendingPathComponent(AetherSegmentScratch.liveMarkerName).path, O_RDWR)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    private func remaining() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    @Test("launch sweep removes dead and unmarked folders, spares a held one")
    func launchSweep() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession("dead", marker: true)
        _ = try makeSession("dvr-ring", marker: false)
        let live = try makeSession("live", marker: true)
        let fd = try holdMarker(of: live)
        defer { close(fd) }

        let removed = AetherSegmentScratch.sweep(directory: root, createdBefore: Date().addingTimeInterval(60),
                                                 removesUnmarked: true)

        #expect(Set(removed) == ["dead", "dvr-ring"])
        #expect(remaining() == ["live"])
        #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("seg-0.m4s").path))
    }

    @Test("after-playback sweep keeps unmarked folders another playback may own")
    func afterPlaybackSweep() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession("dead", marker: true)
        _ = try makeSession("dvr-ring", marker: false)

        let removed = AetherSegmentScratch.sweep(directory: root, createdBefore: Date().addingTimeInterval(60),
                                                 removesUnmarked: false)

        #expect(removed == ["dead"])
        #expect(remaining() == ["dvr-ring"])
    }

    @Test("folders made after the cutoff are never touched")
    func newerThanCutoff() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cutoff = Date().addingTimeInterval(-60)
        _ = try makeSession("dead", marker: true)
        _ = try makeSession("dvr-ring", marker: false)

        let removed = AetherSegmentScratch.sweep(directory: root, createdBefore: cutoff, removesUnmarked: true)

        #expect(removed.isEmpty)
        #expect(remaining() == ["dead", "dvr-ring"])
    }

    @Test("a released marker reads as unheld, a held one as held")
    func markerState() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeSession("s", marker: true)
        #expect(AetherSegmentScratch.markerState(dir) == .unheld)
        let fd = try holdMarker(of: dir)
        #expect(AetherSegmentScratch.markerState(dir) == .held)
        close(fd)
        #expect(AetherSegmentScratch.markerState(dir) == .unheld)
        #expect(AetherSegmentScratch.markerState(root.appendingPathComponent("absent")) == .missing)
    }

    @Test("a missing scratch directory is a no-op")
    func missingDirectory() {
        let removed = AetherSegmentScratch.sweep(directory: root.appendingPathComponent("nope"),
                                                 createdBefore: Date(), removesUnmarked: true)
        #expect(removed.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}
