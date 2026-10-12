import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct ApplePlaybackFailureRecoveryTests {
    private func recovery(_ kind: ApplePlaybackFailure.Kind) -> ApplePlaybackFailureRecovery {
        ApplePlaybackFailureRecovery(ApplePlaybackFailure(kind: kind, message: "x"))
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.network, .timedOut, .player, .sourceEnded])
    func failuresThatCanEndDifferentlyOfferRetry(kind: ApplePlaybackFailure.Kind) {
        #expect(recovery(kind) == .retry)
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.unavailable, .unsupportedMedia, .authentication])
    func failuresThatRepeatUntilASourceChangesOfferSources(kind: ApplePlaybackFailure.Kind) {
        #expect(recovery(kind) == .sources)
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.engineUnavailable, .cancelled])
    func failuresNobodyCanFixFromTheTitlePageOfferOnlyClose(kind: ApplePlaybackFailure.Kind) {
        #expect(recovery(kind) == .closeOnly)
    }

    /// The failures the no-data simulator produced in the crawl: a catalog
    /// with no stream add-on, and a title whose every source was ruled out.
    @Test func noStreamSourceIsNotRetryable() {
        let noStreams = ApplePlaybackFailure.classify(AppleStremioPlaybackResolutionError.noStreams)
        #expect(ApplePlaybackFailureRecovery(noStreams) == .sources)

        let noCompatible = ApplePlaybackFailure.classify(AppleStremioPlaybackResolutionError.noCompatibleHTTPStream)
        #expect(ApplePlaybackFailureRecovery(noCompatible) == .sources)

        let allRuledOut = ApplePlaybackFailure.classify(AppleLibrarySourceError.noMedia)
        #expect(allRuledOut.kind == .unavailable)
        #expect(allRuledOut.message == AppleLibrarySourceError.noMedia.localizedDescription)
        #expect(ApplePlaybackFailureRecovery(allRuledOut) == .sources)
    }

    @Test func rejectedAccountIsNotRetryable() {
        let rejected = ApplePlaybackFailure.classify(AppleStremioPlaybackError.requestFailed(401))
        #expect(ApplePlaybackFailureRecovery(rejected) == .sources)
    }

    @Test func unreachableServerIsRetryable() {
        let timedOut = ApplePlaybackFailure.classify(URLError(.timedOut))
        #expect(ApplePlaybackFailureRecovery(timedOut) == .retry)

        let serverError = ApplePlaybackFailure.classify(AppleStremioPlaybackError.requestFailed(503))
        #expect(ApplePlaybackFailureRecovery(serverError) == .retry)
    }

    @Test func retryKeepsItsLoadingStateForTheMinimumBeforeANewFailure() {
        let minimum = ApplePlaybackFailureRecovery.retryFeedbackMinimum
        #expect(minimum > .zero)
        #expect(ApplePlaybackFailureRecovery.remainingRetryFeedback(elapsed: .zero) == minimum)
        #expect(ApplePlaybackFailureRecovery.remainingRetryFeedback(elapsed: .milliseconds(250))
            == minimum - .milliseconds(250))
        #expect(ApplePlaybackFailureRecovery.remainingRetryFeedback(elapsed: minimum) == .zero)
        #expect(ApplePlaybackFailureRecovery.remainingRetryFeedback(elapsed: .seconds(30)) == .zero)
    }
}
