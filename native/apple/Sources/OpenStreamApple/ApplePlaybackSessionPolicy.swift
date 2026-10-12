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

    /// Installed at document start in every frame, including the provider iframe.
    /// WebKit's automatic audio behavior is separately constrained by ambient audio.
    var webMediaSessionSuppressionScript: String {
        guard !publishesNowPlaying, !registersRemoteCommands else { return "" }
        return """
        (() => {
          const session = navigator.mediaSession;
          if (!session) return;
          const attempt = (action) => { try { action(); } catch (_) {} };
          const setActionHandler = session.setActionHandler?.bind(session);
          const actions = ['play', 'pause', 'stop', 'seekbackward', 'seekforward',
                           'seekto', 'previoustrack', 'nexttrack'];
          const clear = () => {
            attempt(() => { session.metadata = null; });
            attempt(() => { session.playbackState = 'none'; });
            for (const action of actions) attempt(() => setActionHandler?.(action, null));
          };
          clear();
          attempt(() => Object.defineProperty(session, 'metadata', {get: () => null, set: () => {}}));
          attempt(() => Object.defineProperty(session, 'playbackState', {get: () => 'none', set: () => {}}));
          attempt(() => Object.defineProperty(session, 'setActionHandler', {
            value: (action) => { attempt(() => setActionHandler?.(action, null)); }
          }));
          attempt(() => Object.defineProperty(session, 'setPositionState', {value: () => {}}));
          document.addEventListener('play', clear, true);
          document.addEventListener('playing', clear, true);
        })();
        """
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @MainActor static var activeAudioPolicy: Self?

    /// `pressed` is an explicit "Play Trailer": it takes `.playback` instead
    /// of the trailer's usual `.ambient`, so the silent switch does not mute
    /// the sound the viewer just asked for. Autoplay never passes it — an
    /// unrequested preview must stay silenceable exactly as the ringer
    /// switch expects.
    @MainActor static func prepareTrailerAudio(pressed: Bool = false) -> Bool {
        let policy = Self.trailer
        let session = AVAudioSession.sharedInstance()
        do {
            // Drain pending long-form preparation/deactivation before taking over.
            // Otherwise that queued work can overwrite ambient after this returns.
            try AppleAudioSessionWorkQueue.shared.performSynchronously {
                let category: AVAudioSession.Category = pressed
                    ? .playback
                    : (policy.audioCategory == .ambient ? .ambient : .playback)
                try session.setCategory(category, mode: .default, options: [])
                #if os(visionOS)
                try session.setIsNowPlayingCandidate(policy.publishesNowPlaying)
                #endif
                try session.setActive(true)
            }
            activeAudioPolicy = policy
            return true
        } catch {
            appleTraceFailure("trailer audio unavailable: \(error.localizedDescription)")
            return false
        }
    }
    #endif
}
