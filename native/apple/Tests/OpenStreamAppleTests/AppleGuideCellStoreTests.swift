import Foundation
import Testing
@testable import OpenStreamApple

/// The owner's lineup is 9376 channels. Building the grid for all of them to
/// draw the fifteen rows a television shows is what kept the Live tab slow
/// after the per-row rebuild was removed (2026-09-14).
@Suite("Guide cell store")
@MainActor
struct AppleGuideCellStoreTests {
    private let window = DateInterval(start: Date(timeIntervalSince1970: 3600), duration: 7200)

    private func guide(channels: Int) -> AppleIPTVGuide {
        AppleIPTVGuide(programmes: (0 ..< channels).map { index in
            AppleIPTVProgramme(id: "p\(index)", channelID: "ch\(index)", title: "Show \(index)",
                subtitle: nil, description: nil,
                start: Date(timeIntervalSince1970: 3600), end: Date(timeIntervalSince1970: 7200),
                category: nil, isLive: false)
        })
    }

    private func configured(_ store: AppleGuideCellStore, token: String = "a", channels: Int = 9376) {
        store.configure(token: token, guide: guide(channels: channels), window: window,
            now: Date(timeIntervalSince1970: 3600), slotMinutes: 30)
    }

    @Test func onlyTheChannelsAskedForAreBuilt() {
        let store = AppleGuideCellStore()
        configured(store)
        #expect(store.builtChannelCount == 0)
        for index in 0 ..< 15 { _ = store.cells(for: "ch\(index)") }
        #expect(store.builtChannelCount == 15)
    }

    @Test func aSecondAskIsServedFromTheCache() {
        let store = AppleGuideCellStore()
        configured(store)
        let first = store.cells(for: "ch7")
        let second = store.cells(for: "ch7")
        #expect(first == second)
        #expect(store.builtChannelCount == 1)
    }

    @Test func aNewWindowDropsWhatWasBuilt() {
        let store = AppleGuideCellStore()
        configured(store)
        _ = store.cells(for: "ch1")
        #expect(store.builtChannelCount == 1)
        configured(store, token: "b")
        #expect(store.builtChannelCount == 0)
        #expect(!store.headerSlots.isEmpty)
    }

    @Test func reconfiguringWithTheSameTokenKeepsTheCache() {
        let store = AppleGuideCellStore()
        configured(store)
        _ = store.cells(for: "ch1")
        configured(store)
        #expect(store.builtChannelCount == 1)
    }

    @Test func aChannelWithNoProgrammesStillFillsItsRow() {
        let store = AppleGuideCellStore()
        configured(store, channels: 1)
        let cells = store.cells(for: "ch-missing")
        #expect(!cells.isEmpty)
        #expect(cells.allSatisfy { $0.title == "No information" })
    }
}
