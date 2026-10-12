import Foundation
import Testing
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import OpenStreamApple

/// Edge cases the happy-path suite (`AppleHomeDesignPolicyTests`) does not
/// cover: enum equality, the invariant tying the ownership flags together,
/// and the suppression script's defensive branches (missing session, a
/// session missing `setActionHandler`, the empty-script no-op path, and
/// repeated installation across navigations within the same frame).
@Suite("Playback session policy edge cases")
struct ApplePlaybackSessionPolicyEdgeTests {
    @Test func trailerAndPlaybackAreDistinctAndSelfEqual() {
        #expect(ApplePlaybackSessionPolicy.trailer == ApplePlaybackSessionPolicy.trailer)
        #expect(ApplePlaybackSessionPolicy.playback == ApplePlaybackSessionPolicy.playback)
        #expect(ApplePlaybackSessionPolicy.trailer != ApplePlaybackSessionPolicy.playback)
    }

    /// The three system-ownership flags never disagree: a case either owns
    /// now-playing and remote commands and allows unmuted web audio, or it
    /// owns none of them and requires muting.
    @Test("Now-playing, remote commands and muting never disagree",
          arguments: [ApplePlaybackSessionPolicy.trailer, .playback])
    func ownershipFlagsAgree(_ policy: ApplePlaybackSessionPolicy) {
        #expect(policy.publishesNowPlaying == policy.registersRemoteCommands)
        #expect(policy.requiresMutedWebPlayback != policy.publishesNowPlaying)
    }

    #if canImport(JavaScriptCore)
    @Test("Trailer script names every media session action it clears",
          arguments: ["play", "pause", "stop", "seekbackward", "seekforward",
                      "seekto", "previoustrack", "nexttrack"])
    func trailerScriptListsEveryAction(_ action: String) {
        #expect(ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript.contains("'\(action)'"))
    }

    /// If a provider iframe never sets up `navigator.mediaSession` at all,
    /// the script's own `if (!session) return;` guard must stop it quietly
    /// instead of throwing on the frame's `document.addEventListener` calls.
    @Test func trailerScriptToleratesAMissingMediaSession() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var navigator = {}; var document = {addEventListener: () => {}};")
        context.evaluateScript(ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript)
        #expect(context.exception == nil)
    }

    /// Some pages only implement part of the Media Session API. Optional
    /// chaining on a missing `setActionHandler` must not throw, and the
    /// direct property writes must still take effect.
    @Test func trailerScriptToleratesAMediaSessionWithoutSetActionHandler() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var document = {addEventListener: () => {}};
        var navigator = {mediaSession: {metadata: {title: 'Fixture'}, playbackState: 'playing'}};
        """)
        context.evaluateScript(ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("navigator.mediaSession.metadata === null")?.toBool() == true)
        #expect(context.evaluateScript("navigator.mediaSession.playbackState === 'none'")?.toBool() == true)
    }

    /// The script is installed at document start in every frame, including
    /// re-navigations within the same frame, so running it a second time
    /// must stay a no-op rather than throwing when it tries to redefine
    /// properties it already made non-configurable the first time.
    @Test func trailerScriptIsSafeToInstallTwice() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var handlers = {play: () => {}};
        var events = {};
        var document = {addEventListener: (name, callback) => { events[name] = callback; }};
        var navigator = {mediaSession: {
          metadata: {title: 'Fixture'}, playbackState: 'playing',
          setActionHandler: (name, handler) => { handlers[name] = handler; },
          setPositionState: () => {}
        }};
        """)
        let script = ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript
        context.evaluateScript(script)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("navigator.mediaSession.metadata === null")?.toBool() == true)
        #expect(context.evaluateScript("Object.values(handlers).every(handler => handler === null)")?.toBool() == true)
    }

    /// `.playback`'s script is the empty string; evaluating it must be a
    /// true no-op and never touch an existing media session.
    @Test func playbackScriptIsANoOpAgainstAnExistingSession() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var navigator = {mediaSession: {metadata: {title: 'Fixture'}, playbackState: 'playing'}};
        """)
        context.evaluateScript(ApplePlaybackSessionPolicy.playback.webMediaSessionSuppressionScript)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("navigator.mediaSession.metadata.title")?.toString() == "Fixture")
        #expect(context.evaluateScript("navigator.mediaSession.playbackState")?.toString() == "playing")
    }
    #endif
}
