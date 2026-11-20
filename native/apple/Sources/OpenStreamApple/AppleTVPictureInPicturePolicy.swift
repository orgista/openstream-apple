import Foundation

/// Picture in Picture on Apple TV, the decisions only (the runtime is
/// `AppleTVPictureInPicture`). Like the Apple TV app: the picture shrinks
/// into the system's window and the viewer keeps browsing oStream.
///
/// tvOS only puts `AVPlayerLayer` content into the window; it has no Picture
/// in Picture for sample-buffer content (FB9751461, still so on tvOS 26), so
/// the engine's software surface never offers it rather than offering a
/// button that does nothing.
enum AppleTVPictureInPicturePolicy {
    /// What is in the window, which decides how the full-screen player comes
    /// back: the Live tab's player, or the on-demand player over any tab.
    enum Content: Equatable, Sendable {
        case live
        case onDemand
    }

    /// Choosing a channel in the guide while something is in the window.
    enum ChannelChoice: Equatable, Sendable {
        /// Nothing in the window: the channel opens full screen as usual.
        case playFullScreen
        /// The window closes and the chosen channel opens full screen. No
        /// "swap the window's content" prompt: one press, one result.
        case closeWindowAndPlayFullScreen
    }

    /// Only the stock player's own layer can go into the window.
    static func allowsPictureInPicture(route: ApplePlaybackPresentationRoute) -> Bool {
        route == .avPlayer
    }

    /// "Picture in Picture" in the live player's options (hold Select): on
    /// the AVPlayer route of a device that supports it, and not while a
    /// window is already up.
    static func offersMenuEntry(route: ApplePlaybackPresentationRoute, isSupported: Bool,
                                isPictureInPictureActive: Bool) -> Bool {
        isSupported && !isPictureInPictureActive && allowsPictureInPicture(route: route)
    }

    static func channelChoice(isPictureInPictureActive: Bool) -> ChannelChoice {
        isPictureInPictureActive ? .closeWindowAndPlayFullScreen : .playFullScreen
    }

    /// Multiview needs every decoder it can get and a full screen of its
    /// own; its entry is hidden while a window is up.
    static func offersMultiview(isPictureInPictureActive: Bool) -> Bool {
        !isPictureInPictureActive
    }

    /// The window's own full-screen button: back to the player with the same
    /// stream, without reloading it. Anything else (the window closed, or
    /// the full-screen player never came back) ends playback.
    static func keepsPlayingWhenWindowCloses(restoredToFullScreen: Bool) -> Bool {
        restoredToFullScreen
    }

    /// The live tab's resume-the-last-channel-on-arrival is skipped while a
    /// window is up: it would close the window the viewer just opened.
    static func resumesLastChannelOnArrival(isPictureInPictureActive: Bool) -> Bool {
        !isPictureInPictureActive
    }

    /// Channel previews in the guide stay off while a window plays; two
    /// pictures with sound would compete.
    static func previewsEnabled(preference: Bool, isPictureInPictureActive: Bool) -> Bool {
        preference && !isPictureInPictureActive
    }
}
