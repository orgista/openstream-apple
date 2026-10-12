import Foundation

/// Who draws the film's own captions while the picture is somewhere the
/// app's cue layer cannot follow: a Picture in Picture window, an AirPlay
/// receiver, a wired external screen.
///
/// On the Mac, iPhone and Vision the default engine's loopback item carries
/// no legible renditions while the picture is in the app, so AVKit shows no
/// captions button and lists no phantom rows ("English 2", "English 3"), and
/// the app's cue layer is the one on-screen renderer (N38). PiP and AirPlay
/// only draw what the item itself carries, though, so an MKV's captions went
/// blank there. The handoff puts the renditions on the item for exactly as
/// long as the picture is away — a session-preserving reload that turns the
/// engine's `prepareNativeSubtitles` on — has the engine select the one
/// matching the viewer's track, and takes them off again with a second reload
/// when the picture comes back (N42).
///
/// Pure: the engine feeds it the picture's whereabouts, the rendered track
/// and each reload's outcome, and performs the actions it returns in order.
struct AppleCaptionHandoff: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// The item has no renditions; the app's cue layer draws.
        case app
        /// A reload adding the renditions is in flight.
        case declaring
        /// The renditions are on the item; AVKit draws the selected one.
        case native
        /// A reload taking them off again is in flight.
        case withdrawing
    }

    enum Action: Equatable, Sendable {
        /// Rebuild the session at the playhead with renditions on or off.
        case reload(declaringRenditions: Bool)
        /// Select (true) or deselect (false) the rendition matching the
        /// engine's active track (`AetherEngine.setNativeSubtitleRendering`).
        case nativeRendering(Bool)
    }

    private(set) var stage: Stage = .app
    private(set) var pictureIsAway = false
    /// The active track when it is one the engine can serve as a rendition
    /// (`wantedTrack(activeTrackID:tracks:)`), else nil.
    private(set) var wantedTrackID: Int?
    /// What the last `.nativeRendering` asked for, while `.native`.
    private(set) var renderedTrackID: Int?
    /// A declaring reload failed (including the one retried after a failed
    /// withdraw). Not retried until the picture comes back, so a session
    /// that cannot be rebuilt is not rebuilt on every tick.
    private(set) var declineUntilPictureReturns = false

    /// Whether the app's cue layer should draw. Never while the picture is
    /// away: the Mac's player shows AVKit's "playing in Picture in Picture"
    /// placeholder there, and the iPhone the AirPlay one, and cues over a
    /// placeholder are cues over nothing.
    var appDrawsCaptions: Bool { !pictureIsAway }

    /// Whether a selection change on the item may be read as the viewer's.
    /// Mid-reload the item changes under the engine's own selects and
    /// deselects, none of which is a captions command.
    var acceptsStockSelection: Bool { stage == .app || stage == .native }

    /// Whether the next load should declare the renditions itself, so an
    /// episode that starts while PiP or AirPlay holds the picture needs no
    /// second rebuild. Moves to `.declaring`; finish with `reloadFinished`.
    /// `eligible` is false for an item the handoff leaves alone (remote HLS
    /// carries its own renditions; Apple TV declares them always).
    mutating func loadStarted(eligible: Bool) -> Bool {
        renderedTrackID = nil
        wantedTrackID = nil
        // A new session may rebuild where the last one could not.
        declineUntilPictureReturns = false
        guard eligible, pictureIsAway, !declineUntilPictureReturns else {
            stage = .app
            return false
        }
        stage = .declaring
        return true
    }

    /// The picture moved, or the viewer's track changed.
    mutating func update(pictureIsAway away: Bool, wantedTrackID wanted: Int?) -> [Action] {
        pictureIsAway = away
        wantedTrackID = wanted
        if !away { declineUntilPictureReturns = false }
        switch stage {
        case .app:
            guard away, wanted != nil, !declineUntilPictureReturns else { return [] }
            stage = .declaring
            return [.reload(declaringRenditions: true)]
        case .native:
            guard away else {
                stage = .withdrawing
                renderedTrackID = nil
                return [.nativeRendering(false), .reload(declaringRenditions: false)]
            }
            guard wanted != renderedTrackID else { return [] }
            renderedTrackID = wanted
            return [.nativeRendering(wanted != nil)]
        case .declaring, .withdrawing:
            // Settled by `reloadFinished`, against the state at that moment.
            return []
        }
    }

    /// The reload (or load) the last action started has finished.
    mutating func reloadFinished(succeeded: Bool) -> [Action] {
        switch stage {
        case .declaring:
            guard succeeded else {
                stage = .app
                declineUntilPictureReturns = pictureIsAway
                return []
            }
            guard pictureIsAway else {
                stage = .withdrawing
                return [.reload(declaringRenditions: false)]
            }
            stage = .native
            renderedTrackID = wantedTrackID
            return wantedTrackID == nil ? [] : [.nativeRendering(true)]
        case .withdrawing:
            stage = .app
            // The picture went away again mid-withdraw. Declare whether or
            // not the withdraw worked: a failed one may have left either
            // item attached, and only a declaring rebuild puts the viewer's
            // captions on the receiver. That is one retry: if the declare
            // fails too, `declineUntilPictureReturns` holds the next one.
            guard pictureIsAway, wantedTrackID != nil, !declineUntilPictureReturns else { return [] }
            stage = .declaring
            return [.reload(declaringRenditions: true)]
        case .app, .native:
            return []
        }
    }

    /// The active track if the engine can hand it to AVKit as a rendition:
    /// a stream of the file's own (add-on files never become one) that is
    /// not CEA-708, which the engine draws only itself. Text, CEA-608 and —
    /// on demand — bitmap tracks all have renditions.
    @MainActor static func wantedTrack(activeTrackID: Int?, tracks: [ApplePlaybackTrack]) -> Int? {
        guard let activeTrackID, activeTrackID < AetherPlaybackEngine.externalSubtitleTrackIDBase,
              let track = tracks.first(where: { $0.id == activeTrackID }) else { return nil }
        let codec = track.codec?.lowercased() ?? ""
        return ["eia_708", "cea708", "cea_708"].contains(codec) ? nil : activeTrackID
    }

    /// Whether an external screen holds the picture. `AVPlayer`'s flag drops
    /// to false for a moment while the engine rebuilds the item for an
    /// AirPlay receiver (AetherEngine #227), and during the handoff's own
    /// rebuilds on either kind of screen, which would read as "the screen
    /// went" and start a withdraw in the middle of a swap. An AirPlay or HDMI
    /// route that still holds the audio keeps an active handoff active; it
    /// never starts one (AirPlay to a speaker carries no picture).
    static func externalPictureActive(playerReportsExternal: Bool, externalRouteHoldsAudio: Bool,
                                      wasActive: Bool) -> Bool {
        playerReportsExternal || (wasActive && externalRouteHoldsAudio)
    }
}
