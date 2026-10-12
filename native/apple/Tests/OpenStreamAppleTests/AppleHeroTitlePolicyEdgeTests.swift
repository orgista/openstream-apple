import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases for `AppleHeroTitlePolicy` (N62 wordmark hold, N63 lookup
/// hold, N64 per-page lookup) that `AppleHeroQualityTests.swift` does not
/// cover: the default-argument path for the name latch, a wordmark reported
/// as both loaded and failed, a timed-out wordmark whose lookup is still
/// marked pending, and empty/ignored inputs.
@Suite("Hero title policy: latch defaults, contradictory reports, ignored inputs")
struct AppleHeroTitlePolicyEdgeTests {
    private let mark = URL(string: "https://fixture.example/logo.png")!

    /// The main suite always pairs `nameShown: true` with an explicit
    /// `lookupPending: true`. The latch must win with the plain defaults too.
    @Test func nameShownWinsWithNoOtherArgumentsSupplied() {
        #expect(AppleHeroTitlePolicy.presentation(wordmark: nil, loaded: nil, failed: nil, graceExpired: false, nameShown: true) == .name)
        #expect(AppleHeroTitlePolicy.presentation(wordmark: nil, loaded: nil, failed: nil, graceExpired: true, nameShown: true) == .name)
    }

    /// A mark reported as both the one that loaded and the one that failed
    /// is a contradictory caller report; the failure check runs first in
    /// the source, so it must win either way.
    @Test func aMarkReportedAsBothLoadedAndFailedIsTreatedAsFailed() {
        #expect(AppleHeroTitlePolicy.presentation(wordmark: mark, loaded: mark, failed: mark, graceExpired: false) == .name)
        #expect(AppleHeroTitlePolicy.presentation(wordmark: mark, loaded: mark, failed: mark, graceExpired: true) == .name)
    }

    /// Once a wordmark is known but has not loaded by the grace, a lookup
    /// still marked pending does not rescue it: `lookupPending` only gates
    /// the branch where there is no wordmark yet.
    @Test func aTimedOutWordmarkIsNotRescuedByAStillPendingLookup() {
        let presentation = AppleHeroTitlePolicy.presentation(
            wordmark: mark, loaded: nil, failed: nil, graceExpired: true, lookupPending: true
        )
        #expect(presentation == .name)
        #expect(presentation.wordmarkURL == nil)
    }

    /// `wordmarkLookupPending` treats an empty media id like any other id:
    /// nothing special about the empty string as a set key.
    @Test func wordmarkLookupPendingToleratesAnEmptyMediaID() {
        #expect(AppleHeroTitlePolicy.wordmarkLookupPending(mediaID: "", resolved: [], wordmarkFailed: false))
        #expect(!AppleHeroTitlePolicy.wordmarkLookupPending(mediaID: "", resolved: [""], wordmarkFailed: false))
        #expect(!AppleHeroTitlePolicy.wordmarkLookupPending(mediaID: "", resolved: [], wordmarkFailed: true))
    }

    /// With no wordmark at all, `graceExpired` alone does not draw the name
    /// unless the lookup is also not pending — the main suite only checks
    /// this with `graceExpired: false`; the `true` side must agree.
    @Test func aNilWordmarkWithNoPendingLookupAlwaysDrawsTheNameRegardlessOfGrace() {
        #expect(AppleHeroTitlePolicy.presentation(wordmark: nil, loaded: nil, failed: nil, graceExpired: false, lookupPending: false) == .name)
        #expect(AppleHeroTitlePolicy.presentation(wordmark: nil, loaded: nil, failed: nil, graceExpired: true, lookupPending: false) == .name)
    }

    /// When there is no current wordmark, `failed` describes a stale or
    /// unrelated report and must be ignored entirely — the slot still holds
    /// while its own lookup runs.
    @Test func aFailedURLIsIgnoredWhenThereIsNoCurrentWordmarkToMatchIt() {
        let presentation = AppleHeroTitlePolicy.presentation(
            wordmark: nil, loaded: nil, failed: mark, graceExpired: false, lookupPending: true
        )
        #expect(presentation == .holding)
    }
}
