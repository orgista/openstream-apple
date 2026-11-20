import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import AVFoundation
#endif

/// Previews never own the system transport controls or long-form audio session.
enum ApplePlaybackSessionPolicy: Equatable, Sendable {
    case trailer
    case playback

    enum AudioCategory: Equatable, Sendable { case ambient, playback }
    var audioCategory: AudioCategory { self == .trailer ? .ambient : .playback }
    var publishesNowPlaying: Bool { self == .playback }
    var registersRemoteCommands: Bool { self == .playback }
    // WebKit can publish its automatic audible-media session without JS metadata.
    var requiresMutedWebPlayback: Bool { self == .trailer }

    func shouldRestoreAudioSession(hasPlaybackRequest: Bool) -> Bool {
        self == .playback && hasPlaybackRequest
    }

    @MainActor static var activeAudioPolicy: Self? {
        didSet { audioPolicyGeneration &+= 1 }
    }
    @MainActor private static var audioPolicyGeneration: UInt64 = 0

    /// Long-form playback takes the session. The generation bump in `activeAudioPolicy`'s observer
    /// voids any trailer completion still queued from before the claim. Keep the returned claim for
    /// `releasePlaybackAudio`.
    @MainActor static func claimPlaybackAudio() -> UInt64 {
        activeAudioPolicy = .playback
        return audioPolicyGeneration
    }

    /// False when a later claim or a pressed trailer took the session since: a player torn down after the
    /// next one started must not hand that one's session back.
    @MainActor static func releasePlaybackAudio(_ claim: UInt64?) -> Bool {
        guard let claim, claim == audioPolicyGeneration, activeAudioPolicy == .playback else { return false }
        activeAudioPolicy = nil
        return true
    }

    /// An autoplaying preview never takes the session from long-form playback. The Discover hero's
    /// start task can still fire during the switch to Live; its `.ambient` session then replaced the
    /// channel's `.playback` one as the player loaded, and the first tune played with its sound off
    /// the picture until another channel claimed the session again (owner trace 2026-10-21).
    /// A pressed trailer is the viewer's choice and still takes it.
    @MainActor static func trailerMayTakeAudioSession(pressed: Bool) -> Bool {
        guard pressed || activeAudioPolicy != .playback else {
            appleTrace("trailer audio left to playback")
            return false
        }
        return true
    }

    /// Returns once preparation is queued; activation failures are reported in the trace.
    @MainActor static func prepareTrailerAudio(
        workQueue: AppleAudioSessionWorkQueue = .shared,
        pressed: Bool = false,
        activate: @escaping @Sendable () throws -> Void
    ) {
        guard trailerMayTakeAudioSession(pressed: pressed) else { return }
        // Required before enqueue: a second back-to-back call must invalidate
        // this one, or the older completion could apply after the newer.
        audioPolicyGeneration &+= 1
        let generation = audioPolicyGeneration
        appleTrace("trailer audio preparing")
        // Pending long-form preparation/deactivation must finish before takeover.
        workQueue.enqueue {
            do {
                try activate()
                Task { @MainActor in
                    // A newer playback request or teardown owns any later policy change.
                    guard audioPolicyGeneration == generation else { return }
                    activeAudioPolicy = .trailer
                    appleTrace("trailer audio prepared")
                }
            } catch {
                appleTraceFailure("trailer audio unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Waits for the session to be ready; false when activation failed or was cancelled. True without
    /// touching the session when long-form playback keeps it: the muted preview still plays.
    @MainActor static func prepareTrailerAudioAwaiting(
        workQueue: AppleAudioSessionWorkQueue = .shared,
        pressed: Bool = false,
        activate: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        guard trailerMayTakeAudioSession(pressed: pressed) else { return true }
        audioPolicyGeneration &+= 1
        let generation = audioPolicyGeneration
        appleTrace("trailer audio preparing")
        do {
            try await workQueue.perform(activate)
        } catch {
            appleTraceFailure("trailer audio unavailable: \(error.localizedDescription)")
            return false
        }
        if audioPolicyGeneration == generation {
            activeAudioPolicy = .trailer
            appleTrace("trailer audio prepared")
        }
        return true
    }

    /// `.ambient` mixes with other apps' audio and follows the silent switch; only a pressed trailer
    /// takes `.playback`.
    static func trailerAudioCategory(pressed: Bool) -> AudioCategory {
        pressed ? .playback : trailer.audioCategory
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// `pressed` is an explicit "Play Trailer": it takes `.playback` instead
    /// of the trailer's usual `.ambient`, so the silent switch does not mute
    /// the sound the viewer just asked for. Autoplay never passes it — an
    /// unrequested preview must stay silenceable exactly as the ringer
    /// switch expects.
    @MainActor static func prepareTrailerAudio(pressed: Bool = false) {
        prepareTrailerAudio(pressed: pressed, activate: trailerSessionWork(pressed: pressed))
    }

    /// Same session work, but the caller starts a player right after, so it waits.
    @MainActor static func prepareTrailerAudioAwaiting(pressed: Bool = false) async -> Bool {
        await prepareTrailerAudioAwaiting(pressed: pressed, activate: trailerSessionWork(pressed: pressed))
    }

    private static func trailerSessionWork(pressed: Bool) -> @Sendable () throws -> Void {
        {
            let session = AVAudioSession.sharedInstance()
            let category: AVAudioSession.Category = trailerAudioCategory(pressed: pressed) == .ambient ? .ambient : .playback
            try session.setCategory(category, mode: .default, options: [])
            #if os(visionOS)
            try session.setIsNowPlayingCandidate(Self.trailer.publishesNowPlaying)
            #endif
            try session.setActive(true)
        }
    }
    #endif
}
