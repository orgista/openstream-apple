import Testing
@testable import OpenStreamApple

/// Owner 2026-11-04: Rill read "Connected · 0 titles" while its rows were full.
@Suite("Media server title count")
struct AppleMediaServerTitleCountTests {
    @Test func libraryTitlesNoRowHasLoadedStillCount() {
        #expect(AppleMediaServerTitleCount.titles(indexed: 0, libraries: [(total: 120, loaded: 0)]) == 120)
    }

    @Test func loadedTitlesAreNotCountedTwice() {
        #expect(AppleMediaServerTitleCount.titles(indexed: 70, libraries: [(total: 120, loaded: 50), (total: 30, loaded: 30)]) == 140)
    }

    @Test func aRowHoldingMoreThanTheReportedTotalAddsNothing() {
        #expect(AppleMediaServerTitleCount.titles(indexed: 25, libraries: [(total: 20, loaded: 25)]) == 25)
    }
}
