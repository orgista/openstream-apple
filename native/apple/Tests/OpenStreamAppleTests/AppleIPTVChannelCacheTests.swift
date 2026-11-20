import Foundation
import Testing
@testable import OpenStreamApple

/// The Live tab re-fetched all 9376 of the owner's channels on every launch —
/// 2137 ms before the guide could draw anything (2026-09-15). The saved copy
/// is what makes the tab open at once.
@Suite("Live channel cache")
struct AppleIPTVChannelCacheTests {
    private func makeCache() -> (AppleIPTVChannelCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openstream-channel-cache-\(UUID().uuidString)", isDirectory: true)
        return (AppleIPTVChannelCache(directory: directory), directory)
    }

    private func channel(_ id: String, source: UUID) -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: source, name: "Channel \(id)", group: "News",
                         streamURL: URL(string: "https://fixture.example/\(id).ts")!)
    }

    @Test func aStoredLineupComesBack() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = UUID()
        let channels = (0 ..< 50).map { channel("ch\($0)", source: source) }

        await cache.store(channels, for: source)
        let snapshot = await cache.snapshot(for: source)
        #expect(snapshot?.channels.count == 50)
        #expect(snapshot?.channels.first?.name == "Channel ch0")
        #expect(snapshot?.channels.first?.streamURL.absoluteString == "https://fixture.example/ch0.ts")
    }

    @Test func nothingComesBackForASourceNeverStored() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await cache.snapshot(for: UUID()) == nil)
    }

    /// Never store an empty list: a provider that answered with nothing must
    /// not wipe a good lineup.
    @Test func anEmptyAnswerIsNotStored() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = UUID()
        await cache.store([channel("ch1", source: source)], for: source)
        await cache.store([], for: source)
        #expect(await cache.snapshot(for: source)?.channels.count == 1)
    }

    @Test func staleIsReportedButTheLineupIsStillThere() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = UUID()
        let stored = Date().addingTimeInterval(-13 * 60 * 60)
        await cache.store([channel("ch1", source: source)], for: source, now: stored)
        let snapshot = await cache.snapshot(for: source)
        #expect(snapshot?.isStale() == true)
        #expect(snapshot?.channels.isEmpty == false)
    }

    @Test func aFreshLineupIsNotStale() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = UUID()
        await cache.store([channel("ch1", source: source)], for: source)
        #expect(await cache.snapshot(for: source)?.isStale() == false)
    }

    /// A removed provider must not leave megabytes of channels behind.
    @Test func retainDropsSourcesThatAreGone() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = UUID(), dropped = UUID()
        await cache.store([channel("a", source: kept)], for: kept)
        await cache.store([channel("b", source: dropped)], for: dropped)

        await cache.retain([kept])
        #expect(await cache.snapshot(for: kept) != nil)
        #expect(await cache.snapshot(for: dropped) == nil)
    }
}
