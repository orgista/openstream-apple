import Foundation
import Testing
@testable import OpenStreamApple

/// N54 #14: with sources whose catalog could not be read, Discover said only
/// "Nothing to Show" and offered only Settings.
@Suite("Discover empty state")
struct AppleDiscoverEmptyStateTests {
    @Test("No sources is still No Sources, whatever else failed")
    func noSourcesWins() {
        let state = AppleDiscoverEmptyState(sourceCount: 0, catalogFailureCount: 3, hasSourceError: true)
        #expect(state == .noSources)
        #expect(state.title == "No Sources")
        #expect(state.offersRetry == false)
    }

    @Test(
        "A failed catalog read or an unreadable source says so and offers a reload",
        arguments: [(failures: 1, sourceError: false), (failures: 0, sourceError: true), (failures: 2, sourceError: true)]
    )
    func failureIsNamed(failures: Int, sourceError: Bool) {
        let state = AppleDiscoverEmptyState(sourceCount: 1, catalogFailureCount: failures, hasSourceError: sourceError)
        #expect(state == .couldNotLoad)
        #expect(state.title == "Couldn't Load Your Catalogs")
        #expect(state.offersRetry)
    }

    @Test("Sources that loaded but hold nothing keep Nothing to Show, with no retry")
    func emptyButHealthy() {
        let state = AppleDiscoverEmptyState(sourceCount: 2, catalogFailureCount: 0, hasSourceError: false)
        #expect(state == .nothingToShow)
        #expect(state.title == "Nothing to Show")
        #expect(state.offersRetry == false)
    }

    @Test("With sources, an empty page is loading until their first refresh has finished")
    func loadingUntilSettled() {
        #expect(AppleDiscoverEmptyState.isStillLoading(sourceCount: 2, isLoading: false, hasSettled: false))
        #expect(AppleDiscoverEmptyState.isStillLoading(sourceCount: 2, isLoading: true, hasSettled: true))
        #expect(!AppleDiscoverEmptyState.isStillLoading(sourceCount: 2, isLoading: false, hasSettled: true))
    }

    @Test("No sources is never a loading state", arguments: [false, true])
    func noSourcesIsNotLoading(isLoading: Bool) {
        #expect(!AppleDiscoverEmptyState.isStillLoading(sourceCount: 0, isLoading: isLoading, hasSettled: false))
    }

    @Test("Only No Sources offers Restore from iCloud, and only where iCloud can be reached")
    func iCloudRestoreIsOfferedOnNoSources() {
        #expect(AppleDiscoverEmptyState.noSources.offersICloudRestore(.available))
        #expect(AppleDiscoverEmptyState.noSources.offersICloudRestore(.signedOut))
        #expect(!AppleDiscoverEmptyState.noSources.offersICloudRestore(.notEntitled))
        #expect(!AppleDiscoverEmptyState.couldNotLoad.offersICloudRestore(.available))
        #expect(!AppleDiscoverEmptyState.nothingToShow.offersICloudRestore(.available))
    }
}

@Suite struct AppleDiscoverSourceErrorScopeTests {
    @Test func nonCatalogCredentialFailureDoesNotBecomeCatalogError() {
        let source = AppleSource(kind: .nas, name: "Home Server", url: URL(string: "https://fixture.example/share")!)
        let state = AppleDiscoverEmptyState(sources: [source], catalogFailureCount: 0, hasSourceError: true)
        #expect(state == .nothingToShow)
        #expect(state.offersRetry == false)
    }
    @Test func ignoredSourcesShowWelcomeDespiteCredentialFailure() {
        #expect(AppleDiscoverEmptyState(sources: [], catalogFailureCount: 0, hasSourceError: true) == .noSources)
    }
    #if OPENSTREAM_ADDONS
    @Test func activeCatalogCredentialFailureStillOffersRetry() {
        let source = AppleSource(kind: .stremio, name: "Catalog", url: URL(string: "https://fixture.example/manifest.json")!)
        #expect(AppleDiscoverEmptyState(sources: [source], catalogFailureCount: 0, hasSourceError: true) == .couldNotLoad)
    }
    #endif
}
