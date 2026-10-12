import SwiftUI

/// Native menu content shared by the live player and decoded-surface route.
struct AppleLivePlaybackOptions: View {
    let onSleepTimer: () -> Void
    let onMultiview: (() -> Void)?
    let onCaptions: () -> Void

    var onStartOver: (() -> Void)? = nil
    var onBackToLive: (() -> Void)? = nil
    /// Apple TV, where the window can show this stream
    /// (`AppleTVPictureInPicturePolicy.offersMenuEntry`); nil hides it.
    var onPictureInPicture: (() -> Void)? = nil

    var body: some View {
        if let onStartOver {
            Button("Start Over", action: onStartOver)
                .accessibilityIdentifier("live.player.startOver")
        }
        if let onBackToLive {
            Button("Back to Live", action: onBackToLive)
                .accessibilityIdentifier("live.player.backToLive")
        }
        Button("Sleep Timer", action: onSleepTimer)
        if let onPictureInPicture {
            Button("Picture in Picture", action: onPictureInPicture)
                .accessibilityIdentifier("live.player.pictureInPicture")
        }
        if let onMultiview {
            Button("Multiview", action: onMultiview)
                .accessibilityIdentifier("live.player.multiview")
        }
        Button("Captions", action: onCaptions)
    }
}
