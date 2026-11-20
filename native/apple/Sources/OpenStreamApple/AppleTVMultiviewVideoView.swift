#if os(tvOS)
import AVKit
import SwiftUI

/// AVKit renders native legible tracks as well as the picture. A bare
/// AVPlayerLayer preview is insufficient for the grid's captions contract.
/// Interaction stays with the tile button; each player has no transport
/// controls and cannot change the display mode for the wall.
struct AppleTVMultiviewVideoView: UIViewControllerRepresentable {
    let player: AVPlayer
    let onBack: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onBack: onBack) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = false
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = .resizeAspect
        controller.view.isUserInteractionEnabled = false
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onBack = onBack
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        controller.player = nil
    }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onBack: () -> Void
        init(onBack: @escaping () -> Void) { self.onBack = onBack }

        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            // Embedded AVKit players must not dismiss the containing Live cover.
            onBack()
            return false
        }
    }
}
#endif
