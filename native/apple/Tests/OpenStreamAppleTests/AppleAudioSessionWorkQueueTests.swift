import Foundation
import Testing
@testable import OpenStreamApple

/// Serialized: every test here reads and writes the one shared session policy.
@MainActor @Suite(.serialized) struct AppleAudioSessionPolicyTests {
    init() { ApplePlaybackSessionPolicy.activeAudioPolicy = nil }

    @Test func audioSessionWorkRunsOffMainAndPreservesActivationOrder() async throws {
        let queue = AppleAudioSessionWorkQueue()
        let recorder = AudioWorkRecorder()
        queue.enqueue { recorder.append("activate") }
        queue.enqueue { recorder.append("deactivate") }
        try await queue.perform { recorder.append("reactivate") }
        #expect(recorder.values == ["activate", "deactivate", "reactivate"])
        #expect(!recorder.usedMainThread)
    }

    @Test func trailerAudioPreparationReturnsBeforePendingAudioWorkCompletes() async throws {
        let queue = AppleAudioSessionWorkQueue()
        let recorder = AudioWorkRecorder()
        let blocked = DispatchSemaphore(value: 0)
        queue.enqueue {
            // Model a two-second mediaserverd wait already occupying the audio queue.
            _ = blocked.wait(timeout: .now() + 2)
            recorder.append("pending playback")
        }

        let clock = ContinuousClock()
        let start = clock.now
        ApplePlaybackSessionPolicy.prepareTrailerAudio(workQueue: queue) {
            recorder.append("trailer")
        }
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .milliseconds(50))
        #expect(recorder.values.isEmpty)

        try await queue.perform { recorder.append("subsequent playback") }
        #expect(recorder.values == ["pending playback", "trailer", "subsequent playback"])
        #expect(recorder.usedMainThread == false)
    }

    /// Owner trace 2026-10-21: Live claimed `.playback` before "play COMEDY CENTRAL" (67.614 s), the
    /// Discover hero's autoplay trailer asked for its session 5 ms later and had `.ambient` active at
    /// 67.699 s, and the channel started at 69.016 s under it, with its sound off the picture.
    @Test func anAutoplayTrailerLeavesLongFormPlaybackItsAudioSession() async throws {
        let queue = AppleAudioSessionWorkQueue()
        let recorder = AudioWorkRecorder()
        _ = ApplePlaybackSessionPolicy.claimPlaybackAudio()
        ApplePlaybackSessionPolicy.prepareTrailerAudio(workQueue: queue) { recorder.append("autoplay trailer") }
        let awaited = await ApplePlaybackSessionPolicy.prepareTrailerAudioAwaiting(workQueue: queue) {
            recorder.append("awaited autoplay trailer")
        }
        #expect(awaited)
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == .playback)

        _ = await ApplePlaybackSessionPolicy.prepareTrailerAudioAwaiting(workQueue: queue, pressed: true) {
            recorder.append("pressed trailer")
        }
        #expect(recorder.values == ["pressed trailer"])
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == .trailer)
    }

    /// The other order: the trailer's session work is queued first and Live claims while it waits.
    /// The work still runs, ahead of Live's own, but its completion must not mark the session the trailer's.
    @Test func aLiveClaimVoidsATrailerQueuedBeforeIt() async throws {
        let queue = AppleAudioSessionWorkQueue()
        let recorder = AudioWorkRecorder()
        let gate = DispatchSemaphore(value: 0)
        queue.enqueue { gate.wait() }
        let trailer = Task { await ApplePlaybackSessionPolicy.prepareTrailerAudioAwaiting(workQueue: queue) {
            recorder.append("trailer")
        } }
        await Task.yield()
        _ = ApplePlaybackSessionPolicy.claimPlaybackAudio()
        gate.signal()

        #expect(await trailer.value)
        // Queued, so it asked before the claim; the guard would have refused it after.
        #expect(recorder.values == ["trailer"])
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == .playback)
    }

    @Test func afterLiveStopsAnAutoplayTrailerIsAmbientAgain() async throws {
        let queue = AppleAudioSessionWorkQueue()
        let recorder = AudioWorkRecorder()
        let claim = ApplePlaybackSessionPolicy.claimPlaybackAudio()
        #expect(ApplePlaybackSessionPolicy.releasePlaybackAudio(claim))
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == nil)

        let prepared = await ApplePlaybackSessionPolicy.prepareTrailerAudioAwaiting(workQueue: queue) {
            recorder.append("autoplay trailer")
        }
        #expect(prepared)
        #expect(recorder.values == ["autoplay trailer"])
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == .trailer)
        // `.ambient` mixes with other apps' audio instead of interrupting it.
        #expect(ApplePlaybackSessionPolicy.trailerAudioCategory(pressed: false) == .ambient)
        #expect(ApplePlaybackSessionPolicy.trailerAudioCategory(pressed: true) == .playback)
    }

    /// A player torn down after the next one claimed (a channel switch, Live after a movie) must not
    /// release the newer player's session.
    @Test func aStaleReleaseKeepsTheNewerClaim() {
        let first = ApplePlaybackSessionPolicy.claimPlaybackAudio()
        let second = ApplePlaybackSessionPolicy.claimPlaybackAudio()
        #expect(!ApplePlaybackSessionPolicy.releasePlaybackAudio(first))
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == .playback)
        #expect(ApplePlaybackSessionPolicy.releasePlaybackAudio(second))
        #expect(ApplePlaybackSessionPolicy.activeAudioPolicy == nil)
        #expect(!ApplePlaybackSessionPolicy.releasePlaybackAudio(nil))
    }
}

private final class AudioWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var main = false
    var values: [String] { lock.withLock { storage } }
    var usedMainThread: Bool { lock.withLock { main } }
    func append(_ value: String) { lock.withLock { storage.append(value); main = main || Thread.isMainThread } }
}
