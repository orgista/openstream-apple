import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Active billboard title policy")
struct AppleTVBillboardTitleTreatmentTests {
    @Test func posterFallbackStillNamesTheTitle() {
        #expect(AppleHeroTitlePolicy.presentation(wordmark: nil, loaded: nil, failed: nil, graceExpired: false) == .name)
    }

    @Test func readyBackdropWordmarkWins() throws {
        let logo = try #require(URL(string: "https://fixture.example/logo.png"))
        #expect(AppleHeroTitlePolicy.presentation(wordmark: logo, loaded: logo, failed: nil, graceExpired: false) == .wordmark(logo))
    }

    @Test func detailAndHomeKeepTheSameGraceAndStickyFallback() throws {
        #expect(AppleTitleLogoPolicy.loadingGrace == AppleHeroTitlePolicy.loadingGrace)
        let logo = try #require(URL(string: "https://fixture.example/logo.png"))
        #expect(AppleHeroTitlePolicy.presentation(wordmark: logo, loaded: logo, failed: nil, graceExpired: true, nameShown: true) == .name)
        #expect(!AppleTitleLogoPolicy.keepsLoadResult(true, shown: .text))
    }
}
