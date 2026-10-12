import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Play requests resolve once")
struct ApplePlayRequestLedgerTests {
    @Test func aRequestResolvesExactlyOnce() {
        var ledger = ApplePlayRequestLedger()
        let press = UUID()
        let r1 = ledger.consume(press)
        #expect(r1)
        // The page reappears (tab switch) and the task reruns with the same id.
        let r2 = ledger.consume(press)
        #expect(!r2)
        let r3 = ledger.consume(press)
        #expect(!r3)
    }

    @Test func noRequestNeverResolves() {
        var ledger = ApplePlayRequestLedger()
        let r4 = ledger.consume(nil)
        #expect(!r4)
    }

    @Test func aNewPressResolvesAgain() {
        var ledger = ApplePlayRequestLedger()
        let first = UUID(), second = UUID()
        let r5 = ledger.consume(first)
        #expect(r5)
        let r6 = ledger.consume(second)
        #expect(r6)
        let r7 = ledger.consume(second)
        #expect(!r7)
        #expect(ledger.consumed == second)
    }

    @Test func initialAutoPlayFiresOncePerPage() {
        var ledger = ApplePlayRequestLedger()
        let r8 = ledger.takeInitialAutoPlay(true)
        #expect(r8)
        let r9 = ledger.takeInitialAutoPlay(true)
        #expect(!r9)
        #expect(ledger.initialAutoPlayFired)
    }

    @Test func aPageThatDoesNotAutoPlayNeverDoes() {
        var ledger = ApplePlayRequestLedger()
        let r10 = ledger.takeInitialAutoPlay(false)
        #expect(!r10)
        #expect(!ledger.initialAutoPlayFired)
    }
}

@Suite("One-shot requests run once")
struct AppleOneShotRequestLedgerTests {
    @Test func aConnectPressRunsOnceAcrossReappears() {
        var ledger = AppleOneShotRequestLedger()
        let press = UUID()
        let first = ledger.consume(press)
        let reappear = ledger.consume(press)
        let next = ledger.consume(UUID())
        #expect(first)
        #expect(!reappear)
        #expect(next)
    }
}

@Suite("Series progress needs an episode")
struct AppleSeriesProgressGuardTests {
    private let suiteName = "series-progress-guard-tests.\(UUID())"

    @MainActor
    private func makeStore() throws -> (ApplePlaybackStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (ApplePlaybackStore(defaults: defaults), defaults)
    }

    @Test func episodeIdentity() {
        #expect(AppleSeriesProgressGuard.namesEpisode("tt0108778:1:2"))
        #expect(!AppleSeriesProgressGuard.namesEpisode("tt0108778"))
        #expect(!AppleSeriesProgressGuard.namesEpisode(nil))
    }

    @Test func decision() {
        let episode = ApplePlaybackProgress(position: 600, duration: 1_300, partID: "tt0108778:1:2")
        let film = ApplePlaybackProgress(position: 600, duration: 6_000, partID: nil)
        #expect(!AppleSeriesProgressGuard.mayOverwrite(existing: episode, with: "tt0108778"))
        #expect(!AppleSeriesProgressGuard.mayOverwrite(existing: episode, with: nil))
        #expect(AppleSeriesProgressGuard.mayOverwrite(existing: episode, with: "tt0108778:9:3"))
        #expect(AppleSeriesProgressGuard.mayOverwrite(existing: film, with: nil))
        #expect(AppleSeriesProgressGuard.mayOverwrite(existing: nil, with: "tt0108778"))
    }

    @MainActor @Test func aShowWidePlayDoesNotWipeTheEpisodeResume() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.save(mediaID: "fixture-series", position: 600, duration: 1_300, partID: "fixture-series:1:2")
        // The replayed request: the whole show, no season or episode.
        store.save(mediaID: "fixture-series", position: 40, duration: 1_300,
                   partID: AppleDetailResume.partID(type: "series", mediaID: "fixture-series"))
        store.save(mediaID: "fixture-series", position: 1_300, duration: 1_300, partID: nil)
        #expect(store.progress(for: "fixture-series")?.resumePosition(for: "fixture-series:1:2") == 600)
    }

    @MainActor @Test func anotherEpisodeStillReplacesIt() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.save(mediaID: "fixture-series", position: 600, duration: 1_300, partID: "fixture-series:1:2")
        store.save(mediaID: "fixture-series", position: 300, duration: 1_300, partID: "fixture-series:1:3")
        #expect(store.progress(for: "fixture-series")?.partID == "fixture-series:1:3")
    }
}

