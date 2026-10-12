#if !os(tvOS)
import AVKit
import Foundation

/// Reports when a Picture in Picture window takes the picture and when it
/// gives it back, for the caption handoff (`AppleCaptionHandoff`). The
/// delegate of the Mac's `AVPlayerView` and of `AVPlayerViewController`
/// elsewhere; it implements nothing else, so AVKit's default PiP behaviour is
/// unchanged.
///
/// "Away" starts once the window is up (a rebuild while AVKit is still
/// animating the layer into it could lose the window) and ends as soon as
/// the window starts to close, so the app's captions are back by the time
/// the picture lands in the app again. AVKit does not promise the main
/// thread for these callbacks, so each hops to the main actor.
@MainActor
final class ApplePictureInPictureWatcher: NSObject {
    /// The stock player's own window, or one opened on the same player by
    /// something else (the DEBUG captions probe). Kept apart so one's
    /// callbacks cannot close the other's.
    enum Source: Hashable { case stockPlayer, other }

    private var active: Set<Source> = []
    private var isStarting = false
    var isActive: Bool { !active.isEmpty }
    var isStartingOrActive: Bool { isStarting || isActive }
    var onChange: (Bool) -> Void = { _ in }

    func set(_ isOn: Bool, source: Source = .stockPlayer, event: String) {
        if source == .stockPlayer { isStarting = false }
        let wasActive = isActive
        if isOn { active.insert(source) } else { active.remove(source) }
        appleTrace("picture in picture: \(event) (\(source)) active=\(isActive)")
        if isActive != wasActive { onChange(isActive) }
    }

    func willStart() { isStarting = true }
}

#if os(macOS)
extension ApplePictureInPictureWatcher: AVPlayerViewPictureInPictureDelegate {
    nonisolated func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
        Task { @MainActor in self.set(true, event: "didStart") }
    }

    nonisolated func playerViewWillStopPicture(inPicture playerView: AVPlayerView) {
        Task { @MainActor in self.set(false, event: "willStop") }
    }

    nonisolated func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in self.set(false, event: "failedToStart") }
    }
}
#else
extension ApplePictureInPictureWatcher: AVPlayerViewControllerDelegate {
    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.willStart() }
    }
    nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.set(true, event: "didStart") }
    }

    nonisolated func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.set(false, event: "willStop") }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in self.set(false, event: "failedToStart") }
    }
}
#endif
#endif
