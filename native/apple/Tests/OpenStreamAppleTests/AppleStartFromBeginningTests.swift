import Foundation
import Testing
@testable import OpenStreamApple

/// Owner decision 2026-10-01: beside Resume, "Start from Beginning" plays
/// the film or episode from 0:00; Remove from Continue Watching keeps progress.
@Suite struct AppleStartFromBeginningTests {
    @Test(arguments: [AppleTitlePagePolicy.PrimaryAction.resume(episode: nil), .resume(episode: "S4, E8")])
    func offeredBesideResume(_ action: AppleTitlePagePolicy.PrimaryAction) {
        #expect(AppleTitlePagePolicy.offersStartFromBeginning(action))
    }

    @Test(arguments: [AppleTitlePagePolicy.PrimaryAction.play, .playEpisode("S1, E3"), .playTrailer, .details])
    func notOfferedWithoutAResume(_ action: AppleTitlePagePolicy.PrimaryAction) {
        #expect(!AppleTitlePagePolicy.offersStartFromBeginning(action))
    }

    @Test func notOfferedWithNoButton() {
        #expect(!AppleTitlePagePolicy.offersStartFromBeginning(nil))
    }

    @Test func startsAtTheTopOnlyWhenAsked() {
        #expect(AppleTitlePagePolicy.startPosition(saved: 1_234, fromBeginning: true) == nil)
        #expect(AppleTitlePagePolicy.startPosition(saved: 1_234, fromBeginning: false) == 1_234)
        #expect(AppleTitlePagePolicy.startPosition(saved: nil, fromBeginning: false) == nil)
    }
}
