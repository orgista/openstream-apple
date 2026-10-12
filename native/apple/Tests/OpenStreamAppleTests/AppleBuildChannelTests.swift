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

@Suite struct AppleTestCatalogSeedPolicyTests {
    /// TestFlight, App Review and the App Store all run Release archives; App
    /// Review's carries the same sandbox receipt as TestFlight. None of them
    /// may start with a catalog the user did not add.
    private static let fixture = ["https://fixture.example/aiometadata/manifest.json"]

    @Test func releaseBuildsNeverSeedWhateverTheReceipt() {
        #expect(!AppleTestCatalogSeedPolicy.seedsTestCatalogs(isDebugBuild: false))
        #expect(AppleTestCatalogSeedPolicy.manifests(isDebugBuild: false, devSourceManifests: Self.fixture).isEmpty)
    }

    /// A debug build seeds exactly the dev-sources add-ons it was given; the
    /// addresses themselves are never compiled in.
    @Test func debugBuildsSeedTheDevSourcesCatalogs() {
        #expect(AppleTestCatalogSeedPolicy.seedsTestCatalogs(isDebugBuild: true))
        #expect(AppleTestCatalogSeedPolicy.manifests(isDebugBuild: true, devSourceManifests: Self.fixture) == Self.fixture)
        #expect(AppleTestCatalogSeedPolicy.manifests(isDebugBuild: true, devSourceManifests: []).isEmpty)
    }

    /// The store follows the policy for the build it was compiled in (tests
    /// run as DEBUG).
    @MainActor @Test func storeFollowsThePolicyForThisBuild() {
        #expect(AppleTestCatalogSeedPolicy.isDebugBuild)
        #expect(AppleSourceStore.seedsTestCatalogs == AppleTestCatalogSeedPolicy.seedsTestCatalogs(isDebugBuild: true))
        #expect(AppleSourceStore.testCatalogManifests == AppleTestCatalogSeedPolicy.manifests(
            isDebugBuild: true, devSourceManifests: AppleTestCatalogSeedPolicy.debugManifests))
    }
}

@Suite struct AppleTraceDefaultTests {
    @Test func sandboxReceiptTracesUnlessTheBuildSaysOtherwise() {
        #expect(AppleInteractionTrace.defaultEnabled(infoPlistFlag: nil, isTestFlight: true))
        #expect(!AppleInteractionTrace.defaultEnabled(infoPlistFlag: false, isTestFlight: true))
    }

    @Test func appStoreStaysOffUnlessTheBuildTurnsItOn() {
        #expect(!AppleInteractionTrace.defaultEnabled(infoPlistFlag: nil, isTestFlight: false))
        #expect(AppleInteractionTrace.defaultEnabled(infoPlistFlag: true, isTestFlight: false))
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
        #expect(AppleDiscoverEmptyState.couldNotLoad.footnote == nil)
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
        #expect(AppleAttribution.sourceCodeDisplay == "github.com/orgista/openstream-apple")
    }
}
