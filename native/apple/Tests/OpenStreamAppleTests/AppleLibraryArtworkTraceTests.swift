import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Cold library artwork trace")
@MainActor
struct AppleLibraryArtworkTraceTests {
    @Test(.timeLimit(.minutes(1))) func measuresShownPostersAndPlaceholderDeadlines() async {
        let clock = ManualClock()
        var records: [String] = []
        let trace = AppleLibraryArtworkTrace(clock: clock) { records.append($0) }
        let first = UUID(), second = UUID(), third = UUID()
        trace.start()
        trace.updateCatalogIDs(["first", "second", "third"])
        trace.cardAppeared(UUID(), catalogID: "unrelated-server-card", hasPoster: true)
        trace.cardAppeared(first, catalogID: "first", hasPoster: false)
        trace.cardAppeared(second, catalogID: "second", hasPoster: false)
        await clock.waitForSleep(until: .seconds(10))
        clock.advance(by: .seconds(2))
        trace.posterShown(first)
        trace.posterShown(first)
        let duplicate = UUID()
        trace.cardAppeared(duplicate, catalogID: "first", hasPoster: true)
        #expect(records == ["cold-library scan-start", "cold-library first-poster scan_ms=2000"])
        clock.advance(to: .seconds(10))
        await clock.waitForSleep(until: .seconds(30))
        #expect(records.last == "cold-library checkpoint seconds=10 scan_ms=10000 cards=3 placeholders=1")
        trace.cardDisappeared(second)
        trace.cardDisappeared(duplicate)
        trace.cardAppeared(third, catalogID: "third", hasPoster: false)
        clock.advance(to: .seconds(30))
        await waitFor("30-second snapshot") { records.count == 4 }
        #expect(records.last == "cold-library checkpoint seconds=30 scan_ms=30000 cards=2 placeholders=1")
        #expect(!trace.isActive)
        #expect(clock.pendingSleepers == 0)
    }

    @Test(.timeLimit(.minutes(1))) func stopsAtThirtySecondsWithoutAnyPoster() async {
        let clock = ManualClock()
        var records: [String] = []
        let trace = AppleLibraryArtworkTrace(clock: clock) { records.append($0) }
        let card = UUID()
        trace.start()
        trace.updateCatalogIDs(["placeholder"])
        trace.cardAppeared(card, catalogID: "placeholder", hasPoster: false)
        await clock.waitForSleep(until: .seconds(10))
        clock.advance(to: .seconds(10))
        await clock.waitForSleep(until: .seconds(30))
        #expect(records.last == "cold-library checkpoint seconds=10 scan_ms=10000 cards=1 placeholders=1")
        clock.advance(to: .seconds(30))
        await waitFor("final placeholder sample") { records.count == 3 }
        #expect(records.last == "cold-library checkpoint seconds=30 scan_ms=30000 cards=1 placeholders=1")
        #expect(!trace.isActive)
        trace.posterShown(card)
        #expect(records.count == 3)
        #expect(clock.pendingSleepers == 0)
    }

    @Test(.timeLimit(.minutes(1))) func resetCancelsOldDeadlinesAndMemoryHitsCountAsShown() async {
        let clock = ManualClock()
        var records: [String] = []
        let trace = AppleLibraryArtworkTrace(clock: clock) { records.append($0) }
        trace.start()
        await clock.waitForSleep(until: .seconds(10))
        trace.stop()
        clock.advance(to: .seconds(10))
        trace.start()
        trace.updateCatalogIDs(["cached"])
        trace.cardAppeared(UUID(), catalogID: "cached", hasPoster: true)
        await clock.waitForSleep(until: .seconds(20))
        #expect(records == ["cold-library scan-start", "cold-library scan-start", "cold-library first-poster scan_ms=0"])
        trace.stop()
        await waitFor("cancelled snapshots") { clock.pendingSleepers == 0 }
    }
}
