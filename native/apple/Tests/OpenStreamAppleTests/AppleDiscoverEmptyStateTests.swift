import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Discover empty state")
struct AppleDiscoverEmptyStateTests {
    @Test("No sources is No Sources")
    func noSourcesWins() {
        let state = AppleDiscoverEmptyState(sourceCount: 0)
        #expect(state == .noSources)
        #expect(state.title == "No Sources")
    }

    @Test("Sources that loaded but hold nothing keep Nothing to Show")
    func emptyButHealthy() {
        let state = AppleDiscoverEmptyState(sourceCount: 2)
        #expect(state == .nothingToShow)
        #expect(state.title == "Nothing to Show")
    }

    @Test("With sources, an empty page is loading until their first refresh has finished")
    func loadingUntilSettled() {
        #expect(AppleDiscoverEmptyState.isStillLoading(sourceCount: 2, hasSettled: false))
        #expect(!AppleDiscoverEmptyState.isStillLoading(sourceCount: 2, hasSettled: true))
    }

    @Test("No sources is never a loading state", arguments: [false, true])
    func noSourcesIsNotLoading(hasSettled: Bool) {
        #expect(!AppleDiscoverEmptyState.isStillLoading(sourceCount: 0, hasSettled: hasSettled))
    }

    @Test("Only No Sources offers Restore from iCloud, and only where iCloud can be reached")
    func iCloudRestoreIsOfferedOnNoSources() {
        #expect(AppleDiscoverEmptyState.noSources.offersICloudRestore(.available))
        #expect(AppleDiscoverEmptyState.noSources.offersICloudRestore(.signedOut))
        #expect(!AppleDiscoverEmptyState.noSources.offersICloudRestore(.notEntitled))
        #expect(!AppleDiscoverEmptyState.nothingToShow.offersICloudRestore(.available))
    }
}
