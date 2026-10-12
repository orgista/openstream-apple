import Foundation

/// Full-screen presentation covers the guide without ending its playback session.
@MainActor
final class AppleLivePlaybackLifetime {
    var isFullScreen = false
    private var loadIdentity: String?
    private(set) var isInBackground = false

    func enteredBackground(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        isInBackground = true
        guard !host.keepsPlaybackForPictureInPicture else { return }
        stop(host: host, coordinator: coordinator)
    }

    func enteredForeground() { isInBackground = false }

    func beginLoad(identity: String) -> Bool {
        guard loadIdentity != identity else { return false }
        loadIdentity = identity
        return true
    }

    func inlineDisappeared(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        guard !isFullScreen, !host.keepsPlaybackForPictureInPicture else { return }
        stop(host: host, coordinator: coordinator)
    }

    func stop(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator) {
        loadIdentity = nil
        host.teardown()
        coordinator.stop()
    }
}
