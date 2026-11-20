import Foundation
import Testing
@testable import OpenStreamApple

struct AppleAutoPlayChainTests {
    @Test func stopsAtThreeEpisodesOrTwoHoursAndInteractionResets() {
        let start = Date(timeIntervalSince1970: 0)
        var chain = AppleAutoPlayChain(startedAt: start)
        #expect(chain.canAdvance(at: start))
        chain.didAdvance()
        #expect(chain.canAdvance(at: start))
        chain.didAdvance()
        #expect(chain.canAdvance(at: start) == false)
        chain = AppleAutoPlayChain(startedAt: start)
        #expect(chain.canAdvance(at: start.addingTimeInterval(7199)))
        #expect(chain.canAdvance(at: start.addingTimeInterval(7200)) == false)
        chain.interacted(at: start.addingTimeInterval(7200))
        #expect(chain.canAdvance(at: start.addingTimeInterval(7200)))
    }
    @MainActor @Test func handoffCarriesTheCapAndInteractionEnablesAnotherEpisode() {
        var carry = AppleTrackCarryOver.none
        var chain = AppleAutoPlayChain()
        chain.didAdvance()
        chain.didAdvance()
        carry.autoPlayChain = chain
        #expect(carry.isEmpty == false)
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        coordinator.trackCarryOver = carry
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var starts = 0
        model.nextEpisodeTitle = "S1 E4"
        model.nextEpisode = { starts += 1 }
        #expect(coordinator.handsOffAtEnd == false)
        model.apply(.duration(1800))
        model.apply(.position(1795))
        #expect(model.nextEpisodePrompt?.secondsRemaining == 0)
        #expect(starts == 0)
        model.bumpActivity()
        #expect(coordinator.handsOffAtEnd)
        model.apply(.position(1795))
        #expect(starts == 0)
        model.apply(.position(1799.5))
        #expect(starts == 1)
        #expect(coordinator.autoPlayChain.episodes == 2)
    }

    @MainActor @Test func reachingTheCapDoesNotCloseTheHandoffAlreadyStarted() {
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        coordinator.autoPlayChain.didAdvance()
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var starts = 0
        model.nextEpisodeTitle = "S1 E3"
        model.nextEpisode = { starts += 1 }
        model.apply(.duration(1800))
        model.apply(.position(1795))
        #expect(starts == 0)
        model.apply(.position(1799.5))
        #expect(starts == 1)
        #expect(coordinator.autoPlayChain.episodes == 3)
        model.apply(.position(1799.6))
        #expect(coordinator.handsOffAtEnd)
        model.apply(.phase(.ended))
        #expect(coordinator.handsOffAtEnd)
        #expect(starts == 1)
    }

}
