import Foundation
import AetherEngine
import Testing
@testable import OpenStreamApple

@Suite struct ApplePlaybackFailureRecoveryTests {
    private func recovery(_ kind: ApplePlaybackFailure.Kind) -> ApplePlaybackFailureRecovery {
        ApplePlaybackFailureRecovery(ApplePlaybackFailure(kind: kind, message: "x"))
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.network, .timedOut, .player, .sourceEnded, .storageFull])
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

    /// A failure the no-data simulator produced in the crawl: a title whose
    /// every source was ruled out.
    @Test func noUsableSourceIsNotRetryable() {
        let allRuledOut = ApplePlaybackFailure.classify(AppleLibrarySourceError.noMedia)
        #expect(allRuledOut.kind == .unavailable)
        #expect(allRuledOut.message == AppleLibrarySourceError.noMedia.localizedDescription)
        #expect(ApplePlaybackFailureRecovery(allRuledOut) == .sources)
    }

    /// Apple TV 2026-11-08: a 4K NAS title filled the Apple TV with segment files. Before or after the first
    /// frame, that is the device's storage, not the NAS file, so nothing falls back or blames the source.
    @MainActor @Test(arguments: [false, true])
    func fullDeviceIsStorageNotThePlayer(hasReachedPlaying: Bool) {
        let info = PlaybackErrorInfo(kind: .insufficientStorage,
                                     message: "Not enough free storage on this device to play this video",
                                     underlyingCode: -28)
        let failure = AetherPlaybackEngine.classify(info, hasReachedPlaying: hasReachedPlaying)
        #expect(failure.kind == .storageFull)
        #expect(failure.userMessage == ApplePlaybackFailure.storageFullMessage)
        #expect(ApplePlaybackFailureRecovery(failure) == .retry)
    }

    @Test(arguments: zip(
        [AppleSMBError.invalidHost, .invalidPort, .invalidShare, .unavailableOnPlatform,
         .authenticationFailed, .accessDenied, .serverUnreachable, .connectionFailed, .notFound],
        [ApplePlaybackFailure.Kind.unavailable, .unavailable, .unavailable, .unavailable,
         .authentication, .authentication, .network, .network, .unavailable]))
    func shareFailuresKeepTheirActionableReason(error: AppleSMBError, kind: ApplePlaybackFailure.Kind) {
        let failure = ApplePlaybackFailure.classify(error)
        #expect(failure.kind == kind)
        #expect(failure.userMessage == error.localizedDescription)
    }

    @Test func rejectedAccountIsNotRetryable() {
        let rejected = ApplePlaybackFailure.classify(AppleIPTVError.requestFailed(401))
        #expect(ApplePlaybackFailureRecovery(rejected) == .sources)
    }

    @Test func unreachableServerIsRetryable() {
        let timedOut = ApplePlaybackFailure.classify(URLError(.timedOut))
        #expect(ApplePlaybackFailureRecovery(timedOut) == .retry)

        let serverError = ApplePlaybackFailure.classify(AppleIPTVError.requestFailed(503))
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
