#if os(tvOS)
import AVKit
import Observation
import SwiftUI
import UIKit

/// Picture in Picture on Apple TV (`AppleTVPictureInPicturePolicy` decides).
///
/// The players are full-screen covers that tear their engine down when they
/// disappear. When the window opens, this holds on to the player (its host,
/// audio session and coordinator) and closes the cover around it, so playback
/// carries on in the window while the viewer browses. The window's
/// full-screen button opens the cover again around the same host — no new
/// item, same channel, same position. Closing the window, or starting
/// anything else, ends it.
@MainActor
@Observable
final class AppleTVPictureInPicture {
    static let shared = AppleTVPictureInPicture()

    /// A full-screen player and how it leaves and comes back.
    struct Owner {
        let host: ApplePlayerHost
        let audioSession: AppleAudioSessionCoordinator
        let coordinator: ApplePlaybackCoordinator
        let content: AppleTVPictureInPicturePolicy.Content
        /// Closes the full-screen player once the window is up.
        let leave: () -> Void
        /// Opens the full-screen player again.
        let restore: () -> Void
        /// Ends playback for good.
        let end: () -> Void
    }

    /// The player in the window; nil when there is none.
    private(set) var parked: Owner?
    var isActive: Bool { parked != nil }
    /// The on-demand player the root puts back on screen.
    var restoringPresentation: AppleMediaPlayerPresentation?
    /// Moves when the Live tab should open its player around the window's
    /// channel; `takeLiveRestore()` consumes it.
    private(set) var liveRestoreRequest = 0

    /// The player on screen, which a window started now would belong to.
    @ObservationIgnored private var owner: Owner?
    @ObservationIgnored private var liveRestorePending = false
    @ObservationIgnored private var pendingRestore: ((Bool) -> Void)?
    /// Set once the restored player is on screen again.
    @ObservationIgnored private var restoredHost: ApplePlayerHost?

    private init() {}

    func register(_ owner: Owner) {
        self.owner = owner
    }

    func unregister(_ host: ApplePlayerHost) {
        if owner?.host === host { owner = nil }
    }

    /// The player in the window, for a cover being rebuilt around the same
    /// coordinator.
    func parked(for coordinator: ApplePlaybackCoordinator) -> Owner? {
        guard let parked, parked.coordinator === coordinator else { return nil }
        return parked
    }

    func holds(_ host: ApplePlayerHost) -> Bool {
        parked?.host === host
    }

    /// The restored player has appeared: AVKit can animate the window into it.
    func playerAppeared(_ host: ApplePlayerHost) {
        guard parked?.host === host, let completion = pendingRestore else { return }
        pendingRestore = nil
        restoredHost = host
        appleTrace("picture in picture: restored")
        completion(true)
    }

    func takeLiveRestore() -> Bool {
        defer { liveRestorePending = false }
        return liveRestorePending && parked?.content == .live
    }

    /// Something else is starting to play: the window closes with its player.
    /// `host` is the player that is starting, if it is already built.
    func endForNewPlayback(keeping host: ApplePlayerHost? = nil) {
        guard let parked, parked.host !== host else { return }
        appleTrace("picture in picture: ended for new playback")
        end(parked)
    }

    // MARK: - From AVKit (`AppleTVPictureInPictureDelegate`)

    fileprivate func didStart(_ host: ApplePlayerHost) {
        guard let owner, owner.host === host else {
            appleTrace("picture in picture: started without an owner")
            return
        }
        if let parked, parked.host !== host { end(parked) }
        parked = owner
        restoredHost = nil
        appleTrace("picture in picture: started (\(owner.content))")
        owner.leave()
    }

    fileprivate func restore(_ host: ApplePlayerHost, completion: @escaping (Bool) -> Void) {
        guard let parked, parked.host === host else {
            completion(false)
            return
        }
        pendingRestore?(false)
        pendingRestore = completion
        if parked.content == .live {
            liveRestorePending = true
            liveRestoreRequest &+= 1
        }
        parked.restore()
        // A cover that never comes back must not hold the window open.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let late = self.pendingRestore, self.parked?.host === host else { return }
            self.pendingRestore = nil
            appleTrace("picture in picture: restore timed out")
            late(false)
        }
    }

    fileprivate func didStop(_ host: ApplePlayerHost) {
        host.pictureInPictureDidStop()
        guard let parked, parked.host === host else { return }
        let restored = restoredHost === host
        restoredHost = nil
        liveRestorePending = false
        if AppleTVPictureInPicturePolicy.keepsPlayingWhenWindowCloses(restoredToFullScreen: restored) {
            // The full-screen player owns the host again.
            self.parked = nil
            appleTrace("picture in picture: stopped, back to full screen")
        } else {
            appleTrace("picture in picture: closed")
            end(parked)
        }
    }

    private func end(_ parked: Owner) {
        if self.parked?.host === parked.host { self.parked = nil }
        pendingRestore?(false)
        pendingRestore = nil
        restoredHost = nil
        liveRestorePending = false
        if restoringPresentation?.coordinator === parked.coordinator { restoringPresentation = nil }
        parked.host.stopPictureInPicture()
        parked.end()
    }
}

/// The AVKit side of one `ApplePlayerHost`: the stock controller's own
/// window (its transport-bar button, on demand) and the live player's
/// (`AVPictureInPictureController` on `AppleTVPictureInPictureLayerView`).
/// AVKit does not promise the main thread, so each callback hops to it.
@MainActor
final class AppleTVPictureInPictureDelegate: NSObject {
    weak var host: ApplePlayerHost?

    private nonisolated func onMain(_ body: @escaping @MainActor (AppleTVPictureInPicture, ApplePlayerHost) -> Void) {
        Task { @MainActor in
            guard let host = self.host else { return }
            body(AppleTVPictureInPicture.shared, host)
        }
    }

    private nonisolated func restore(_ completion: @escaping (Bool) -> Void) {
        let completion = AppleTVPictureInPictureCompletion(body: completion)
        onMain { store, host in store.restore(host) { completion.body($0) } }
    }
}

/// AVKit's restore completion, carried to the main actor it is called from.
private struct AppleTVPictureInPictureCompletion: @unchecked Sendable {
    let body: (Bool) -> Void
}

extension AppleTVPictureInPictureDelegate: AVPlayerViewControllerDelegate {
    /// The cover is closed by the app (`Owner.leave`), not by AVKit.
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool { false }

    nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        onMain { store, host in store.didStart(host) }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          failedToStartPictureInPictureWithError error: any Error) {
        let kind = String(describing: type(of: error))
        Task { @MainActor in appleTrace("picture in picture: failed to start (\(kind))") }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        restore(completionHandler)
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        onMain { store, host in store.didStop(host) }
    }
}

extension AppleTVPictureInPictureDelegate: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { store, host in store.didStart(host) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        let kind = String(describing: type(of: error))
        onMain { _, host in
            appleTrace("picture in picture: failed to start (\(kind))")
            host.pictureInPictureDidStop()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        restore(completionHandler)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { store, host in store.didStop(host) }
    }
}

/// The layer the live player's window starts from and returns to. The live
/// player hides AVKit's transport bar, and with it the stock window button,
/// so its options menu starts the window from this layer instead. It sits
/// full screen under the stock controller and holds the player only while a
/// window is being opened or is up.
final class AppleTVPictureInPictureLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct AppleTVPictureInPictureLayer: UIViewRepresentable {
    let view: AppleTVPictureInPictureLayerView

    func makeUIView(context: Context) -> AppleTVPictureInPictureLayerView { view }
    func updateUIView(_ uiView: AppleTVPictureInPictureLayerView, context: Context) {}
}
#endif
