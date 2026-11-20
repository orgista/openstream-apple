import Foundation
import Testing
@testable import OpenStreamApple

/// WatchConnectivity carries untyped `[String: Any]`, so both sides encode
/// against this shape. A key typo would otherwise fail silently on a device
/// that is awkward to debug.
@Suite("Watch payload")
struct AppleWatchPayloadTests {
    @Test func aPlayingTitleIsCarried() {
        let payload = AppleWatchPayload.context(title: "Jury Duty", isPlaying: true)
        #expect(payload[AppleWatchPayload.titleKey] as? String == "Jury Duty")
        #expect(payload[AppleWatchPayload.isPlayingKey] as? Bool == true)
    }

    /// Nothing playing must omit the title rather than send an empty string —
    /// the watch shows its empty state on a missing key, and a blank
    /// now-playing card on an empty one.
    @Test func nothingPlayingOmitsTheTitle() {
        let payload = AppleWatchPayload.context(title: nil, isPlaying: false)
        #expect(payload[AppleWatchPayload.titleKey] == nil)
        #expect(payload[AppleWatchPayload.isPlayingKey] as? Bool == false)
    }

    @Test func anEmptyTitleIsTreatedAsNothingPlaying() {
        #expect(AppleWatchPayload.context(title: "", isPlaying: false)[AppleWatchPayload.titleKey] == nil)
    }

    // MARK: Commands

    @Test func theWatchCommandsDecode() {
        #expect(AppleWatchPayload.command(in: ["command": "togglePlayPause"]) == .toggle)
        #expect(AppleWatchPayload.command(in: ["command": "skipForward"])
                == .skipForward(AppleRemoteCommand.skipInterval))
        #expect(AppleWatchPayload.command(in: ["command": "skipBackward"])
                == .skipBackward(AppleRemoteCommand.skipInterval))
    }

    /// Anything else is ignored rather than guessed at.
    @Test func unknownPayloadsAreIgnored() {
        #expect(AppleWatchPayload.command(in: [:]) == nil)
        #expect(AppleWatchPayload.command(in: ["command": "selfDestruct"]) == nil)
        #expect(AppleWatchPayload.command(in: ["command": 7]) == nil)
    }

    /// The wrist uses the same skip distance as every other remote.
    @Test func theWatchSkipsTheSameDistanceAsEverythingElse() {
        guard case .skipForward(let offset)? = AppleWatchPayload.command(in: ["command": "skipForward"])
        else { return #expect(Bool(false), "did not decode") }
        #expect(offset == AppleRemoteCommand.skipInterval)
    }
}
