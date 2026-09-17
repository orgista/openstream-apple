import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15, two complaints that turned out to be one decision:
/// *"artwork with word mark and then the work mark is redundant"* and
/// *"the heros don't load the word mark art just text"*.
@Suite("Billboard title treatment")
struct AppleTVBillboardTitleTreatmentTests {
    private typealias T = AppleTVBillboardTitleTreatment
    private let logo = URL(string: "https://example.com/logo.png")!

    @Test func aPosterFallbackDrawsNoTitleBecauseTheArtAlreadyHasOne() {
        // "72 Hours" had no backdrop, so the poster was used — and the poster
        // has the title burned into it.
        #expect(T.choose(hasBackdrop: false, wordmark: nil) == .none)
        // Even with a wordmark available: over a poster it is still a repeat.
        #expect(T.choose(hasBackdrop: false, wordmark: logo) == .none)
    }

    @Test func aBackdropPrefersTheWordmarkOverPlainText() {
        #expect(T.choose(hasBackdrop: true, wordmark: logo) == .wordmark(logo))
    }

    @Test func aBackdropWithNoWordmarkStillNamesTheTitle() {
        // Never leave the viewer with an unlabelled picture.
        #expect(T.choose(hasBackdrop: true, wordmark: nil) == .text)
    }
}
