import Foundation
import Testing
@testable import OpenStreamApple

#if canImport(CoreSpotlight) && !os(tvOS)
private actor SpotlightFixture: AppleSpotlightStoring {
    var ids: [String] = []
    var exports: [[String]] = []
    var blocked: CheckedContinuation<Void, Never>?
    var entered = false
    func deleteAll() { ids = [] }
    func index(_ records: [AppleMediaRecord]) async {
        entered = true
        await withCheckedContinuation { blocked = $0 }
        ids = records.map(\.id)
        exports.append(ids)
    }
    func release() { blocked?.resume(); blocked = nil }
}

@Test func spotlightFiltersPrivateRecordsAndOptOutWinsOverAnInFlightExport() async throws {
    let fixture = SpotlightFixture()
    let indexer = AppleSpotlightIndexer(store: fixture)
    let source = UUID()
    let availability: [AppleMediaAvailability] = [.init(instanceID: source, capability: .resolvable, itemReference: "movie|tt1234567")]
    let visible = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Public", availability: availability)
    let hidden = AppleMediaRecord(canonicalID: "tt7654321", kind: .movie, title: "Private", availability: availability, isPrivate: true)
    let first = Task { await indexer.synchronize(records: [visible, hidden], enabled: true) }
    for _ in 0..<200 { if await fixture.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await fixture.entered)
    let disabled = Task { await indexer.synchronize(records: [visible], enabled: false) }
    await fixture.release()
    await first.value
    await disabled.value
    #expect(await fixture.exports == [[visible.id]])
    #expect(await fixture.ids.isEmpty)
}
#endif
