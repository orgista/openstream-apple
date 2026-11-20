import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite struct ApplePlaybackStartupTests {
    @Test func connectionFeedbackBelongsToTheCurrentAttempt() {
        let startup = ApplePlaybackStartup()
        let first = UUID()
        startup.begin(first)
        #expect(startup.showsConnectionStatus == false)
        #expect(startup.showConnectionStatus(for: first))
        #expect(startup.showsConnectionStatus)
        startup.begin(UUID())
        #expect(startup.showsConnectionStatus == false)
        #expect(startup.showConnectionStatus(for: first) == false)
        startup.cancel()
        #expect(startup.showsConnectionStatus == false)
    }

    @Test(arguments: ApplePlaybackPresentationRoute.allCases)
    func handoffKeepsTheIndicatorUntilAFrame(_ route: ApplePlaybackPresentationRoute) {
        let startup = ApplePlaybackStartup()
        let press = UUID()
        startup.begin(press)
        #expect(startup.isLoading)
        startup.handOff()
        for phase: ApplePlaybackPhase in [.idle, .resolving, .loading, .waiting(nil)] {
            startup.observe(phase, route: route, readyForDisplay: false, for: press)
            #expect(startup.isLoading)
            #expect(startup.requestID == press)
        }
        startup.observe(.playing, route: route, readyForDisplay: false, for: press)
        #expect(startup.isLoading == (route != .audioOnly))
        startup.observe(.playing, route: route, readyForDisplay: true, for: press)
        #expect(startup.isLoading == (route == .none))
    }

    @Test func stockPlaybackFinishesOnTheDisplayedFrameBeforeTransportPlays() {
        let startup = ApplePlaybackStartup(starting: true)
        let press = startup.requestID
        startup.observe(.loading, route: .avPlayer, readyForDisplay: false, for: press)
        #expect(startup.isLoading)
        startup.observe(.loading, route: .avPlayer, readyForDisplay: true, for: press)
        #expect(startup.hasPresentedFrame)
        startup.observe(.playing, route: .avPlayer, readyForDisplay: false, for: press)
        #expect(startup.hasPresentedFrame)
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: press)
        #expect(!startup.isLoading)
        startup.observe(.waiting(nil), route: .none, readyForDisplay: false, for: press)
        #expect(!startup.isLoading)
    }

    @Test(arguments: [ApplePlaybackPresentationRoute.avPlayer, .surface])
    func aDecodedFrameFinishesBufferingStartup(_ route: ApplePlaybackPresentationRoute) {
        let startup = ApplePlaybackStartup(starting: true)
        startup.observe(.waiting(nil), route: route, readyForDisplay: true, for: startup.requestID)
        #expect(startup.hasPresentedFrame)
        #expect(startup.coversPicture(phase: .waiting(nil)) == false)
    }

    @Test func resolvingCannotPresentAnOutgoingFrame() {
        let startup = ApplePlaybackStartup()
        startup.begin(UUID())
        startup.observe(.resolving, route: .avPlayer, readyForDisplay: true, for: startup.requestID)
        #expect(startup.isLoading)
        #expect(startup.hasPresentedFrame == false)
    }

    @Test func aPausedFirstFrameAlsoFinishesStartup() {
        let startup = ApplePlaybackStartup(starting: true)
        startup.observe(.paused, route: .avPlayer, readyForDisplay: false, for: startup.requestID)
        #expect(startup.isLoading)
        startup.observe(.paused, route: .avPlayer, readyForDisplay: true, for: startup.requestID)
        #expect(!startup.isLoading)
    }

    @Test func reconnectingBeforeTheFirstFrameKeepsTheInitialPresentation() {
        let startup = ApplePlaybackStartup(starting: true)
        let press = startup.requestID
        startup.observe(.playing, route: .avPlayer, readyForDisplay: false, for: press)
        startup.observe(.waiting(nil), route: .avPlayer, readyForDisplay: false, for: press)
        #expect(startup.isLoading)
        #expect(!startup.hasPresentedFrame)
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: press)
        startup.observe(.waiting(nil), route: .avPlayer, readyForDisplay: false, for: press)
        #expect(startup.hasPresentedFrame)
        startup.begin(UUID())
        #expect(!startup.hasPresentedFrame)
    }

    @Test func fallbackThroughNoRouteKeepsTheSameIndicator() {
        let startup = ApplePlaybackStartup(starting: true)
        let press = startup.requestID
        for route: ApplePlaybackPresentationRoute in [.avPlayer, .none, .surface] {
            startup.observe(.loading, route: route, readyForDisplay: false, for: press)
            #expect(startup.isLoading)
            #expect(startup.requestID == press)
        }
        startup.observe(.playing, route: .surface, readyForDisplay: true, for: press)
        #expect(!startup.isLoading)
    }

    @Test func failureAndCancellationReleaseThePresentation() {
        let startup = ApplePlaybackStartup()
        startup.begin(UUID())
        startup.observe(.failed(.init(kind: .unavailable, message: "Unavailable")),
                        route: .none, readyForDisplay: false, for: startup.requestID)
        #expect(!startup.isLoading)
        #expect(startup.requestID == nil)
        startup.begin(UUID())
        startup.cancel()
        #expect(!startup.isLoading)
        #expect(startup.requestID == nil)
    }

    @Test func aPreviousPlayerCannotFinishOrCancelANewPress() {
        let startup = ApplePlaybackStartup(starting: true)
        let previous = startup.requestID
        let current = UUID()
        startup.begin(current)
        startup.handOff()
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: previous)
        startup.observe(.failed(.init(kind: .cancelled, message: "Cancelled")),
                        route: .none, readyForDisplay: false, for: previous)
        #expect(startup.isLoading)
        #expect(startup.requestID == current)
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: current)
        #expect(!startup.isLoading)
    }

    @Test func aTitlePressStartsAndCancellationClosesThePendingCover() {
        var page = AppleTitlePagePlaybackState()
        let coordinator = ApplePlaybackCoordinator()
        coordinator.beginResolving()
        let request = UUID()
        page.request = request
        #expect(page.startup.requestID == request)
        #expect(page.startup.resolutionID == request)
        #expect(page.startup.needsPresentation(hasPlayer: false))
        page.startup.cancel()
        page.resetCancelledStartup(coordinator)
        #expect(coordinator.phase == .idle)
        #expect(page.startup.resolutionID == nil)
        #expect(!page.startup.needsPresentation(hasPlayer: false))
        #expect(page.startup.isPresented)
        page.startup.presentationDidDismiss()
        #expect(!page.startup.isPresented)
    }

    @Test func aResolutionFailureSurvivesCoverCancellationForTheAlert() {
        var page = AppleTitlePagePlaybackState()
        let coordinator = ApplePlaybackCoordinator()
        page.request = UUID()
        let failure = ApplePlaybackFailure(kind: .unavailable, message: "Unavailable")
        coordinator.fail(failure)
        page.startup.cancel()
        page.resetCancelledStartup(coordinator)
        #expect(coordinator.phase == .failed(failure))
        #expect(page.startup.isPresented)
        page.startup.presentationDidDismiss()
        #expect(!page.startup.isPresented)
        #expect(coordinator.phase == .failed(failure))
    }

    @Test func aRequestlessHandoffHasAnIdentityAndKeepsTheCover() {
        let startup = ApplePlaybackStartup()
        startup.handOff()
        #expect(startup.requestID != nil)
        #expect(startup.needsPresentation(hasPlayer: false))
        startup.observe(.playing, route: .surface, readyForDisplay: true, for: startup.requestID)
        #expect(startup.needsPresentation(hasPlayer: true))
        #expect(!startup.needsPresentation(hasPlayer: false))
    }

    @Test func rebufferKeepsThePictureAndOnlyChangesTheIndicator() {
        let startup = ApplePlaybackStartup(starting: true)
        #expect(startup.coversPicture(phase: .loading))
        #expect(!startup.showsReconnecting(true))
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: startup.requestID)
        for phase: ApplePlaybackPhase in [.waiting(nil), .loading, .resolving, .idle] {
            startup.observe(phase, route: .avPlayer, readyForDisplay: false, for: startup.requestID)
            #expect(!startup.coversPicture(phase: phase))
            #expect(startup.showsReconnecting(true))
        }
        #expect(startup.coversPicture(phase: .waiting(nil), isClosing: true))
    }

    @Test func timeoutKeepsAnErrorCoverAndRetryStartsAFreshRequest() async {
        let startup = ApplePlaybackStartup()
        let first = UUID()
        startup.begin(first)
        #expect(await startup.waitForTimeout(for: first, after: .zero))
        #expect(startup.phase == .timedOut)
        #expect(!startup.isLoading)
        #expect(startup.resolutionID == nil)
        #expect(startup.needsPresentation(hasPlayer: false))
        let retry = UUID()
        startup.begin(retry)
        #expect(!startup.timeOut(for: first))
        #expect(startup.resolutionID == retry)
        startup.handOff()
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: retry)
        #expect(!startup.timeOut(for: retry))
        #expect(startup.hasPresentedFrame)
    }

    @Test func cancellationPreventsAStaleTimeoutOrFrameFromReopeningTheCover() {
        let startup = ApplePlaybackStartup(starting: true)
        let request = startup.requestID
        startup.cancel()
        #expect(!startup.timeOut(for: request))
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: request)
        #expect(!startup.needsPresentation(hasPlayer: false))
    }

    @Test(arguments: [ApplePlaybackPresentationRoute.avPlayer, .surface])
    func aLateFirstFrameReplacesTheTimeoutCover(_ route: ApplePlaybackPresentationRoute) {
        let startup = ApplePlaybackStartup(starting: true)
        let request = startup.requestID
        #expect(startup.timeOut(for: request))
        startup.observe(.playing, route: route, readyForDisplay: false, for: request)
        #expect(startup.phase == .timedOut)
        startup.observe(.playing, route: route, readyForDisplay: true, for: request)
        #expect(startup.hasPresentedFrame)
        #expect(!startup.coversPicture(phase: .playing))
        #expect(!startup.timeOut(for: request))
    }

    @Test func aPausedLateFramePresentsButAnOldRequestCannotReplaceARetry() {
        let startup = ApplePlaybackStartup(starting: true)
        let previous = startup.requestID
        #expect(startup.timeOut(for: previous))
        startup.observe(.paused, route: .avPlayer, readyForDisplay: true, for: previous)
        #expect(startup.hasPresentedFrame)
        let retry = UUID()
        startup.begin(retry)
        #expect(startup.timeOut(for: retry))
        startup.observe(.playing, route: .avPlayer, readyForDisplay: true, for: previous)
        #expect(startup.phase == .timedOut)
        startup.observe(.paused, route: .surface, readyForDisplay: true, for: retry)
        #expect(startup.hasPresentedFrame)
    }

}
