import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Recent searches")
struct AppleRecentSearchesTests {
    @Test func newestFirstAndCappedAtTen() {
        var recents: [String] = []
        for index in 1 ... 12 { recents = AppleRecentSearchPolicy.recording("title \(index)", in: recents) }
        #expect(recents.count == AppleRecentSearchPolicy.limit)
        #expect(recents.first == "title 12")
        #expect(recents.last == "title 3")
    }

    @Test func repeatingASearchMovesItToTheFront() {
        var recents = ["matrix", "alien", "heat"]
        recents = AppleRecentSearchPolicy.recording("Alien", in: recents)
        #expect(recents == ["Alien", "matrix", "heat"])
    }

    @Test func keystrokesOnTheWayToAQueryAreCollapsed() {
        var recents: [String] = []
        for typed in ["ma", "mat", "matr", "matrix"] { recents = AppleRecentSearchPolicy.recording(typed, in: recents) }
        #expect(recents == ["matrix"])
    }

    @Test func whitespaceAndSingleCharactersAreNotSearches() {
        #expect(AppleRecentSearchPolicy.recording("   ", in: ["heat"]) == ["heat"])
        #expect(AppleRecentSearchPolicy.recording("m", in: ["heat"]) == ["heat"])
        #expect(AppleRecentSearchPolicy.normalized("  the   matrix  ") == "the matrix")
    }

    @Test @MainActor func storePersistsAndClears() throws {
        let suite = "recent-searches-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppleRecentSearchStore(defaults: defaults)
        store.record("matrix")
        store.record("alien")
        #expect(AppleRecentSearchStore(defaults: defaults).recents == ["alien", "matrix"])
        store.clear()
        #expect(store.recents.isEmpty)
        #expect(defaults.stringArray(forKey: AppleRecentSearchStore.storageKey) == nil)
    }
}
