import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleBuildChannelTests {
    @Test func sandboxReceiptIsRecognised() {
        #expect(AppleBuildChannel.isSandboxReceipt("sandboxReceipt"))
    }

    @Test func appStoreReceiptAndNoReceiptAreNotSandbox() {
        #expect(!AppleBuildChannel.isSandboxReceipt("receipt"))
        #expect(!AppleBuildChannel.isSandboxReceipt(nil))
    }
}

@Suite struct AppleAttributionTests {
    @Test func tmdbLogoShipsInTheBundle() {
        #expect(AppleTMDBAttributionRow.logo != nil)
    }

    /// No Sources carries the no-content statement (behind its (i)); the other
    /// empty states carry nothing.
    @Test func noSourcesCarriesTheNoContentStatement() {
        #expect(AppleDiscoverEmptyState.noSources.footnote == AppleAttribution.noContentDisclaimer)
        #expect(AppleDiscoverEmptyState.nothingToShow.footnote == nil)
    }

    /// The exact wording the (i) sheet shows: TMDB's required sentence,
    /// JustWatch's credit, and the no-content line.
    @Test func infoSheetLinesAreTheRequiredOnes() {
        #expect(AppleAttribution.tmdbNotice == "This product uses the TMDB API but is not endorsed or certified by TMDB.")
        #expect(AppleAttribution.justWatchCredit == "Streaming availability data by JustWatch")
        #expect(AppleAttribution.noContentDisclaimer == "oStream doesn't provide any content. Add your own sources.")
    }

    /// About links the public repository (the origin remote).
    @Test func aboutLinksTheOriginRepository() {
        #expect(AppleAttribution.sourceCodeURL.absoluteString == "https://github.com/orgista/openstream-apple")
    }
}
