import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleDetailReadinessTests {
    @Test
    func titleLogoFallsBackToTextWhenTheWordmarkFailsToLoad() {
        // Validated, then the image fetch failed: the text title has to appear
        // so the hero is not left empty.
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: false, elapsed: 0)
                == .text
        )
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: true, elapsed: 0)
                == .logo
        )
        // No wordmark at all: text straight away, no grace period.
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: false, loadResult: nil, elapsed: 0)
                == .text
        )
    }

    @Test
    func titleLogoShowsNothingForTheFirstSecondThenTheTextTitle() {
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: nil, loadResult: nil, elapsed: 0)
                == .hidden
        )
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: nil, elapsed: 0.9)
                == .hidden
        )
        // Owner 2026-09-14 widened the grace from one second to three, so a
        // slow wordmark is waited for instead of flashing text and back.
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: nil, elapsed: 2)
                == .hidden
        )
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: nil, loadResult: nil, elapsed: 3)
                == .text
        )
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: nil, elapsed: 4)
                == .text
        )
        // A wordmark that arrives inside the grace window never flashes text.
        #expect(
            AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: true, elapsed: 0.5)
                == .logo
        )
    }

    @Test
    func canonicalMovieIsPlayableWithoutWaitingForIdentifierResolution() {
        #expect(ApplePlayGatingPolicy.canonicalMediaID("tt1234567") == "tt1234567")
        #expect(ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: "tt1234567") == false)
        #expect(ApplePlayGatingPolicy.requiresIdentifierResolution(mediaID: "tt1234567") == false)

        #expect(ApplePlayGatingPolicy.canonicalMediaID("rt:movie-123") == nil)
        #expect(ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: "rt:movie-123"))
        #expect(ApplePlayGatingPolicy.requiresIdentifierResolution(mediaID: "rt:movie-123"))
    }

    @Test
    func seriesDefaultsToTheFirstEpisodeOfTheFirstSeason() {
        let episodes = [
            AppleStremioEpisode(id: "tt1234567:2:1", title: "Later", season: 2, episode: 1),
            AppleStremioEpisode(id: "tt1234567:1:2", title: "Second", season: 1, episode: 2),
            AppleStremioEpisode(id: "tt1234567:1:1", title: "Pilot", season: 1, episode: 1),
        ]
        #expect(ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes) == "tt1234567:1:1")
        #expect(ApplePlayGatingPolicy.defaultEpisodeID(episodes: []) == nil)
    }

    @Test
    func reselectingTheCurrentTabPopsItToRoot() {
        #expect(OpenStreamTabReselection.popsToRoot(current: .home, selected: .home))
        #expect(OpenStreamTabReselection.popsToRoot(current: .library, selected: .library))
        #expect(OpenStreamTabReselection.popsToRoot(current: .home, selected: .library) == false)
        #expect(OpenStreamTabReselection.popsToRoot(current: .settings, selected: .live) == false)
    }
}
