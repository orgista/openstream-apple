import Foundation
import Testing
@testable import OpenStreamApple

/// A dead channel is ordinary in a 9376-channel lineup, so failing one must
/// read as information and offer the next channel — not raise a modal quoting
/// libavcodec (owner 2026-09-15: "changed to a channel eventually got to this
/// error", `Demuxer: open failed (Input/output error (-5))`).
@Suite("Live failure presentation")
struct AppleLiveFailurePresentationTests {
    private typealias P = AppleLiveFailurePresentation

    private func failure(_ kind: ApplePlaybackFailure.Kind, _ message: String = "raw") -> ApplePlaybackFailure {
        ApplePlaybackFailure(kind: kind, message: message)
    }

    @Test func theDemuxerStringNeverReachesTheViewer() {
        let raw = "Demuxer: open failed (Input/output error (-5))"
        let shown = P.message(for: failure(.player, raw), channelName: "CBS (EAST)")
        #expect(!shown.contains("Demuxer"))
        #expect(!shown.contains("-5"))
        #expect(shown == "CBS (EAST) is not broadcasting right now.")
    }

    @Test func theChannelIsNamedWhenKnownAndStandsInWhenNot() {
        #expect(P.message(for: failure(.player), channelName: "FOX 5").hasPrefix("FOX 5"))
        #expect(P.message(for: failure(.player), channelName: nil).hasPrefix("This channel"))
    }

    @Test func everyKindGetsOneReadableSentence() {
        for kind in [ApplePlaybackFailure.Kind.authentication, .network, .unsupportedMedia,
                     .unavailable, .player, .timedOut, .sourceEnded, .engineUnavailable] {
            let message = P.message(for: failure(kind), channelName: "HBO")
            #expect(!message.isEmpty)
            #expect(message.hasSuffix("."))
            // One sentence, readable from a sofa.
            #expect(message.count < 90)
        }
    }

    @Test func aCancelledLoadIsNotAFailureTheViewerSees() {
        #expect(!P.isVisible(failure(.cancelled)))
        #expect(P.message(for: failure(.cancelled)).isEmpty)
        #expect(!P.opensChannelStrip(for: failure(.cancelled)))
        // Everything else is worth showing.
        #expect(P.isVisible(failure(.player)))
    }

    @Test func theStripOpensForAnythingAnotherChannelCouldFix() {
        for kind in [ApplePlaybackFailure.Kind.network, .unsupportedMedia, .unavailable,
                     .player, .timedOut, .sourceEnded] {
            #expect(P.opensChannelStrip(for: failure(kind)), "\(kind) should offer the next channel")
        }
    }

    @Test func theStripStaysShutWhenAnotherChannelCannotHelp() {
        // Bad credentials fail identically on every row, and a missing engine
        // is not about this channel at all. Both are answered elsewhere.
        #expect(!P.opensChannelStrip(for: failure(.authentication)))
        #expect(!P.opensChannelStrip(for: failure(.engineUnavailable)))
        #expect(P.message(for: failure(.authentication), channelName: "HBO").contains("username and password"))
    }
}
